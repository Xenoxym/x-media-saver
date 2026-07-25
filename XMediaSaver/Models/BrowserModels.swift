import Foundation

enum BookmarkMediaType: String, Codable, CaseIterable, Hashable, Identifiable {
    case photo
    case animatedGIF = "animated_gif"
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photo: return "图片"
        case .animatedGIF: return "动图"
        case .video: return "视频"
        }
    }

    var systemImage: String {
        switch self {
        case .photo: return "photo"
        case .animatedGIF: return "sparkles.tv"
        case .video: return "video"
        }
    }
}

struct XMediaVariant: Codable, Hashable {
    let bitRate: Int?
    let contentType: String
    let url: URL

    enum CodingKeys: String, CodingKey {
        case bitRate = "bit_rate"
        case contentType = "content_type"
        case url
    }
}

struct BookmarkedMedia: Identifiable, Codable, Hashable {
    let mediaKey: String
    let type: BookmarkMediaType
    let url: URL?
    let previewImageURL: URL?
    let variants: [XMediaVariant]
    let width: Int?
    let height: Int?
    let durationMilliseconds: Int?

    var id: String { mediaKey }

    var bestMP4Variant: XMediaVariant? {
        variants
            .filter { $0.contentType.lowercased() == "video/mp4" }
            .sorted { ($0.bitRate ?? -1) > ($1.bitRate ?? -1) }
            .first
    }

    var downloadURL: URL? {
        switch type {
        case .photo:
            return url
        case .animatedGIF, .video:
            return bestMP4Variant?.url
        }
    }

    enum CodingKeys: String, CodingKey {
        case mediaKey = "media_key"
        case type
        case url
        case previewImageURL = "preview_image_url"
        case variants
        case width
        case height
        case durationMilliseconds = "duration_ms"
    }
}

struct BookmarkedPost: Identifiable, Codable, Equatable {
    let id: String
    let text: String
    let createdAt: Date?
    let authorID: String?
    let authorName: String?
    let authorUsername: String?
    let media: [BookmarkedMedia]
}

struct BookmarkPage: Equatable {
    let posts: [BookmarkedPost]
    let nextToken: String?
}

struct BookmarkFilter: Equatable {
    var includePhotos = true
    var includeGIFs = true
    var includeVideos = true
    var useStartDate = false
    var startDate = Calendar.current.date(
        byAdding: .month,
        value: -1,
        to: Date()
    ) ?? Date()
    var useEndDate = false
    var endDate = Date()

    var selectedTypes: Set<BookmarkMediaType> {
        var result: Set<BookmarkMediaType> = []
        if includePhotos { result.insert(.photo) }
        if includeGIFs { result.insert(.animatedGIF) }
        if includeVideos { result.insert(.video) }
        return result
    }

    func contains(_ post: BookmarkedPost, calendar: Calendar = .current) -> Bool {
        if useStartDate {
            guard let createdAt = post.createdAt,
                  createdAt >= calendar.startOfDay(for: startDate)
            else {
                return false
            }
        }
        if useEndDate {
            guard let createdAt = post.createdAt,
                  let endExclusive = calendar.date(
                    byAdding: .day,
                    value: 1,
                    to: calendar.startOfDay(for: endDate)
                  ),
                  createdAt < endExclusive
            else {
                return false
            }
        }
        return post.media.contains { selectedTypes.contains($0.type) }
    }

    func media(in post: BookmarkedPost) -> [BookmarkedMedia] {
        guard contains(post) else { return [] }
        return post.media.filter { selectedTypes.contains($0.type) }
    }
}

struct BookmarkStatistics: Equatable {
    let bookmarkCount: Int
    let bookmarksWithMedia: Int
    let photoCount: Int
    let gifCount: Int
    let videoCount: Int

    static func calculate(from posts: [BookmarkedPost]) -> BookmarkStatistics {
        let media = posts.flatMap(\.media)
        return BookmarkStatistics(
            bookmarkCount: posts.count,
            bookmarksWithMedia: posts.filter { !$0.media.isEmpty }.count,
            photoCount: media.filter { $0.type == .photo }.count,
            gifCount: media.filter { $0.type == .animatedGIF }.count,
            videoCount: media.filter { $0.type == .video }.count
        )
    }
}

struct BatchSaveResult: Equatable {
    let saved: Int
    let skipped: Int
    let failed: Int
    let issues: [String]
}

struct BrowserCapture: Equatable {
    let posts: [BookmarkedPost]
    let bottomCursor: String?
    let sourceURL: String
}
