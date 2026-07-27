import AVKit
import SwiftUI
import UIKit

struct BookmarkPostDetailView: View {
    let post: BookmarkedPost
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
                    InlineVideoPreview(media: media)
                        .frame(minHeight: 220)
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
    @State private var player: AVPlayer?
    @State private var isFullScreen = false
    @State private var audioSessionActive = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VideoPlayer(player: player)

            Button {
                isFullScreen = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.6), in: Circle())
            }
            .padding(10)
            .disabled(player == nil)
            .accessibilityLabel("全屏播放")
        }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .simultaneousGesture(
                MagnificationGesture()
                    .onEnded { scale in
                        if scale > 1.12, player != nil {
                            isFullScreen = true
                        }
                    }
            )
            .task(id: media.mediaKey) {
                if player == nil {
                    let localURL = await LocalMediaLibrary.shared.localURL(
                        for: media.mediaKey
                    )
                    if let url = localURL ?? media.bestMP4Variant?.url {
                        let newPlayer = AVPlayer(url: url)
                        let silent = await MediaPlaybackAudioSession.isSilent(
                            media: media,
                            url: url
                        )
                        newPlayer.isMuted = silent
                        if silent {
                            audioSessionActive =
                                MediaPlaybackAudioSession.activate(
                                    silent: true
                                )
                        }
                        player = newPlayer
                    }
                }
            }
            .onDisappear {
                if !isFullScreen {
                    player?.pause()
                    if audioSessionActive {
                        MediaPlaybackAudioSession.deactivate()
                        audioSessionActive = false
                    }
                }
            }
            .fullScreenCover(isPresented: $isFullScreen) {
                FullScreenVideoPlayer(player: player)
            }
    }
}

private struct FullScreenVideoPlayer: View {
    let player: AVPlayer?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
                .ignoresSafeArea()

            VideoPlayer(player: player)
                .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.6), in: Circle())
            }
            .padding()
            .accessibilityLabel("退出全屏")
        }
        .onAppear {
            player?.play()
        }
    }
}
