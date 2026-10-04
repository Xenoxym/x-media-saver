import SwiftUI
import AVKit
import UniformTypeIdentifiers

// Temporary test bench. No production player depends on any type in this file.
private enum AudioTestPreset: String, CaseIterable, Identifiable {
    case movie, standard, ambient, soloAmbient, spoken

    var id: String { rawValue }
    var title: String {
        switch self {
        case .movie: return "A · playback / moviePlayback"
        case .standard: return "B · playback / default"
        case .ambient: return "C · ambient / default"
        case .soloAmbient: return "D · soloAmbient / default"
        case .spoken: return "E · playback / spokenAudio"
        }
    }
    var category: AVAudioSession.Category {
        switch self {
        case .ambient: return .ambient
        case .soloAmbient: return .soloAmbient
        default: return .playback
        }
    }
    var mode: AVAudioSession.Mode {
        switch self {
        case .movie: return .moviePlayback
        case .spoken: return .spokenAudio
        default: return .default
        }
    }
}

// Audio-session operations are serial and off the UI thread, including restore.
private enum AudioTestSession {
    static let queue = DispatchQueue(label: "XMediaSaver.AudioComparison")

    struct Snapshot {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let policy: AVAudioSession.RouteSharingPolicy
        let options: AVAudioSession.CategoryOptions

        init() {
            let session = AVAudioSession.sharedInstance()
            category = session.category
            mode = session.mode
            policy = session.routeSharingPolicy
            options = session.categoryOptions
        }
    }

    static func apply(
        preset: AudioTestPreset, mix: Bool
    ) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    let options: AVAudioSession.CategoryOptions =
                        preset.category == .playback && mix ? [.mixWithOthers] : []
                    try session.setCategory(
                        preset.category, mode: preset.mode,
                        policy: .default, options: options
                    )
                    try session.setActive(true)
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: error.localizedDescription)
                }
            }
        }
    }

    static func restore(_ snapshot: Snapshot) {
        queue.async {
            let session = AVAudioSession.sharedInstance()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? session.setCategory(
                snapshot.category, mode: snapshot.mode,
                policy: snapshot.policy, options: snapshot.options
            )
        }
    }
}

@MainActor
private final class AudioComparisonModel: ObservableObject {
    let player = AVPlayer()
    @Published var preset: AudioTestPreset = .movie
    @Published var mix = false
    @Published var disableSpatialization = false
    @Published var fileName = ""
    @Published var audioTracks = ""
    @Published var actualSession = ""
    @Published var errorMessage: String?
    @Published var busy = false
    @Published var hasVideo = false
    @Published var referenceSeconds: Double = 0
    @Published var elapsedSeconds: Double = 0
    @Published var durationSeconds: Double = 0
    @Published var isPlaying = false
    @Published var appliedTitle = ""

    private var source: URL?
    private var securityScope = false
    private var originalSession: AudioTestSession.Snapshot?
    private var operation: Task<Void, Never>?
    private var generation = 0
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?

    init() {
        player.isMuted = false
        player.volume = 1
        player.allowsExternalPlayback = false
        player.audiovisualBackgroundPlaybackPolicy = .pauses
        installTimeObserver()
    }

    private func installTimeObserver() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.elapsedSeconds = time.seconds.isFinite ? time.seconds : 0
                self.isPlaying = self.player.timeControlStatus != .paused
            }
        }
    }

    func open(_ url: URL) {
        guard !busy else { return }
        installTimeObserver()
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeItemObservers()
        if securityScope { source?.stopAccessingSecurityScopedResource() }
        source = url
        securityScope = url.startAccessingSecurityScopedResource()
        originalSession = originalSession ?? AudioTestSession.Snapshot()
        fileName = url.lastPathComponent
        referenceSeconds = 0
        elapsedSeconds = 0
        durationSeconds = 0
        audioTracks = ""
        errorMessage = nil
        hasVideo = true
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        statusObservation = item.observe(\.status, options: [.new]) {
            [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? L10n.string("Unable to play this file.")
            Task { @MainActor [weak self] in self?.errorMessage = message }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.replay() }
        }
        apply(readMetadata: true, playWhenReady: false)
    }

    func apply(readMetadata: Bool = false, playWhenReady: Bool = true) {
        guard hasVideo, !busy else { return }
        busy = true
        errorMessage = nil
        player.pause()
        generation += 1
        let token = generation
        let chosenPreset = preset
        let chosenMix = mix
        // Restore the item's standard video default when this switch is off.
        player.currentItem?.allowedAudioSpatializationFormats =
            disableSpatialization ? [] : .monoStereoAndMultichannel
        operation = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let failure = await AudioTestSession.apply(preset: chosenPreset, mix: chosenMix)
            guard let self, !Task.isCancelled, token == self.generation else { return }
            if let failure {
                self.errorMessage = failure
                self.busy = false
                return
            }
            self.appliedTitle = chosenPreset.title
            if readMetadata, let asset = self.player.currentItem?.asset {
                let metadata = await Self.describeTracks(asset)
                guard !Task.isCancelled, token == self.generation else { return }
                self.audioTracks = metadata
                if let duration = try? await asset.load(.duration), duration.seconds.isFinite {
                    self.durationSeconds = max(0, duration.seconds)
                }
                guard !Task.isCancelled, token == self.generation else { return }
            }
            self.refreshSession()
            // Every configuration plays from the same user-marked point.
            let time = CMTime(seconds: self.referenceSeconds, preferredTimescale: 600)
            let finished = await self.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            guard !Task.isCancelled, token == self.generation else { return }
            self.busy = false
            if finished, playWhenReady { self.player.play() }
        }
    }

    func mark() {
        let seconds = player.currentTime().seconds
        if seconds.isFinite { referenceSeconds = max(0, seconds) }
    }

    func replay() {
        guard hasVideo, !busy else { return }
        let token = generation
        player.seek(
            to: CMTime(seconds: referenceSeconds, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, finished, token == self.generation, self.hasVideo else { return }
                self.player.play()
            }
        }
    }

    func refreshSession() {
        let session = AVAudioSession.sharedInstance()
        actualSession = "\(session.category.rawValue)\n\(session.mode.rawValue)\n"
            + "\(Int(session.sampleRate)) Hz · \(session.outputNumberOfChannels) ch\n"
            + session.currentRoute.outputs.map { "\($0.portType.rawValue): \($0.portName)" }
                .joined(separator: "\n")
    }

    func togglePlayback() {
        guard !busy else { return }
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
        isPlaying = player.timeControlStatus != .paused
    }

    func seek(_ seconds: Double) {
        guard !busy else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    func close() {
        generation += 1
        operation?.cancel()
        operation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        removeItemObservers()
        hasVideo = false
        busy = false
        if securityScope { source?.stopAccessingSecurityScopedResource() }
        securityScope = false
        source = nil
        if let originalSession {
            AudioTestSession.restore(originalSession)
            self.originalSession = nil
        }
    }

    private func removeItemObservers() {
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    private static func describeTracks(_ asset: AVAsset) async -> String {
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            var lines: [String] = []
            for (index, track) in tracks.enumerated() {
                let formats = try await track.load(.formatDescriptions)
                for format in formats {
                    guard let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { continue }
                    let code = CMFormatDescriptionGetMediaSubType(format)
                    let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
                    let codec = String(bytes: bytes, encoding: .ascii) ?? "\(code)"
                    lines.append("\(index + 1) · \(codec) · \(Int(stream.pointee.mSampleRate)) Hz · \(stream.pointee.mChannelsPerFrame) ch")
                }
            }
            return lines.isEmpty ? L10n.string("No audio track found.") : lines.joined(separator: "\n")
        } catch { return error.localizedDescription }
    }
}

struct AudioComparisonView: View {
    @StateObject private var model = AudioComparisonModel()
    @State private var showsImporter = false
    @State private var showsFullScreen = false
    @AppStorage("audioComparisonTestNotes") private var listeningNotes = ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
                Button { showsImporter = true } label: {
                    Label("Choose Test Video", systemImage: "folder")
                }
                .disabled(model.busy)
                if model.hasVideo {
                    Text(model.fileName).font(.caption).lineLimit(2)
                    Button("Play Full Screen") { showsFullScreen = true }
                        .disabled(model.busy)
                    HStack {
                        Button("Mark Test Start") { model.mark() }
                        Spacer()
                        Button("Replay Test Segment") { model.replay() }
                    }
                    .font(.subheadline)
                    .disabled(model.busy)
                    Text(L10n.format("Comparison starts at %.1f s", model.referenceSeconds))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Test Video") }

            Section {
                Picker("Audio Configuration", selection: $model.preset) {
                    ForEach(AudioTestPreset.allCases) { preset in
                        Text(verbatim: preset.title).tag(preset)
                    }
                }
                Toggle("Mix with Other Audio", isOn: $model.mix)
                    .disabled(model.preset.category != .playback)
                Toggle("Disable Item Spatialization", isOn: $model.disableSpatialization)
                Button {
                    model.apply()
                    showsFullScreen = true
                } label: {
                    HStack {
                        Text("Apply and Replay")
                        if model.busy { Spacer(); ProgressView() }
                    }
                }
                .disabled(!model.hasVideo)
            } header: { Text("Test Configuration") }
                footer: {
                    Text("Select a configuration, then Apply and Replay. All tests use the same video and marked start. Changes only affect this test page.")
                }
                .disabled(model.busy)

            if let error = model.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
            if model.hasVideo {
                Section {
                    Text(model.audioTracks).font(.caption.monospaced())
                    Text(model.actualSession).font(.caption.monospaced())
                    Button("Refresh Audio Status") { model.refreshSession() }
                } header: { Text("Audio Status") }
            }
            Section {
                TextField("Record the best configuration here", text: $listeningNotes, axis: .vertical)
                    .lineLimit(3...6)
            } header: { Text("Listening Notes") }
        }
        .navigationTitle("Audio Comparison Test")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.movie]) { result in
            switch result {
            case .success(let url): model.open(url)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .fullScreenCover(isPresented: $showsFullScreen) {
            AudioTestFullScreenView(model: model)
        }
        .onDisappear {
            if !showsFullScreen, !showsImporter { model.close() }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { model.player.pause() }
        }
    }
}

private struct AudioTestFullScreenView: View {
    @ObservedObject var model: AudioComparisonModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsConfiguration = false
    @State private var seekSeconds: Double = 0
    @State private var seeking = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AudioTestPlayerLayerView(player: model.player).ignoresSafeArea()
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").padding(12)
                    }
                    Spacer()
                    Button { showsConfiguration = true } label: {
                        Image(systemName: "slider.horizontal.3").padding(12)
                    }
                }
                Spacer()
                VStack(spacing: 12) {
                    Text(verbatim: model.appliedTitle).font(.caption)
                    Slider(
                        value: $seekSeconds, in: 0...max(1, model.durationSeconds),
                        onEditingChanged: { editing in
                            seeking = editing
                            if !editing { model.seek(seekSeconds) }
                        }
                    )
                    HStack {
                        Button { model.togglePlayback() } label: {
                            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                                .frame(width: 44, height: 44)
                        }
                        Spacer()
                        Button("Mark Test Start") { model.mark() }
                        Spacer()
                        Button("Replay Test Segment") { model.replay() }
                    }.font(.subheadline)
                }
                .padding().background(.black.opacity(0.65))
            }.foregroundStyle(.white).tint(.white)
        }
        .onAppear { model.replay() }
        .onDisappear { model.player.pause() }
        .onChange(of: model.elapsedSeconds) { seconds in
            if !seeking { seekSeconds = min(max(0, seconds), max(1, model.durationSeconds)) }
        }
        .sheet(isPresented: $showsConfiguration) {
            NavigationStack {
                Form {
                    Picker("Audio Configuration", selection: $model.preset) {
                        ForEach(AudioTestPreset.allCases) { preset in
                            Text(verbatim: preset.title).tag(preset)
                        }
                    }
                    Toggle("Mix with Other Audio", isOn: $model.mix)
                        .disabled(model.preset.category != .playback)
                    Toggle("Disable Item Spatialization", isOn: $model.disableSpatialization)
                    Button("Apply and Replay") {
                        model.apply()
                        showsConfiguration = false
                    }
                    .disabled(model.busy)
                    if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
                }
                .disabled(model.busy)
                .navigationTitle("Test Configuration")
                .navigationBarTitleDisplayMode(.inline)
            }.presentationDetents([.medium, .large])
        }
    }
}

// Same AVPlayer + AVPlayerLayer output path as the gallery's full-screen player.
private struct AudioTestPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: Surface, context: Context) {}

    static func dismantleUIView(_ view: Surface, coordinator: ()) {
        view.playerLayer.player = nil
    }
}
