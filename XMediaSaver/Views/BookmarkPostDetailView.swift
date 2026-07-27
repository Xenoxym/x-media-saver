import AVKit
import SwiftUI

struct BookmarkPostDetailView: View {
    let post: BookmarkedPost
    @Environment(\.openURL) private var openURL

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
