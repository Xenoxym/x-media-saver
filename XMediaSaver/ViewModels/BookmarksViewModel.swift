import Combine
import Foundation

@MainActor
final class BookmarksViewModel: ObservableObject {
    @Published var filter = BookmarkFilter() {
        didSet { scheduleRecompute() }
    }
    @Published var searchText = "" {
        didSet { scheduleRecompute() }
    }
    @Published var searchField = BookmarkSearchField.all {
        didSet { scheduleRecompute() }
    }
    @Published var browseMode = BookmarkBrowseMode.posts {
        didSet { scheduleRecompute() }
    }
    @Published var accountSort = BookmarkAccountSort.countDescending {
        didSet { scheduleRecompute() }
    }
    @Published var postSort = BookmarkPostSort.newest {
        didSet { scheduleRecompute() }
    }
    @Published var hashtagSort = BookmarkHashtagSort.countDescending {
        didSet { scheduleRecompute() }
    }
    @Published var allowResaving = false {
        didSet { scheduleRecompute() }
    }

    @Published private(set) var visiblePosts: [BookmarkedPost] = []
    @Published private(set) var visibleAccountGroups: [BookmarkAccountGroup] = []
    @Published private(set) var visibleHashtagGroups: [BookmarkHashtagGroup] = []
    @Published private(set) var selectedMediaCount = 0
    @Published private(set) var alreadySavedCount = 0
    @Published private(set) var selectedStorageEstimate =
        MediaStorageEstimate.zero
    @Published private(set) var photoNewStorageEstimate =
        MediaStorageEstimate.zero
    @Published private(set) var filesNewStorageEstimate =
        MediaStorageEstimate.zero
    @Published private(set) var isSaving = false
    @Published private(set) var progress = BatchSaveProgress(
        completed: 0,
        total: 0,
        currentFraction: 0,
        currentType: nil
    )
    @Published private(set) var result: BatchSaveResult?
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress = FolderExportProgress(
        completed: 0,
        total: 0,
        currentFraction: 0,
        currentType: nil
    )
    @Published private(set) var exportResult: FolderExportResult?
    @Published var presentedError: PresentedError?

    private let saver: BatchMediaSaver
    private let exporter: FolderMediaExporter
    private let saveHistory: MediaSaveHistoryStore
    private var sourcePosts: [BookmarkedPost] = []
    private var savedMediaKeys: Set<String> = []
    private var localFileMediaKeys: Set<String> = []
    private var hashtagsByPostID: [String: [String]] = [:]
    private var saveTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var recomputeTask: Task<Void, Never>?

    init(
        saver: BatchMediaSaver = BatchMediaSaver(),
        exporter: FolderMediaExporter = FolderMediaExporter(),
        saveHistory: MediaSaveHistoryStore = MediaSaveHistoryStore()
    ) {
        self.saver = saver
        self.exporter = exporter
        self.saveHistory = saveHistory
        Task { [weak self] in
            guard let self else { return }
            savedMediaKeys = (try? await saveHistory.load()) ?? []
            localFileMediaKeys =
                await LocalMediaLibrary.shared.availableMediaKeys()
            recomputeNow()
        }
    }

    func update(posts: [BookmarkedPost]) {
        sourcePosts = posts
        let validIDs = Set(posts.map(\.id))
        hashtagsByPostID = hashtagsByPostID.filter {
            validIDs.contains($0.key)
        }
        scheduleRecompute()
    }

    func filteredPosts(from posts: [BookmarkedPost]) -> [BookmarkedPost] {
        calculateFilteredPosts(posts)
    }

    func accountGroups(from posts: [BookmarkedPost]) -> [BookmarkAccountGroup] {
        calculateAccountGroups(from: calculateFilteredPosts(posts))
    }

    func hashtagGroups(from posts: [BookmarkedPost]) -> [BookmarkHashtagGroup] {
        calculateHashtagGroups(from: calculateFilteredPosts(posts))
    }

    func selectedMedia(from posts: [BookmarkedPost]) -> [BookmarkedMedia] {
        deduplicatedMedia(from: calculateFilteredPosts(posts))
    }

    func startSaving(posts: [BookmarkedPost]) {
        update(posts: posts)
        guard !isSaving, !isExporting else { return }
        let allMedia = deduplicatedMedia(from: calculateFilteredPosts(posts))
        let media = allowResaving
            ? allMedia
            : allMedia.filter { !savedMediaKeys.contains($0.mediaKey) }
        let duplicateCount = allMedia.count - media.count

        guard !allMedia.isEmpty else {
            show(AppError.noMediaSelected)
            return
        }
        guard !media.isEmpty else {
            result = BatchSaveResult(
                saved: 0,
                skipped: duplicateCount,
                failed: 0,
                issues: ["全部筛选媒体此前已经成功保存；开启“允许重新保存”可再次写入。"]
            )
            return
        }

        result = nil
        progress = BatchSaveProgress(
            completed: 0,
            total: media.count,
            currentFraction: 0,
            currentType: nil
        )
        isSaving = true
        saveTask = Task { [weak self] in
            guard let self else { return }
            do {
                let savedResult = try await saver.save(
                    media,
                    didSave: { [saveHistory] media, _ in
                        _ = try? await saveHistory.insert(media.mediaKey)
                    },
                    progress: { update in
                        Task { @MainActor [weak self] in
                            self?.progress = update
                        }
                    }
                )
                savedMediaKeys = (try? await saveHistory.load())
                    ?? savedMediaKeys
                result = BatchSaveResult(
                    saved: savedResult.saved,
                    skipped: savedResult.skipped + duplicateCount,
                    failed: savedResult.failed,
                    issues: savedResult.issues
                )
                recomputeNow()
            } catch is CancellationError {
                // User cancellation is intentionally silent.
            } catch {
                show(error)
            }
            isSaving = false
            saveTask = nil
        }
    }

    func startExporting(
        posts: [BookmarkedPost],
        destination: URL = StorageManager.appDocumentsLibraryURL
    ) {
        update(posts: posts)
        guard !isSaving, !isExporting else { return }
        let filtered = calculateFilteredPosts(posts)
        let mediaByPostID = Dictionary(
            uniqueKeysWithValues: filtered.map {
                ($0.id, filter.media(in: $0))
            }
        )
        let total = mediaByPostID.values.flatMap { $0 }.count
        guard total > 0 else {
            show(AppError.noMediaSelected)
            return
        }

        exportResult = nil
        exportProgress = FolderExportProgress(
            completed: 0,
            total: total,
            currentFraction: 0,
            currentType: nil
        )
        isExporting = true
        exportTask = Task { [weak self] in
            guard let self else { return }
            do {
                let completedExport = try await exporter.export(
                    posts: filtered,
                    mediaByPostID: mediaByPostID,
                    destination: destination
                ) { update in
                    Task { @MainActor [weak self] in
                        self?.exportProgress = update
                    }
                }
                exportResult = completedExport
                await LocalMediaLibrary.shared.register(
                    root: completedExport.destination
                )
                localFileMediaKeys =
                    await LocalMediaLibrary.shared.availableMediaKeys()
                recomputeNow()
            } catch is CancellationError {
                // User cancellation is intentionally silent.
            } catch {
                show(error)
            }
            isExporting = false
            exportTask = nil
        }
    }

    func cancelCurrentOperation() {
        saver.cancel()
        exporter.cancel()
        saveTask?.cancel()
        exportTask?.cancel()
    }

    func clearPhotoSaveHistory() async {
        try? await saveHistory.clear()
        savedMediaKeys = []
        recomputeNow()
    }

    func markCurrentSelectionAsSaved(posts: [BookmarkedPost]) async {
        let media = deduplicatedMedia(from: calculateFilteredPosts(posts))
        for item in media {
            _ = try? await saveHistory.insert(item.mediaKey)
        }
        savedMediaKeys = (try? await saveHistory.load()) ?? savedMediaKeys
        recomputeNow()
    }

    static func hashtags(in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return hashtagExpression.matches(in: text, range: range).compactMap {
            guard let swiftRange = Range($0.range, in: text) else {
                return nil
            }
            return String(text[swiftRange].dropFirst())
        }
    }

    private func scheduleRecompute(immediate: Bool = false) {
        recomputeTask?.cancel()
        recomputeTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(nanoseconds: 280_000_000)
            }
            guard !Task.isCancelled, let self else { return }
            recomputeNow()
        }
    }

    private func recomputeNow() {
        let filtered = calculateFilteredPosts(sourcePosts)
        visiblePosts = filtered
        switch browseMode {
        case .accounts:
            visibleAccountGroups = calculateAccountGroups(from: filtered)
            visibleHashtagGroups = []
        case .posts:
            visibleAccountGroups = []
            visibleHashtagGroups = []
        case .hashtags:
            visibleAccountGroups = []
            visibleHashtagGroups = calculateHashtagGroups(from: filtered)
        }

        let allMedia = deduplicatedMedia(from: filtered)
        let photoNewMedia = allMedia.filter {
            !savedMediaKeys.contains($0.mediaKey)
        }
        let filesNewMedia = allMedia.filter {
            !localFileMediaKeys.contains($0.mediaKey)
        }
        alreadySavedCount = allMedia.count - photoNewMedia.count
        selectedStorageEstimate = MediaStorageEstimate(media: allMedia)
        photoNewStorageEstimate = MediaStorageEstimate(media: photoNewMedia)
        filesNewStorageEstimate = MediaStorageEstimate(media: filesNewMedia)
        selectedMediaCount = allowResaving
            ? allMedia.count
            : photoNewMedia.count
    }

    private func calculateFilteredPosts(
        _ posts: [BookmarkedPost]
    ) -> [BookmarkedPost] {
        posts
            .filter { filter.contains($0) && matchesSearch($0) }
            .sorted {
                postSort == .newest
                    ? Self.newestFirst($0, $1)
                    : Self.newestFirst($1, $0)
            }
    }

    private func calculateAccountGroups(
        from posts: [BookmarkedPost]
    ) -> [BookmarkAccountGroup] {
        let groups = Dictionary(grouping: posts) {
            $0.authorID ?? $0.authorUsername?.lowercased() ?? "unknown-author"
        }
        return groups.map { key, posts in
            let first = posts.first
            return BookmarkAccountGroup(
                id: key,
                authorID: first?.authorID,
                authorName: first?.authorName,
                authorUsername: first?.authorUsername,
                posts: posts
            )
        }
        .sorted { lhs, rhs in
            switch accountSort {
            case .countDescending:
                if lhs.posts.count != rhs.posts.count {
                    return lhs.posts.count > rhs.posts.count
                }
                return Self.accountLabel(lhs)
                    .localizedCaseInsensitiveCompare(Self.accountLabel(rhs))
                    == .orderedAscending
            case .handleAscending:
                return (lhs.authorUsername ?? "\u{10FFFF}")
                    .localizedCaseInsensitiveCompare(
                        rhs.authorUsername ?? "\u{10FFFF}"
                    ) == .orderedAscending
            case .nameAscending:
                return (lhs.authorName ?? "\u{10FFFF}")
                    .localizedCaseInsensitiveCompare(
                        rhs.authorName ?? "\u{10FFFF}"
                    ) == .orderedAscending
            }
        }
    }

    private func calculateHashtagGroups(
        from posts: [BookmarkedPost]
    ) -> [BookmarkHashtagGroup] {
        var grouped: [String: (title: String, posts: [BookmarkedPost])] = [:]
        for post in posts {
            for hashtag in cachedHashtags(for: post) {
                let key = hashtag.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )
                var group = grouped[key] ?? (title: hashtag, posts: [])
                group.posts.append(post)
                grouped[key] = group
            }
        }
        return grouped.map {
            BookmarkHashtagGroup(
                id: $0.key,
                title: $0.value.title,
                posts: $0.value.posts
            )
        }
        .sorted {
            switch hashtagSort {
            case .countDescending:
                if $0.posts.count != $1.posts.count {
                    return $0.posts.count > $1.posts.count
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title)
                    == .orderedAscending
            case .nameAscending:
                return $0.title.localizedCaseInsensitiveCompare($1.title)
                    == .orderedAscending
            }
        }
    }

    private func deduplicatedMedia(
        from posts: [BookmarkedPost]
    ) -> [BookmarkedMedia] {
        var seen: Set<String> = []
        return posts
            .flatMap { filter.media(in: $0) }
            .filter { seen.insert($0.mediaKey).inserted }
    }

    private func matchesSearch(_ post: BookmarkedPost) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let plainQuery = query.trimmingCharacters(
            in: CharacterSet(charactersIn: "@#")
        )
        let accountMatches = contains(post.authorUsername, query: plainQuery)
            || contains(post.authorName, query: query)
            || contains(post.authorID, query: plainQuery)
        let contentMatches = contains(post.text, query: query)
        let hashtagMatches = cachedHashtags(for: post).contains {
            contains($0, query: plainQuery)
        }

        switch searchField {
        case .all:
            return accountMatches || contentMatches || hashtagMatches
        case .account:
            return accountMatches
        case .content:
            return contentMatches
        case .hashtag:
            return hashtagMatches
        }
    }

    private func cachedHashtags(for post: BookmarkedPost) -> [String] {
        if let cached = hashtagsByPostID[post.id] {
            return cached
        }
        let value = Self.hashtags(in: post.text)
        hashtagsByPostID[post.id] = value
        return value
    }

    private func contains(_ value: String?, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return value?.localizedCaseInsensitiveContains(query) == true
    }

    private func show(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        presentedError = PresentedError(
            message: message,
            offersSettings: (error as? AppError) == .photoPermissionDenied
        )
    }

    private static func newestFirst(
        _ lhs: BookmarkedPost,
        _ rhs: BookmarkedPost
    ) -> Bool {
        switch (lhs.createdAt, rhs.createdAt) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.id > rhs.id
        }
    }

    private static func accountLabel(_ group: BookmarkAccountGroup) -> String {
        group.authorUsername ?? group.authorName ?? group.authorID ?? ""
    }

    private static let hashtagExpression: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"#[\p{L}\p{M}\p{N}_]+"#)
    }()
}
