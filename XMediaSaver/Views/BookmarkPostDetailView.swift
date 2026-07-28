import AVKit
import SwiftUI
import UIKit

struct BookmarkPostDetailView: View {
    let post: BookmarkedPost
    var preservesAudioSessionOnDismiss = false
    @Environment(\.openURL) private var openURL
    @StateObject private var mediaSaver = PostMediaSaveModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                authorHeader

                if !post.text.isEmpty {
                    Text(post.text)
                        .font(.body)
                        .textSelection(.enabled)
                }

                ForEach(post.media) { media in
                    mediaCard(media)
                }

                if mediaSaver.isSaving || mediaSaver.resultMessage != nil {
                    saveMediaStatusSection
                }

                if let postURL = post.postURL {
                    Button {
                        openURL(postURL)
                    } label: {
                        Label("在 X 中查看原帖", systemImage: "arrow.up.right.square")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Post 预览")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !post.media.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        mediaSaver.save(post.media)
                    } label: {
                        Label(
                            "保存本 Post 媒体到照片",
                            systemImage: "photo.badge.arrow.down"
                        )
                    }
                    .disabled(mediaSaver.isSaving)
                }
            }
        }
        .alert(item: $mediaSaver.presentedError) { error in
            if error.offersSettings {
                return Alert(
                    title: Text("需要照片权限"),
                    message: Text(error.message),
                    primaryButton: .default(Text("打开设置")) {
                        guard let url = URL(
                            string: UIApplication.openSettingsURLString
                        ) else { return }
                        openURL(url)
                    },
                    secondaryButton: .cancel()
                )
            }
            return Alert(
                title: Text("保存未完成"),
                message: Text(error.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    private var authorHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(post.authorName ?? "未知作者")
                .font(.headline)
            HStack(spacing: 8) {
                if let username = post.authorUsername {
                    Text("@\(username)")
                }
                if let date = post.createdAt {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func mediaCard(_ media: BookmarkedMedia) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch media.type {
            case .photo:
                FullScreenPhotoPreview(media: media)
            case .animatedGIF, .video:
                if media.bestMP4Variant?.url != nil {
                    InlineVideoPreview(
                        media: media,
                        preservesAudioSessionOnDismiss:
                            preservesAudioSessionOnDismiss
                    )
                } else {
                    Label("没有可播放的 MP4 变体", systemImage: "video.slash")
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }

            HStack {
                Label(media.type.title, systemImage: media.type.systemImage)
                Spacer()
                Text(mediaMetadata(media))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .saverCard()
    }

    private var saveMediaStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if mediaSaver.isSaving {
                ProgressView(
                    value: mediaSaver.progressValue,
                    total: 1
                )
                HStack {
                    Text(
                        "\(mediaSaver.progress.completed)/\(mediaSaver.progress.total)"
                    )
                    .font(.caption.monospacedDigit())
                    Spacer()
                    Button("取消", role: .cancel) {
                        mediaSaver.cancel()
                    }
                }
            }

            if let message = mediaSaver.resultMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .saverCard()
    }

    private func mediaMetadata(_ media: BookmarkedMedia) -> String {
        var values: [String] = []
        if let width = media.width, let height = media.height {
            values.append("\(width)×\(height)")
        }
        if let duration = media.durationMilliseconds {
            values.append(Self.durationFormatter.string(
                from: TimeInterval(duration) / 1_000
            ) ?? "")
        }
        if let byteSize = media.byteSize {
            values.append(Self.byteFormatter.string(fromByteCount: byteSize))
        } else {
            values.append("大小待分析")
        }
        return values.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

private struct FullScreenPhotoPreview: View {
    let media: BookmarkedMedia
    @State private var isFullScreen = false

    var body: some View {
        LocalMediaThumbnailView(
            media: media,
            maximumPixelSize: 2_048,
            contentMode: .fit,
            remoteImageName: "orig"
        )
        .frame(maxWidth: .infinity, minHeight: 180)
        .contentShape(Rectangle())
        .overlay(alignment: .topTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.55), in: Circle())
                .padding(10)
                .allowsHitTesting(false)
        }
        .onTapGesture {
            isFullScreen = true
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("全屏查看图片")
        .fullScreenCover(isPresented: $isFullScreen) {
            FullScreenPhotoView(media: media)
        }
    }
}

private struct FullScreenPhotoView: View {
    let media: BookmarkedMedia
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black
                .opacity(backgroundOpacity)

            LocalMediaThumbnailView(
                media: media,
                maximumPixelSize: 4_096,
                contentMode: .fit,
                remoteImageName: "orig"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(scale)
            .offset(dragOffset)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture {
            dismiss()
        }
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    scale = min(max(settledScale * value, 1), 6)
                }
                .onEnded { _ in
                    settledScale = scale
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    guard value.translation.height > 0,
                          abs(value.translation.height)
                            > abs(value.translation.width)
                    else {
                        return
                    }
                    dragOffset = CGSize(
                        width: value.translation.width * 0.25,
                        height: value.translation.height
                    )
                }
                .onEnded { value in
                    let predicted = value.predictedEndTranslation.height
                    if dragOffset.height > 90 || predicted > 180 {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.3)) {
                            dragOffset = .zero
                        }
                    }
                }
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("退出全屏图片")
        .statusBarHidden(true)
    }

    private var backgroundOpacity: Double {
        let progress = min(max(Double(dragOffset.height / 360), 0), 0.45)
        return 1 - progress
    }
}

@MainActor
private final class PostMediaSaveModel: ObservableObject {
    @Published private(set) var isSaving = false
    @Published private(set) var progress = BatchSaveProgress(
        completed: 0,
        total: 0,
        currentFraction: 0,
        currentType: nil
    )
    @Published private(set) var resultMessage: String?
    @Published var presentedError: PresentedError?

    private let saver = BatchMediaSaver()
    private var task: Task<Void, Never>?

    var progressValue: Double {
        guard progress.total > 0 else { return 0 }
        return min(
            (Double(progress.completed) + progress.currentFraction)
                / Double(progress.total),
            1
        )
    }

    func save(_ media: [BookmarkedMedia]) {
        guard !isSaving, !media.isEmpty else { return }
        resultMessage = nil
        isSaving = true
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                isSaving = false
                task = nil
            }

            do {
                progress = BatchSaveProgress(
                    completed: 0,
                    total: media.count,
                    currentFraction: 0,
                    currentType: nil
                )
                let result = try await saver.save(
                    media,
                    didSave: { _, _ in },
                    progress: { update in
                        Task { @MainActor [weak self] in
                            self?.progress = update
                        }
                    }
                )
                resultMessage =
                    "保存 \(result.saved) 项，跳过 \(result.skipped) 项，失败 \(result.failed) 项。"
                if result.failed > 0, let issue = result.issues.first {
                    presentedError = PresentedError(
                        message: issue,
                        offersSettings: false
                    )
                }
            } catch is CancellationError {
                resultMessage = "保存已取消。"
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                presentedError = PresentedError(
                    message: message,
                    offersSettings:
                        (error as? AppError) == .photoPermissionDenied
                )
            }
        }
    }

    func cancel() {
        saver.cancel()
        task?.cancel()
    }
}

private struct InlineVideoPreview: View {
    let media: BookmarkedMedia
    let preservesAudioSessionOnDismiss: Bool
    @State private var player: AVPlayer?
    @State private var audioSessionActive = false
    @State private var isSilent: Bool?
    @State private var pictureInPictureActive = false
    @State private var nativeFullScreenActive = false
    @State private var inlineAudioEnabled = false
    @State private var fullScreenRequestID = 0
    @State private var audioConfigurationTask: Task<Void, Never>?
    @AppStorage("postVideoBackgroundPlaybackEnabled")
    private var backgroundPlaybackEnabled = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                SystemVideoPlayerView(
                    player: player,
                    isPictureInPictureActive: $pictureInPictureActive,
                    isFullScreenActive: $nativeFullScreenActive,
                    inlineAudioEnabled: $inlineAudioEnabled,
                    fullScreenRequestID: fullScreenRequestID,
                    updatesNowPlayingInfoCenter:
                        backgroundPlaybackEnabled && isSilent == false
                )

                Button {
                    fullScreenRequestID &+= 1
                } label: {
                    Image(
                        systemName:
                            "arrow.up.left.and.arrow.down.right"
                    )
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.6), in: Circle())
                }
                .padding(10)
                .disabled(player == nil)
                .accessibilityLabel("全屏播放")
            }
                .aspectRatio(mediaAspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 8) {
                Label("画中画", systemImage: "pip")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("后台播放")
                    .foregroundStyle(.secondary)
                Toggle(
                    "后台播放",
                    isOn: $backgroundPlaybackEnabled
                )
                .labelsHidden()
                .controlSize(.small)
            }
            .font(.caption)
        }
            .task(id: media.mediaKey) {
                if player == nil {
                    let localURL = await LocalMediaLibrary.shared.localURL(
                        for: media.mediaKey
                    )
                    if let url = localURL ?? media.bestMP4Variant?.url {
                        let newPlayer = AVPlayer(url: url)
                        newPlayer.actionAtItemEnd = .none
                        newPlayer.isMuted = true
                        updateBackgroundPolicy(
                            for: newPlayer,
                            enabled: false
                        )
                        player = newPlayer
                        newPlayer.play()

                        // Do not delay the first frame while AVFoundation checks
                        // whether this remote asset contains an audio track.
                        let silent = await MediaPlaybackAudioSession.isSilent(
                            media: media,
                            url: url
                        )
                        guard !Task.isCancelled, player === newPlayer else {
                            return
                        }
                        isSilent = silent
                        let activated =
                            await MediaPlaybackAudioSession.activate(
                                silent:
                                    silent || !backgroundPlaybackEnabled
                            )
                        guard !Task.isCancelled,
                              player === newPlayer
                        else {
                            return
                        }
                        audioSessionActive = activated
                        updateBackgroundPolicy(
                            for: newPlayer,
                            enabled:
                                backgroundPlaybackEnabled && !silent
                        )
                    }
                }
            }
            .onChange(of: backgroundPlaybackEnabled) { enabled in
                guard let player else { return }
                updateBackgroundPolicy(
                    for: player,
                    enabled: enabled && isSilent == false
                )
                if let isSilent {
                    audioConfigurationTask?.cancel()
                    let expectedPlayer = player
                    audioConfigurationTask = Task {
                        let activated =
                            await MediaPlaybackAudioSession.activate(
                                silent: isSilent || !enabled
                            )
                        guard !Task.isCancelled,
                              self.player === expectedPlayer
                        else {
                            return
                        }
                        audioSessionActive = activated
                    }
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.didEnterBackgroundNotification
                )
            ) { _ in
                guard !pictureInPictureActive else { return }
                if !backgroundPlaybackEnabled || isSilent != false {
                    player?.pause()
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .AVPlayerItemDidPlayToEndTime
                )
            ) { notification in
                loopIfCurrentItemEnded(notification)
            }
            .onDisappear {
                audioConfigurationTask?.cancel()
                audioConfigurationTask = nil
                if !pictureInPictureActive
                    && !nativeFullScreenActive {
                    player?.pause()
                }
                if !pictureInPictureActive
                    && !nativeFullScreenActive
                    && !preservesAudioSessionOnDismiss {
                    Task {
                        await MediaPlaybackAudioSession.deactivate()
                    }
                }
                audioSessionActive = false
            }
    }

    private var mediaAspectRatio: CGFloat {
        guard let width = media.width,
              let height = media.height,
              width > 0,
              height > 0
        else {
            return 16 / 9
        }
        return CGFloat(width) / CGFloat(height)
    }

    private func updateBackgroundPolicy(
        for player: AVPlayer,
        enabled: Bool
    ) {
        player.audiovisualBackgroundPlaybackPolicy = enabled
            ? .continuesIfPossible
            : .pauses
    }

    private func loopIfCurrentItemEnded(_ notification: Notification) {
        guard let endedItem = notification.object as? AVPlayerItem,
              let currentItem = player?.currentItem,
              endedItem === currentItem
        else {
            return
        }
        player?.seek(to: .zero)
        player?.play()
    }
}

private struct SystemVideoPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer?
    @Binding var isPictureInPictureActive: Bool
    @Binding var isFullScreenActive: Bool
    @Binding var inlineAudioEnabled: Bool
    let fullScreenRequestID: Int
    let updatesNowPlayingInfoCenter: Bool

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.delegate = context.coordinator
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        controller.updatesNowPlayingInfoCenter =
            updatesNowPlayingInfoCenter
        context.coordinator.attach(to: controller)
        context.coordinator.observe(player: player)
        context.coordinator.handleFullScreenRequest(
            fullScreenRequestID
        )

        let pinchGesture = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )
        pinchGesture.cancelsTouchesInView = false
        controller.view.addGestureRecognizer(pinchGesture)
        return controller
    }

    func updateUIViewController(
        _ controller: AVPlayerViewController,
        context: Context
    ) {
        if controller.player !== player {
            controller.player = player
        }
        controller.updatesNowPlayingInfoCenter =
            updatesNowPlayingInfoCenter
        context.coordinator.observe(player: player)
        context.coordinator.handleFullScreenRequest(
            fullScreenRequestID
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isPictureInPictureActive: $isPictureInPictureActive,
            isFullScreenActive: $isFullScreenActive,
            inlineAudioEnabled: $inlineAudioEnabled
        )
    }

    static func dismantleUIViewController(
        _ controller: AVPlayerViewController,
        coordinator: Coordinator
    ) {
        controller.delegate = nil
        controller.player = nil
        coordinator.attach(to: nil)
        coordinator.stopObservingPlayer()
    }

    final class Coordinator:
        NSObject,
        AVPlayerViewControllerDelegate,
        UIAdaptivePresentationControllerDelegate {
        private var isPictureInPictureActive: Binding<Bool>
        private var isFullScreenActive: Binding<Bool>
        private var inlineAudioEnabled: Binding<Bool>
        private weak var observedPlayer: AVPlayer?
        private weak var playerViewController: AVPlayerViewController?
        private weak var fullScreenController: AVPlayerViewController?
        private var muteObservation: NSKeyValueObservation?
        private var lastFullScreenRequestID = 0

        init(
            isPictureInPictureActive: Binding<Bool>,
            isFullScreenActive: Binding<Bool>,
            inlineAudioEnabled: Binding<Bool>
        ) {
            self.isPictureInPictureActive = isPictureInPictureActive
            self.isFullScreenActive = isFullScreenActive
            self.inlineAudioEnabled = inlineAudioEnabled
        }

        func attach(to controller: AVPlayerViewController?) {
            playerViewController = controller
        }

        func handleFullScreenRequest(_ requestID: Int) {
            guard requestID != lastFullScreenRequestID else { return }
            lastFullScreenRequestID = requestID
            presentFullScreen()
        }

        func observe(player: AVPlayer?) {
            guard observedPlayer !== player else { return }
            stopObservingPlayer()
            observedPlayer = player
            muteObservation = player?.observe(
                \.isMuted,
                options: [.new]
            ) { [weak self] player, _ in
                DispatchQueue.main.async {
                    guard let self,
                          !self.isFullScreenActive.wrappedValue
                    else {
                        return
                    }
                    self.inlineAudioEnabled.wrappedValue =
                        !player.isMuted
                }
            }
        }

        func stopObservingPlayer() {
            muteObservation?.invalidate()
            muteObservation = nil
            observedPlayer = nil
        }

        @objc
        func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard gesture.state == .ended,
                  gesture.scale > 1.12,
                  observedPlayer != nil
            else {
                return
            }
            presentFullScreen()
        }

        func playerViewControllerWillStartPictureInPicture(
            _ playerViewController: AVPlayerViewController
        ) {
            isPictureInPictureActive.wrappedValue = true
        }

        func playerViewControllerDidStopPictureInPicture(
            _ playerViewController: AVPlayerViewController
        ) {
            isPictureInPictureActive.wrappedValue = false
            if !isFullScreenActive.wrappedValue {
                fullScreenController?.player = nil
                fullScreenController = nil
                restoreInlinePlayback()
            }
        }

        func presentationControllerWillDismiss(
            _ presentationController: UIPresentationController
        ) {
            isFullScreenActive.wrappedValue = false
        }

        func presentationControllerDidDismiss(
            _ presentationController: UIPresentationController
        ) {
            finishFullScreenDismissal()
        }

        private func presentFullScreen() {
            guard fullScreenController == nil,
                  let presentingController = playerViewController,
                  let player = observedPlayer
            else {
                return
            }

            let controller = DismissAwarePlayerViewController()
            controller.player = player
            controller.delegate = self
            controller.showsPlaybackControls = true
            controller.videoGravity = .resizeAspect
            controller.allowsPictureInPicturePlayback = true
            controller.canStartPictureInPictureAutomaticallyFromInline =
                false
            controller.updatesNowPlayingInfoCenter = false
            controller.modalPresentationStyle = .fullScreen
            controller.onDismissal = { [weak self] in
                self?.finishFullScreenDismissal()
            }
            fullScreenController = controller

            isFullScreenActive.wrappedValue = true
            player.isMuted = false
            player.play()

            presentingController.present(
                controller,
                animated: true
            ) { [weak self, weak controller] in
                controller?.presentationController?.delegate = self
            }
        }

        private func finishFullScreenDismissal() {
            isFullScreenActive.wrappedValue = false
            if !isPictureInPictureActive.wrappedValue {
                fullScreenController?.player = nil
                fullScreenController = nil
                restoreInlinePlayback()
            }
        }

        private func restoreInlinePlayback() {
            observedPlayer?.isMuted =
                !inlineAudioEnabled.wrappedValue
            observedPlayer?.play()
        }
    }
}

private final class DismissAwarePlayerViewController:
    AVPlayerViewController {
    var onDismissal: (() -> Void)?
    private var hasNotifiedDismissal = false

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hasNotifiedDismissal = false
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard !hasNotifiedDismissal,
              isBeingDismissed || presentingViewController == nil
        else {
            return
        }
        hasNotifiedDismissal = true
        onDismissal?()
    }
}
