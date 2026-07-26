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
    let byteSize: Int64?
    let sizeProbeCompleted: Bool?

    var id: String { mediaKey }

    init(
        mediaKey: String,
        type: BookmarkMediaType,
        url: URL?,
        previewImageURL: URL?,
        variants: [XMediaVariant],
        width: Int?,
        height: Int?,
        durationMilliseconds: Int?,
        byteSize: Int64? = nil,
        sizeProbeCompleted: Bool? = nil
    ) {
        self.mediaKey = mediaKey
        self.type = type
        self.url = url
        self.previewImageURL = previewImageURL
        self.variants = variants
        self.width = width
        self.height = height
        self.durationMilliseconds = durationMilliseconds
        self.byteSize = byteSize
        self.sizeProbeCompleted = sizeProbeCompleted
    }

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
        case byteSize = "byte_size"
        case sizeProbeCompleted = "size_probe_completed"
    }
}

struct BookmarkedPost: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let text: String
    let createdAt: Date?
    let authorID: String?
    let authorName: String?
    let authorUsername: String?
    let media: [BookmarkedMedia]
}

enum BookmarkBrowseMode: String, CaseIterable, Identifiable {
    case posts
    case accounts
    case hashtags

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accounts: return "账号"
        case .posts: return "帖子"
        case .hashtags: return "标签"
        }
    }
}

enum BookmarkSearchField: String, CaseIterable, Identifiable {
    case all
    case account
    case content
    case hashtag

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .account: return "账号"
        case .content: return "正文"
        case .hashtag: return "Hashtag"
        }
    }
}

enum BookmarkPostSort: String, CaseIterable, Identifiable {
    case newest
    case oldest

    var id: String { rawValue }
    var title: String { self == .newest ? "最新优先" : "最早优先" }
}

enum BookmarkHashtagSort: String, CaseIterable, Identifiable {
    case countDescending
    case nameAscending

    var id: String { rawValue }
    var title: String {
        self == .countDescending ? "帖子数从多到少" : "标签名称排序"
    }
}

enum MediaDurationRange: String, CaseIterable, Identifiable {
    case all
    case underOneMinute
    case oneToTenMinutes
    case tenToThirtyMinutes
    case thirtyToSixtyMinutes
    case overOneHour
    case unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "不限时长"
        case .underOneMinute: return "1 分钟以内"
        case .oneToTenMinutes: return "1–10 分钟"
        case .tenToThirtyMinutes: return "10–30 分钟"
        case .thirtyToSixtyMinutes: return "30–60 分钟"
        case .overOneHour: return "1 小时以上"
        case .unknown: return "时长未知"
        }
    }

    func contains(milliseconds: Int?) -> Bool {
        guard self != .all else { return true }
        guard let milliseconds else { return self == .unknown }
        let minute = 60_000
        switch self {
        case .all, .unknown: return false
        case .underOneMinute: return milliseconds < minute
        case .oneToTenMinutes:
            return milliseconds >= minute && milliseconds < 10 * minute
        case .tenToThirtyMinutes:
            return milliseconds >= 10 * minute && milliseconds < 30 * minute
        case .thirtyToSixtyMinutes:
            return milliseconds >= 30 * minute && milliseconds < 60 * minute
        case .overOneHour: return milliseconds >= 60 * minute
        }
    }
}

enum MediaSizeRange: String, CaseIterable, Identifiable {
    case all
    case underTenMB
    case tenToFiftyMB
    case fiftyToTwoHundredMB
    case twoHundredToFiveHundredMB
    case overFiveHundredMB
    case unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "不限大小"
        case .underTenMB: return "10 MB 以下"
        case .tenToFiftyMB: return "10–50 MB"
        case .fiftyToTwoHundredMB: return "50–200 MB"
        case .twoHundredToFiveHundredMB: return "200–500 MB"
        case .overFiveHundredMB: return "500 MB 以上"
        case .unknown: return "大小未知"
        }
    }

    func contains(bytes: Int64?) -> Bool {
        guard self != .all else { return true }
        guard let bytes else { return self == .unknown }
        let mb: Int64 = 1_048_576
        switch self {
        case .all, .unknown: return false
        case .underTenMB: return bytes < 10 * mb
        case .tenToFiftyMB: return bytes >= 10 * mb && bytes < 50 * mb
        case .fiftyToTwoHundredMB:
            return bytes >= 50 * mb && bytes < 200 * mb
        case .twoHundredToFiveHundredMB:
            return bytes >= 200 * mb && bytes < 500 * mb
        case .overFiveHundredMB: return bytes >= 500 * mb
        }
    }
}

enum BookmarkAccountSort: String, CaseIterable, Identifiable {
    case countDescending
    case handleAscending
    case nameAscending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .countDescending: return "帖子数从多到少"
        case .handleAscending: return "@用户名排序"
        case .nameAscending: return "显示昵称排序"
        }
    }
}

struct BookmarkAccountGroup: Identifiable {
    let id: String
    let authorID: String?
    let authorName: String?
    let authorUsername: String?
    let posts: [BookmarkedPost]
}

struct BookmarkHashtagGroup: Identifiable {
    let id: String
    let title: String
    let posts: [BookmarkedPost]
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
    var durationRange = MediaDurationRange.all
    var sizeRange = MediaSizeRange.all

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
        guard sizeRange.contains(bytes: post.totalKnownByteSize) else {
            return false
        }
        return !media(in: post, checksPostRange: false).isEmpty
    }

    func media(in post: BookmarkedPost) -> [BookmarkedMedia] {
        guard contains(post) else { return [] }
        return media(in: post, checksPostRange: false)
    }

    private func media(
        in post: BookmarkedPost,
        checksPostRange: Bool
    ) -> [BookmarkedMedia] {
        if checksPostRange && !sizeRange.contains(bytes: post.totalKnownByteSize) {
            return []
        }
        return post.media.filter { media in
            guard selectedTypes.contains(media.type) else { return false }
            if media.type == .video || media.type == .animatedGIF {
                return durationRange.contains(
                    milliseconds: media.durationMilliseconds
                )
            }
            return durationRange == .all
        }
    }
}

extension BookmarkedPost {
    var totalKnownByteSize: Int64? {
        guard !media.isEmpty, media.allSatisfy({ $0.byteSize != nil }) else {
            return nil
        }
        return media.compactMap(\.byteSize).reduce(0, +)
    }

    var postURL: URL? {
        guard let authorUsername else { return nil }
        return URL(string: "https://x.com/\(authorUsername)/status/\(id)")
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
