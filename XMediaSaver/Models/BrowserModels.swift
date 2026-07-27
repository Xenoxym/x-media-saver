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
        case .posts: return "帖子"
        case .accounts: return "账号"
        case .hashtags: return "标签"
        }
    }
}

enum BookmarkPostPreviewMode: String {
    case media
    case text
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
    case bookmarkNewest
    case bookmarkOldest
    case newest
    case oldest

    var id: String { rawValue }
    var title: String {
        switch self {
        case .bookmarkNewest: return "最近加入书签"
        case .bookmarkOldest: return "最早加入书签"
        case .newest: return "最新发布"
        case .oldest: return "最早发布"
        }
    }
}

enum BookmarkHashtagSort: String, CaseIterable, Identifiable {
    case countDescending
    case nameAscending

    var id: String { rawValue }
    var title: String {
        self == .countDescending ? "帖子数从多到少" : "标签名称排序"
    }
}

enum MediaDurationLimit: Int, CaseIterable, Identifiable {
    case zero
    case oneMinute
    case tenMinutes
    case thirtyMinutes
    case oneHour
    case unlimited

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .zero: return "0"
        case .oneMinute: return "1 分钟"
        case .tenMinutes: return "10 分钟"
        case .thirtyMinutes: return "30 分钟"
        case .oneHour: return "1 小时"
        case .unlimited: return "不限制"
        }
    }

    var milliseconds: Int? {
        switch self {
        case .zero: return 0
        case .oneMinute: return 60_000
        case .tenMinutes: return 10 * 60_000
        case .thirtyMinutes: return 30 * 60_000
        case .oneHour: return 60 * 60_000
        case .unlimited: return nil
        }
    }
}

enum MediaSizeLimit: Int, CaseIterable, Identifiable {
    case zero
    case tenMB
    case fiftyMB
    case twoHundredMB
    case fiveHundredMB
    case unlimited

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .zero: return "0"
        case .tenMB: return "10 MB"
        case .fiftyMB: return "50 MB"
        case .twoHundredMB: return "200 MB"
        case .fiveHundredMB: return "500 MB"
        case .unlimited: return "不限制"
        }
    }

    var bytes: Int64? {
        let mb: Int64 = 1_048_576
        switch self {
        case .zero: return 0
        case .tenMB: return 10 * mb
        case .fiftyMB: return 50 * mb
        case .twoHundredMB: return 200 * mb
        case .fiveHundredMB: return 500 * mb
        case .unlimited: return nil
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
    var minimumDuration = MediaDurationLimit.zero
    var maximumDuration = MediaDurationLimit.unlimited
    var minimumSize = MediaSizeLimit.zero
    var maximumSize = MediaSizeLimit.unlimited

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
        guard matchesSize(post.totalKnownByteSize) else {
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
        if checksPostRange && !matchesSize(post.totalKnownByteSize) {
            return []
        }
        return post.media.filter { media in
            guard selectedTypes.contains(media.type) else { return false }
            if media.type == .video || media.type == .animatedGIF {
                return matchesDuration(media.durationMilliseconds)
            }
            return true
        }
    }

    private func matchesDuration(_ milliseconds: Int?) -> Bool {
        guard let milliseconds else {
            return minimumDuration == .zero
                && maximumDuration == .unlimited
        }
        guard let minimum = minimumDuration.milliseconds,
              milliseconds >= minimum
        else {
            return false
        }
        guard let maximum = maximumDuration.milliseconds else {
            return true
        }
        return milliseconds < maximum
    }

    private func matchesSize(_ bytes: Int64?) -> Bool {
        guard let bytes else {
            return minimumSize == .zero && maximumSize == .unlimited
        }
        guard let minimum = minimumSize.bytes, bytes >= minimum else {
            return false
        }
        guard let maximum = maximumSize.bytes else {
            return true
        }
        return bytes < maximum
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

struct MediaStorageEstimate: Equatable {
    let itemCount: Int
    let knownBytes: Int64
    let unknownSizeCount: Int

    static let zero = MediaStorageEstimate(
        itemCount: 0,
        knownBytes: 0,
        unknownSizeCount: 0
    )

    init(media: [BookmarkedMedia]) {
        itemCount = media.count
        knownBytes = media.compactMap(\.byteSize).reduce(0, +)
        unknownSizeCount = media.filter { $0.byteSize == nil }.count
    }

    init(itemCount: Int, knownBytes: Int64, unknownSizeCount: Int) {
        self.itemCount = itemCount
        self.knownBytes = knownBytes
        self.unknownSizeCount = unknownSizeCount
    }
}

struct BrowserCapture: Equatable {
    let posts: [BookmarkedPost]
    let bottomCursor: String?
    let sourceURL: String
}
