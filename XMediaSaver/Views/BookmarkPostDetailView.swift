import AVKit
import SwiftUI
import UIKit

struct BookmarkPostDetailView: View {
    let post: BookmarkedPost
    @Environment(\.openURL) private var openURL
    @StateObject private var mediaSaver = PostMediaSaveModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                authorHeader

                if !post.text.isEmpty {
                    Text(post.text)
                        .font(.body)
                        .textSelection(.enabled)
                }

                ForEach(post.media) { media in
                    mediaCard(media)
                }

                if !post.media.isEmpty {
                    saveMediaSection
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
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Post 预览")
        .navigationBarTitleDisplayMode(.inline)
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
        VStack(alignment: .leading, spacing: 4) {
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
            if let authorID = post.authorID {
                Text("User ID: \(authorID)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .saverCard()
    }

    private func mediaCard(_ media: BookmarkedMedia) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch media.type {
            case .photo:
                LocalMediaThumbnailView(
                    media: media,
                    maximumPixelSize: 2_048,
                    contentMode: .fit,
                    remoteImageName: "orig"
                )
                .frame(maxWidth: .infinity, minHeight: 180)
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

    private var saveMediaSection: some View {
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
            } else {
                Button {
                    mediaSaver.save(post.media)
                } label: {
                    Label(
                        "保存本 Post 媒体到照片",
                        systemImage: "photo.badge.arrow.down"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
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
    private let history = MediaSaveHistoryStore()
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
                let completedKeys = try await history.load()
                let remaining = media.filter {
                    !completedKeys.contains($0.mediaKey)
                }
                let duplicateCount = media.count - remaining.count
                guard !remaining.isEmpty else {
                    resultMessage = "这个 Post 的媒体此前已经全部保存到照片。"
                    return
                }

                progress = BatchSaveProgress(
                    completed: 0,
                    total: remaining.count,
                    currentFraction: 0,
                    currentType: nil
                )
                let result = try await saver.save(
                    remaining,
                    didSave: { [history] item, _ in
                        _ = try? await history.insert(item.mediaKey)
                    },
                    progress: { update in
                        Task { @MainActor [weak self] in
                            self?.progress = update
                        }
                    }
                )
                resultMessage =
                    "保存 \(result.saved) 项，跳过 \(result.skipped + duplicateCount) 项，失败 \(result.failed) 项。"
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
                        player = AVPlayer(url: url)
                    }
                }
            }
            .onDisappear {
                if !isFullScreen {
                    player?.pause()
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
        ZStack(alignment: .topTrailing) {
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
