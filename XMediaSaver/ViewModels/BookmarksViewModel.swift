import Combine
import Foundation

@MainActor
final class BookmarksViewModel: ObservableObject {
    @Published var filter: BookmarkFilter {
        didSet {
            Self.saveFilter(filter)
            scheduleRecompute()
        }
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
    @Published var postSort = BookmarkPostSort.bookmarkNewest {
        didSet { scheduleRecompute() }
    }
    @Published var hashtagSort = BookmarkHashtagSort.countDescending {
        didSet { scheduleRecompute() }
    }
    @Published var localSaveFilter = BookmarkLocalSaveFilter.all {
        didSet { scheduleRecompute() }
    }
    @Published var categoryRules: [BookmarkRuleCategory] = [] {
        didSet { if oldValue != categoryRules { scheduleRecompute() } }
    }
    @Published private(set) var visiblePosts: [BookmarkedPost] = []
    @Published private(set) var visibleAccountGroups: [BookmarkAccountGroup] = []
    @Published private(set) var visibleHashtagGroups: [BookmarkHashtagGroup] = []
    @Published private(set) var visibleRuleGroups: [BookmarkRuleGroup] = []
    @Published private(set) var isGroupingRules = false
    @Published private(set) var selectedMediaCount = 0
    @Published private(set) var selectedMediaKeys: Set<String> = []
    @Published private(set) var selectedStorageEstimate =
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
    @Published private(set) var saveFailures: [SaveFailureRecord] = []
    @Published private(set) var unavailablePosts: [SaveFailureRecord] = []
    @Published var presentedError: PresentedError?

    private let saver: BatchMediaSaver
    private let exporter: FolderMediaExporter
    private let failureStore: MediaSaveFailureStore
    private let unavailablePostStore: MediaSaveFailureStore
    private var sourcePosts: [BookmarkedPost] = []
    private var localFileMediaKeys: Set<String> = []
    private var hashtagsByPostID: [String: [String]] = [:]
    private var ruleDocuments: [String: BookmarkRuleDocumentCacheEntry] = [:]
    private var ruleGroupingTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var recomputeTask: Task<Void, Never>?

    init(
        saver: BatchMediaSaver = BatchMediaSaver(),
        exporter: FolderMediaExporter = FolderMediaExporter(),
        failureStore: MediaSaveFailureStore = MediaSaveFailureStore(),
        unavailablePostStore: MediaSaveFailureStore = MediaSaveFailureStore(
            fileURL: StorageManager.appDocumentsLibraryURL
                .appendingPathComponent("unavailable-posts.json")
        ),
        localMediaKeys: Set<String>? = nil
    ) {
        filter = Self.loadSavedFilter()
        self.saver = saver
        self.exporter = exporter
        self.failureStore = failureStore
        self.unavailablePostStore = unavailablePostStore
        self.localFileMediaKeys = localMediaKeys ?? []
        Task { [weak self] in
            guard let self else { return }
            if localMediaKeys == nil { localFileMediaKeys = await LocalMediaLibrary.shared.recordedMediaKeys() }
            let storedFailures = (try? await failureStore.load()) ?? []
            saveFailures = storedFailures
            var storedUnavailable =
                (try? await unavailablePostStore.load()) ?? []
            if storedUnavailable.isEmpty, !storedFailures.isEmpty {
                var reasons: [String: String] = [:]
                for record in storedFailures {
                    reasons.merge(
                        record.failureReasons,
                        uniquingKeysWith: { _, new in new }
                    )
                }
                storedUnavailable = (
                    try? await unavailablePostStore.recordAttempt(
                        posts: storedFailures.map(\.post),
                        successfulMediaKeys: [],
                        failureReasons: reasons
                    )
                ) ?? []
            }
            unavailablePosts = storedUnavailable
            recomputeNow()
        }
    }

    func reloadUnavailablePosts() {
        Task { [weak self] in
            guard let self else { return }
            unavailablePosts =
                (try? await unavailablePostStore.reload()) ?? []
            saveFailures = (try? await failureStore.reload()) ?? saveFailures
        }
    }

    func refreshLocalMedia() async {
        let updated = await LocalMediaLibrary.shared.recordedMediaKeys()
        guard updated != localFileMediaKeys else { return }
        localFileMediaKeys = updated
        recomputeNow()
    }

    func update(posts: [BookmarkedPost]) {
        sourcePosts = posts
        let validIDs = Set(posts.map(\.id))
        hashtagsByPostID = hashtagsByPostID.filter {
            validIDs.contains($0.key)
        }
        ruleDocuments = ruleDocuments.filter { validIDs.contains($0.key) }
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

    func filteredMedia(in post: BookmarkedPost) -> [BookmarkedMedia] {
        filter.media(in: post).filter { localSaveFilter.matches($0, localKeys: localFileMediaKeys) }
    }

    func startSaving(posts: [BookmarkedPost]) {
        update(posts: posts)
        guard !isSaving, !isExporting else { return }
        let attemptedPosts = calculateFilteredPosts(posts)
        let media = deduplicatedMedia(from: attemptedPosts)

        guard !media.isEmpty else {
            show(AppError.noMediaSelected)
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
                    didSave: { _, _ in },
                    progress: { update in
                        Task { @MainActor [weak self] in
                            self?.progress = update
                        }
                    }
                )
                result = savedResult
                await updateSaveFailures(
                    posts: attemptedPosts,
                    successfulMediaKeys: savedResult.successfulMediaKeys,
                    failureReasons: savedResult.failureReasons
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
                ($0.id, filteredMedia(in: $0))
            }
        )
        let total = mediaByPostID.values.flatMap { $0 }.count
        let selectedIDs = Set(filtered.map(\.id))
        let exclusions = Dictionary(uniqueKeysWithValues: posts.filter { !selectedIDs.contains($0.id) }.map { post in
            (post.id, post.media.isEmpty ? "no_parsed_media" : "filter_search_or_local_save_state")
        })

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
                    auditPosts: posts,
                    exclusionReasons: exclusions,
                    destination: destination
                ) { update in
                    Task { @MainActor [weak self] in
                        self?.exportProgress = update
                    }
                }
                exportResult = completedExport
                await updateSaveFailures(
                    posts: filtered,
                    successfulMediaKeys: completedExport.successfulMediaKeys,
                    failureReasons: completedExport.failureReasons
                )
                unavailablePosts =
                    (try? await unavailablePostStore.reload()) ?? []
                await LocalMediaLibrary.shared.register(
                    root: completedExport.destination
                )
                localFileMediaKeys =
                    await LocalMediaLibrary.shared.recordedMediaKeys()
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
        ruleGroupingTask?.cancel()
        if browseMode != .rules { visibleRuleGroups = []; isGroupingRules = false }
        switch browseMode {
        case .posts:
            visibleAccountGroups = []
            visibleHashtagGroups = []
        case .accounts:
            visibleAccountGroups = calculateAccountGroups(from: filtered)
            visibleHashtagGroups = []
        case .hashtags:
            visibleAccountGroups = []
            visibleHashtagGroups = calculateHashtagGroups(from: filtered)
        case .rules:
            visibleAccountGroups = []
            visibleHashtagGroups = []
            isGroupingRules = true
            let rules = categoryRules
            let cached = ruleDocuments
            ruleGroupingTask = Task { [weak self] in
                let work = Task.detached(priority: .userInitiated) {
                    try BookmarkRuleGrouping.build(posts: filtered, rules: rules, cache: cached)
                }
                do {
                    let result = try await withTaskCancellationHandler { try await work.value }
                        onCancel: { work.cancel() }
                    guard !Task.isCancelled, let self, self.browseMode == .rules else { return }
                    self.ruleDocuments = result.cache
                    self.visibleRuleGroups = result.groups
                    self.isGroupingRules = false
                } catch {
                    if !Task.isCancelled { self?.isGroupingRules = false }
                }
            }
        }

        let allMedia = deduplicatedMedia(from: filtered)
        let filesNewMedia = allMedia.filter {
            !localFileMediaKeys.contains($0.mediaKey)
        }
        selectedStorageEstimate = MediaStorageEstimate(media: allMedia)
        filesNewStorageEstimate = MediaStorageEstimate(media: filesNewMedia)
        selectedMediaCount = allMedia.count
        selectedMediaKeys = Set(allMedia.map(\.mediaKey))
    }

    private func calculateFilteredPosts(
        _ posts: [BookmarkedPost]
    ) -> [BookmarkedPost] {
        let filtered = posts.filter {
            filter.contains($0) && matchesSearch($0) && !filteredMedia(in: $0).isEmpty
        }
        return BookmarkPostOrdering.sorted(filtered, by: postSort)
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
            .flatMap { filteredMedia(in: $0) }
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

    private func updateSaveFailures(
        posts: [BookmarkedPost],
        successfulMediaKeys: Set<String>,
        failureReasons: [String: String]
    ) async {
        guard let updated = try? await failureStore.recordAttempt(
            posts: posts,
            successfulMediaKeys: successfulMediaKeys,
            failureReasons: failureReasons
        ) else { return }
        saveFailures = updated
    }

    private static let filterDefaultsKey = "bookmarkDownloadBrowseFilter"

    private static func loadSavedFilter() -> BookmarkFilter {
        guard let data = UserDefaults.standard.data(
            forKey: filterDefaultsKey
        ), let filter = try? JSONDecoder().decode(
            BookmarkFilter.self,
            from: data
        ) else {
            return BookmarkFilter()
        }
        return filter
    }

    private static func saveFilter(_ filter: BookmarkFilter) {
        guard let data = try? JSONEncoder().encode(filter) else { return }
        UserDefaults.standard.set(data, forKey: filterDefaultsKey)
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
