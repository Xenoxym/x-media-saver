import SwiftUI

struct MediaGalleryView: View {
    let mediaType: BookmarkMediaType?
    @State private var visibleLimit = 90
    private let galleryItems: [GalleryMediaItem]

    init(posts: [BookmarkedPost], mediaType: BookmarkMediaType?) {
        self.mediaType = mediaType
        var seen: Set<String> = []
        self.galleryItems = posts
            .sorted {
                ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
            }
            .flatMap { post in
                post.media.compactMap { media in
                    guard mediaType == nil || media.type == mediaType,
                          seen.insert(media.mediaKey).inserted
                    else {
                        return nil
                    }
                    return GalleryMediaItem(post: post, media: media)
                }
            }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 2),
                    count: 3
                ),
                spacing: 2
            ) {
                ForEach(Array(galleryItems.prefix(visibleLimit))) { item in
                    NavigationLink {
                        BookmarkPostDetailView(post: item.post)
                    } label: {
                        ZStack(alignment: .bottomLeading) {
                            LocalMediaThumbnailView(
                                media: item.media,
                                maximumPixelSize: 420
                            )
                            .aspectRatio(1, contentMode: .fill)

                            HStack(spacing: 4) {
                                Image(systemName: item.media.type.systemImage)
                                if let duration = item.media.durationMilliseconds {
                                    Text(Self.durationText(duration))
                                }
                            }
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(.black.opacity(0.55))
                        }
                        .aspectRatio(1, contentMode: .fit)
                        .clipped()
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if item.id == galleryItems.prefix(visibleLimit).last?.id,
                           visibleLimit < galleryItems.count {
                            visibleLimit += 90
                        }
                    }
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Text("\(galleryItems.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        switch mediaType {
        case nil: return "全部媒体"
        case .some(.photo): return "图片"
        case .some(.animatedGIF): return "动图"
        case .some(.video): return "视频"
        }
    }

    private static func durationText(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1_000
        if seconds >= 3_600 {
            return String(
                format: "%d:%02d:%02d",
                seconds / 3_600,
                (seconds % 3_600) / 60,
                seconds % 60
            )
        }
        return String(
            format: "%d:%02d",
            seconds / 60,
            seconds % 60
        )
    }
}

private struct GalleryMediaItem: Identifiable {
    let post: BookmarkedPost
    let media: BookmarkedMedia
    var id: String { media.mediaKey }
}
