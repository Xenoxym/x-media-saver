import XCTest
@testable import XMediaSaver

final class BookmarkModelsTests: XCTestCase {
    func testThumbnailURLRetainsXImageFormat() {
        let input = URL(string: "https://pbs.twimg.com/media/example?format=png&name=orig")!
        let preview = LocalMediaThumbnailLoader.previewURL(input, name: "small")!
        let query = URLComponents(url: preview, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "format" }?.value, "png")
        XCTAssertEqual(query.first { $0.name == "name" }?.value, "small")
    }

    func testHashtagSuggestionsPreferCooccurrenceThenFrequency() throws {
        let posts = [
            makePost(id: "1", date: nil, types: [], text: "#Art #portrait"),
            makePost(id: "2", date: nil, types: [], text: "#art #portrait"),
            makePost(id: "3", date: nil, types: [], text: "#art #lineart"),
            makePost(id: "4", date: nil, types: [], text: "#popular"),
            makePost(id: "5", date: nil, types: [], text: "#popular")
        ]
        let index = try BookmarkSuggestionIndex(posts: posts + [posts[0]])
        XCTAssertEqual(index.tagCounts["art"], 3)
        let related = try index.tags(query: "", selected: ["ART"])
        XCTAssertEqual(related.map(\.term), ["portrait", "lineart", "popular"])
        XCTAssertEqual(related[0].cooccurrence, 2)
        XCTAssertEqual(try index.tags(query: "port", selected: []).map(\.term), ["portrait"])
        XCTAssertEqual(try index.tags(query: "", selected: [], limit: 2).count, 2)
    }

    func testKeywordSuggestionsCountPostsNotRepeatedWordsAndStripLinks() throws {
        let posts = [
            makePost(id: "1", date: nil, types: [], text: "#art soft lighting lighting @Artist https://example.com/unrelated"),
            makePost(id: "2", date: nil, types: [], text: "#art soft lighting and the"),
            makePost(id: "3", date: nil, types: [], text: "#other unrelated")
        ]
        let index = try BookmarkSuggestionIndex(posts: posts)
        let suggestions = try index.keywords(hashtags: ["ART"], excluding: [])
        let counts = Dictionary(uniqueKeysWithValues: suggestions.map { ($0.term, $0.count) })
        XCTAssertEqual(counts["lighting"], 2)
        XCTAssertEqual(counts["soft"], 2)
        XCTAssertNil(counts["art"])
        XCTAssertNil(counts["artist"])
        XCTAssertNil(counts["unrelated"])
        XCTAssertNil(counts["the"])
        XCTAssertFalse(try index.keywords(hashtags: ["art"], excluding: ["soft"]).contains { $0.term == "soft" })
    }

    func testRecordedAvailabilityDoesNotRescanFilesOnNavigationAndMissingFilesAreLogged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Images"), withIntermediateDirectories: true)
        let state = try lineData([ExportStateRecord(mediaKey: "missing", relativePath: "Images/missing.jpg")])
        try state.write(to: root.appendingPathComponent("export-state.jsonl"))
        let library = LocalMediaLibrary(roots: [root])
        let recorded = await library.recordedMediaKeys()
        XCTAssertEqual(recorded, ["missing"])
        let url = await library.localURL(for: "missing")
        XCTAssertNil(url)
        let updated = await library.recordedMediaKeys()
        XCTAssertTrue(updated.isEmpty)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("export-state.jsonl")), state)
        let issues = await LocalFileIssueLog.shared.records(root: root)
        XCTAssertEqual(issues.first?.path, "Images/missing.jpg")
        try Data([1]).write(to: root.appendingPathComponent("Images/missing.jpg"))
        await library.reload()
        let restored = await library.localURL(for: "missing")
        XCTAssertNotNil(restored)
    }

    func testFileInventorySeparatesUnlinkedMediaFromMissingReferences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Images"), withIntermediateDirectories: true)
        for name in ["linked.jpg", "unlinked.jpg", "state-only.jpg"] {
            try Data([1, 2, 3]).write(to: root.appendingPathComponent("Images/" + name))
        }
        try Data().write(to: root.appendingPathComponent("Images/empty.jpg"))
        let records = ["linked", "missing", "empty", "state-only"].map {
            ExportStateRecord(mediaKey: $0, relativePath: "Images/" + $0 + ".jpg")
        }
        try lineData(records).write(to: root.appendingPathComponent("export-state.jsonl"))
        let post = ExportedPostRecord(id: "post", postURL: nil, text: "retained", createdAt: nil,
            authorID: nil, authorName: nil, authorUsername: nil,
            media: ["linked", "missing", "empty"].map {
                ExportedMediaRecord(mediaKey: $0, type: .photo, remoteURL: nil,
                    localRelativePath: "Images/" + $0 + ".jpg", width: nil, height: nil,
                    durationMilliseconds: nil, byteSize: nil)
            })
        try lineData([post]).write(to: root.appendingPathComponent("posts.jsonl"))
        let tree = try await LibraryStorageScanner().scan(root: root)
        let report = try LibraryIntegrityInspector.inspect(root: root, tree: tree)
        XCTAssertEqual(Set(report.untrackedFiles.map(\.name)), ["unlinked.jpg", "state-only.jpg"])
        XCTAssertEqual(Set(report.issues.map(\.path)), ["Images/missing.jpg", "Images/empty.jpg"])
        XCTAssertTrue(report.metadataWarnings.isEmpty)
        let restored = try await LocalFolderLibrary(root: root).loadPosts()
        XCTAssertEqual(restored.first?.text, "retained")
    }

    func testCorruptInventoryMetadataIsReportedWithoutRewritingIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let damaged = Data("invalid manifest".utf8)
        try damaged.write(to: root.appendingPathComponent("posts.jsonl"))
        let tree = try await LibraryStorageScanner().scan(root: root)
        let report = try LibraryIntegrityInspector.inspect(root: root, tree: tree)
        XCTAssertEqual(report.metadataWarnings, ["posts.jsonl:1"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("posts.jsonl")), damaged)
    }

    func testFileIssueHistoryIsBounded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let issues = (0..<250).map { LocalFileIssue(path: "Images/\($0).jpg", reason: "missing", mediaKeys: [], observedAt: Date()) }
        await LocalFileIssueLog.shared.record(issues, root: root)
        let records = await LocalFileIssueLog.shared.records(root: root)
        XCTAssertEqual(records.count, 200)
    }

    func testScopedPostSearchMatchesAccountTextAndUnicodeTags() throws {
        let post = makePost(id: "search", date: nil, types: [.photo], text: "Café skyline #旅行 #Travel",
            authorID: "12345", authorName: "Alice", authorUsername: "alice_handle")
        let document = BookmarkSearchDocument(post: post)
        XCTAssertTrue(document.matches(query: " @ALICE_HANDLE ", field: .account))
        XCTAssertTrue(document.matches(query: "12345", field: .account))
        XCTAssertTrue(document.matches(query: "cafe", field: .content))
        XCTAssertTrue(document.matches(query: "#旅行", field: .hashtag))
        XCTAssertTrue(document.matches(query: "#TRAVEL", field: .hashtag))
        XCTAssertFalse(document.matches(query: "skyline", field: .account))
        XCTAssertFalse(document.matches(query: "Alice", field: .hashtag))
    }

    func testBackgroundSizeUpdatesDoNotInvalidateGallerySearchSource() {
        let first = sizedPost("same", bytes: nil)
        let analyzed = sizedPost("same", bytes: 500)
        XCTAssertEqual(BookmarkSearchSourceFingerprint(post: first), BookmarkSearchSourceFingerprint(post: analyzed))
        let edited = BookmarkedPost(id: first.id, text: "new text", createdAt: nil,
            authorID: nil, authorName: nil, authorUsername: nil, media: first.media)
        XCTAssertNotEqual(BookmarkSearchSourceFingerprint(post: first), BookmarkSearchSourceFingerprint(post: edited))
    }

    func testRuleGroupsJoinRelatedHashtagsAndUntaggedKeywords() throws {
        let posts = [
            makePost(id: "tag", date: nil, types: [.photo], text: "A trip #旅行"),
            makePost(id: "keyword", date: nil, types: [.photo], text: "Beautiful LANDSCAPE today"),
            makePost(id: "not-exact", date: nil, types: [.photo], text: "#travelogue")
        ]
        let rule = BookmarkRuleCategory(name: "Travel", hashtags: ["travel", "旅行"], keywords: ["landscape"])
        let matched = try BookmarkSearchEngine.matchingPostIDs(documents: posts.map(BookmarkSearchDocument.init), query: "", field: .all, rule: rule)
        XCTAssertEqual(matched, ["tag", "keyword"])
        let narrowed = try BookmarkSearchEngine.matchingPostIDs(documents: posts.map(BookmarkSearchDocument.init), query: "Beautiful", field: .content, rule: rule)
        XCTAssertEqual(narrowed, ["keyword"])
        var disabled = rule
        disabled.isEnabled = false
        let off = try BookmarkSearchEngine.matchingPostIDs(documents: posts.map(BookmarkSearchDocument.init), query: "", field: .all, rule: disabled)
        XCTAssertTrue(off.isEmpty)
    }

    func testPostCanBelongToMultipleRuleGroups() {
        let doc = BookmarkSearchDocument(post: makePost(id: "both", date: nil, types: [], text: "#travel #photo"))
        XCTAssertTrue(BookmarkRuleCategory(name: "Travel", hashtags: ["TRAVEL"], keywords: []).matcher.matches(doc))
        XCTAssertTrue(BookmarkRuleCategory(name: "Photos", hashtags: ["photo"], keywords: []).matcher.matches(doc))
    }

    func testRuleGroupingRefreshesCachedTextAndPreservesInputOrder() throws {
        let rule = BookmarkRuleCategory(name: "Trips", hashtags: ["travel"], keywords: ["landscape"])
        let one = makePost(id: "one", date: nil, types: [.photo], text: "#travel")
        let two = makePost(id: "two", date: nil, types: [.photo], text: "landscape")
        let first = try BookmarkRuleGrouping.build(posts: [two, one], rules: [rule])
        XCTAssertEqual(first.groups[0].posts.map(\.id), ["two", "one"])
        let changed = makePost(id: "two", date: nil, types: [.photo], text: "unrelated")
        let second = try BookmarkRuleGrouping.build(posts: [changed, one], rules: [rule], cache: first.cache)
        XCTAssertEqual(second.groups[0].posts.map(\.id), ["one"])
    }

    func testRuleTermsKeepPhrasesAndDeduplicateCaseInsensitiveSynonyms() {
        XCTAssertEqual(BookmarkRuleCategory.terms(from: "#Travel\ntravel，＃旅行", hashtags: true), ["Travel", "旅行"])
        XCTAssertEqual(BookmarkRuleCategory.terms(from: "blue archive\nBlue Archive、风景", hashtags: false), ["blue archive", "风景"])
    }

    func testSearchSharedMediaKeepsMatchingLaterPostAssociation() throws {
        let media = sizedPost("shared", bytes: 3).media
        let alice = BookmarkedPost(id: "alice", text: "", createdAt: nil, authorID: nil, authorName: "Alice", authorUsername: "alice", media: media)
        let bob = BookmarkedPost(id: "bob", text: "", createdAt: nil, authorID: nil, authorName: "Bob", authorUsername: "bob", media: media)
        let posts = [alice, bob]
        let ids = try BookmarkSearchEngine.matchingPostIDs(documents: posts.map(BookmarkSearchDocument.init), query: "bob", field: .account)
        let matched = posts.filter { ids.contains($0.id) }
        XCTAssertEqual(matched.map(\.id), ["bob"])
        XCTAssertEqual(matched.flatMap(\.media).map(\.mediaKey), ["shared"])
    }

    @MainActor
    func testRuleStorePersistsEditingDisablingAndDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rule-categories.json")
        let store = BookmarkRuleStore(fileURL: url)
        var rule = BookmarkRuleCategory(name: "Trips", hashtags: ["travel"], keywords: ["landscape"])
        try store.upsert(rule)
        let reloaded = BookmarkRuleStore(fileURL: url)
        XCTAssertEqual(reloaded.rules, [rule])
        rule.isEnabled = false
        try reloaded.upsert(rule)
        XCTAssertFalse(BookmarkRuleStore(fileURL: url).rules[0].isEnabled)
        try reloaded.remove([rule.id])
        XCTAssertTrue(BookmarkRuleStore(fileURL: url).rules.isEmpty)
    }

    @MainActor
    func testCorruptRuleFileIsNotOverwrittenByAnEdit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("rule-categories.json")
        let original = Data("invalid rules".utf8)
        try original.write(to: url)
        let store = BookmarkRuleStore(fileURL: url)
        XCTAssertNotNil(store.loadError)
        XCTAssertThrowsError(try store.upsert(BookmarkRuleCategory(name: "test", hashtags: ["test"], keywords: [])))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testSafeMediaPathsAcceptDirectoryURLsWithTrailingSlash() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Images"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("Images/a.jpg")
        try Data([1]).write(to: file)
        XCTAssertNotNil(FolderPathSafety.mediaURL("Images/a.jpg", root: root))
        XCTAssertNotNil(FolderPathSafety.mediaURL("Images/a.jpg", root: URL(fileURLWithPath: root.path)))
        XCTAssertNil(FolderPathSafety.mediaURL("Images/../../outside.jpg", root: root))
        XCTAssertNil(FolderPathSafety.mediaURL("Images/../posts.jsonl", root: root))
        XCTAssertNil(FolderPathSafety.mediaURL("posts.jsonl", root: root))
    }

    func testPostSizeOrderingKeepsUnknownSizesLast() {
        let small = sizedPost("small", bytes: 10)
        let large = sizedPost("large", bytes: 50)
        let unknown = sizedPost("unknown", bytes: nil)
        XCTAssertEqual(BookmarkPostOrdering.sorted([unknown, small, large], by: .sizeDescending).map(\.id), ["large", "small", "unknown"])
        XCTAssertEqual(BookmarkPostOrdering.sorted([unknown, large, small], by: .sizeAscending).map(\.id), ["small", "large", "unknown"])
    }

    func testShuffleTenThousandPostsHasNoOmissionsOrDuplicates() {
        let ids = (0..<10_000).map(String.init)
        let start = Date()
        let shuffled = BookmarkPostOrdering.shuffledPostIDs(ids + ids)
        print("10,000-Post shuffle seconds: \(Date().timeIntervalSince(start))")
        XCTAssertEqual(shuffled.count, ids.count)
        XCTAssertEqual(Set(shuffled), Set(ids))
    }

    func testLocalSavedFiltersIncludePartialPosts() {
        let post = makePost(id: "p", date: nil, types: [.photo, .video])
        XCTAssertTrue(BookmarkLocalSaveFilter.anySaved.matches(post, localKeys: ["p-0"]))
        XCTAssertTrue(BookmarkLocalSaveFilter.notFullySaved.matches(post, localKeys: ["p-0"]))
        XCTAssertFalse(BookmarkLocalSaveFilter.fullySaved.matches(post, localKeys: ["p-0"]))
        XCTAssertTrue(BookmarkLocalSaveFilter.fullySaved.matches(post, localKeys: ["p-0", "p-1"]))
    }

    func testDuplicatesMatchSourceAssetAndIdenticalFileHashes() {
        let first = sizedPost("one", bytes: 3, source: "same.jpg?name=orig")
        let second = sizedPost("two", bytes: 3, source: "same?format=jpg&name=small")
        let third = sizedPost("three", bytes: 3, source: "other.jpg")
        let indexed = MediaDuplicateAnalyzer.groups(posts: [first, second, third])
        XCTAssertEqual(indexed.count, 1)
        XCTAssertEqual(Set(indexed[0].posts.map(\.id)), ["one", "two"])
        let hashed = MediaDuplicateAnalyzer.groups(posts: [first, third], hashesByMediaKey: ["one": "hash", "three": "hash"])
        XCTAssertEqual(hashed.count, 1)
        XCTAssertTrue(hashed[0].matchedByFileHash)
    }

    func testTreemapCoversAreaWithoutOverlappingTiles() {
        let nodes = (1...20).map { value in
            LibraryStorageNode(relativePath: String(value), name: String(value), bytes: Int64(value), children: [])
        }
        let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
        let tiles = LibraryTreemapLayout.tiles(nodes, in: rect)
        XCTAssertEqual(tiles.reduce(CGFloat(0)) { $0 + $1.rect.width * $1.rect.height }, rect.width * rect.height, accuracy: 0.01)
        for left in tiles.indices {
            for right in tiles.indices where right > left {
                let intersection = tiles[left].rect.intersection(tiles[right].rect)
                XCTAssertTrue(intersection.isNull || intersection.width * intersection.height < 0.001)
            }
        }
    }

    func testDeletingAliasedMediaDoesNotDeleteRetainedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Images"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("Images/shared.jpg")
        try Data([1, 2, 3]).write(to: file)
        let states = [ExportStateRecord(mediaKey: "a", relativePath: "Images/shared.jpg"), ExportStateRecord(mediaKey: "b", relativePath: "Images/shared.jpg")]
        try lineData(states).write(to: root.appendingPathComponent("export-state.jsonl"))
        let record = ExportedPostRecord(id: "keep-text", postURL: nil, text: "keep this", createdAt: nil,
            authorID: nil, authorName: nil, authorUsername: nil, media: ["a", "b"].map {
                ExportedMediaRecord(mediaKey: $0, type: .photo, remoteURL: nil, localRelativePath: "Images/shared.jpg",
                    width: nil, height: nil, durationMilliseconds: nil, byteSize: 3)
            })
        try lineData([record]).write(to: root.appendingPathComponent("posts.jsonl"))
        let library = LocalFolderLibrary(root: root)
        try await library.deleteMedia(withKeys: ["a", "not-saved"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let restored = try await library.loadPosts()
        XCTAssertEqual(restored[0].media.map(\.mediaKey), ["b"])
        try await library.deleteMedia(withKeys: ["b"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let emptyPost = try await library.loadPosts()
        XCTAssertEqual(emptyPost[0].text, "keep this")
        XCTAssertTrue(emptyPost[0].media.isEmpty)
        XCTAssertNil(FolderPathSafety.mediaURL("Images/../../outside.jpg", root: root))
    }

    func testExportAuditIncludesPostsWithNoParsedMedia() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = makePost(id: "old-empty", date: Date(timeIntervalSince1970: 0), types: [])
        let result = try await FolderMediaExporter().export(posts: [], mediaByPostID: [:], auditPosts: [empty], destination: root) { _ in }
        XCTAssertEqual(result.failed, 0)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(FolderExportAudit.self, from: Data(contentsOf: root.appendingPathComponent("last-export-report.json")))
        XCTAssertEqual(report.posts[0].exclusionReason, "no_parsed_media")
    }

    func testOldPostWithExistingMediaIsRecordedAsAvailableNotSilentlyLost() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Images"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("Images/old.jpg"))
        let media = sizedPost("old", bytes: 3).media
        let post = BookmarkedPost(id: "old", text: "2010 archive", createdAt: Date(timeIntervalSince1970: 1_262_304_000),
            authorID: nil, authorName: nil, authorUsername: nil, media: media)
        try lineData([ExportStateRecord(mediaKey: "old", relativePath: "Images/old.jpg")]).write(to: root.appendingPathComponent("export-state.jsonl"))
        let result = try await FolderMediaExporter().export(posts: [post], mediaByPostID: [post.id: post.media], destination: root) { _ in }
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.failed, 0)
        let restored = try await LocalFolderLibrary(root: root).loadPosts()
        XCTAssertEqual(restored.first?.media.count, 1)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(FolderExportAudit.self, from: Data(contentsOf: root.appendingPathComponent("last-export-report.json")))
        XCTAssertEqual(report.posts[0].media[0].relativePath, "Images/old.jpg")
    }

    func testManualFileDeletionUpdatesLocalAvailability() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Images"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("Images/test.jpg")
        try Data([1]).write(to: file)
        try lineData([ExportStateRecord(mediaKey: "key", relativePath: "Images/test.jpg")]).write(to: root.appendingPathComponent("export-state.jsonl"))
        let library = LocalMediaLibrary(roots: [root])
        let before = await library.availableMediaKeys()
        XCTAssertTrue(before.contains("key"))
        try FileManager.default.removeItem(at: file)
        let after = await library.availableMediaKeys()
        XCTAssertFalse(after.contains("key"))
    }

    func testLegacyDictionaryExportStateRemainsReadable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Images"), withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("Images/legacy.jpg"))
        try JSONEncoder().encode(["legacy": "Images/legacy.jpg"]).write(to: root.appendingPathComponent("export-state.jsonl"))
        let library = LocalMediaLibrary(roots: [root])
        let keys = await library.availableMediaKeys()
        XCTAssertEqual(keys, ["legacy"])
    }

    private func sizedPost(_ id: String, bytes: Int64?, source: String? = nil) -> BookmarkedPost {
        BookmarkedPost(id: id, text: "", createdAt: nil, authorID: nil, authorName: nil, authorUsername: nil,
            media: [BookmarkedMedia(mediaKey: id, type: .photo,
                url: URL(string: "https://pbs.twimg.com/media/" + (source ?? id + ".jpg")), previewImageURL: nil,
                variants: [], width: nil, height: nil, durationMilliseconds: nil, byteSize: bytes)])
    }

    func testBrowseModesIncludeFilteredPostsAndAggregations() {
        XCTAssertEqual(
            BookmarkBrowseMode.allCases.map(\.rawValue),
            ["posts", "accounts", "hashtags", "rules"]
        )
    }

    func testStatisticsDistinguishGIFAndVideo() {
        let posts = [
            makePost(
                id: "1",
                date: Date(timeIntervalSince1970: 100),
                types: [.photo, .animatedGIF]
            ),
            makePost(
                id: "2",
                date: Date(timeIntervalSince1970: 200),
                types: [.video, .video]
            ),
            makePost(id: "3", date: nil, types: [])
        ]

        let result = BookmarkStatistics.calculate(from: posts)
        XCTAssertEqual(result.bookmarkCount, 3)
        XCTAssertEqual(result.bookmarksWithMedia, 2)
        XCTAssertEqual(result.photoCount, 1)
        XCTAssertEqual(result.gifCount, 1)
        XCTAssertEqual(result.videoCount, 2)
    }

    func testFilterUsesPostDateAndSelectedMediaTypes() {
        let calendar = Calendar(identifier: .gregorian)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let inside = calendar.date(byAdding: .day, value: 1, to: start)!
        let outside = calendar.date(byAdding: .day, value: 4, to: start)!

        var filter = BookmarkFilter()
        filter.includePhotos = false
        filter.includeGIFs = true
        filter.includeVideos = false
        filter.useStartDate = true
        filter.startDate = start
        filter.useEndDate = true
        filter.endDate = inside

        let matching = makePost(
            id: "1",
            date: inside,
            types: [.photo, .animatedGIF]
        )
        let wrongDate = makePost(
            id: "2",
            date: outside,
            types: [.animatedGIF]
        )

        XCTAssertTrue(filter.contains(matching, calendar: calendar))
        XCTAssertEqual(filter.media(in: matching).map(\.type), [.animatedGIF])
        XCTAssertFalse(filter.contains(wrongDate, calendar: calendar))
    }

    @MainActor
    func testSearchAndAccountGroupingUsePostMetadata() {
        let posts = [
            makePost(
                id: "1",
                date: Date(timeIntervalSince1970: 300),
                types: [.photo],
                text: "Sunset in Chengdu #Travel",
                authorID: "123456",
                authorName: "Alice Zhang",
                authorUsername: "alice"
            ),
            makePost(
                id: "2",
                date: Date(timeIntervalSince1970: 200),
                types: [.video],
                text: "Second post #travel",
                authorID: "123456",
                authorName: "Alice Zhang",
                authorUsername: "alice"
            ),
            makePost(
                id: "3",
                date: Date(timeIntervalSince1970: 100),
                types: [.animatedGIF],
                text: "No tag",
                authorID: "999",
                authorName: "Bob",
                authorUsername: "bob"
            )
        ]
        let viewModel = BookmarksViewModel()

        viewModel.searchField = .account
        viewModel.searchText = "@ALI"
        XCTAssertEqual(viewModel.filteredPosts(from: posts).map(\.id), ["1", "2"])

        viewModel.searchText = "999"
        XCTAssertEqual(viewModel.filteredPosts(from: posts).map(\.id), ["3"])

        viewModel.searchField = .hashtag
        viewModel.searchText = "#travel"
        XCTAssertEqual(viewModel.filteredPosts(from: posts).map(\.id), ["1", "2"])

        viewModel.searchField = .all
        viewModel.searchText = ""
        let groups = viewModel.accountGroups(from: posts)
        XCTAssertEqual(groups.first?.authorUsername, "alice")
        XCTAssertEqual(groups.first?.posts.count, 2)
        XCTAssertEqual(
            viewModel.hashtagGroups(from: posts).first?.title.lowercased(),
            "travel"
        )
    }

    func testDurationAndPostSizeRanges() {
        let video = BookmarkedMedia(
            mediaKey: "video",
            type: .video,
            url: nil,
            previewImageURL: nil,
            variants: [],
            width: 1920,
            height: 1080,
            durationMilliseconds: 15 * 60 * 1_000,
            byteSize: 75 * 1_048_576,
            sizeProbeCompleted: true
        )
        let post = BookmarkedPost(
            id: "duration",
            text: "",
            createdAt: Date(),
            authorID: nil,
            authorName: nil,
            authorUsername: nil,
            media: [video]
        )
        var filter = BookmarkFilter()
        filter.includePhotos = false
        filter.includeGIFs = false
        filter.minimumDuration = .tenMinutes
        filter.maximumDuration = .thirtyMinutes
        filter.minimumSize = .fiftyMB
        filter.maximumSize = .twoHundredMB

        XCTAssertTrue(filter.contains(post))
        filter.minimumDuration = .zero
        filter.maximumDuration = .oneMinute
        XCTAssertFalse(filter.contains(post))
    }

    func testConstrainedRangesExcludeUnknownMetadata() {
        let unknownVideo = BookmarkedMedia(
            mediaKey: "unknown",
            type: .video,
            url: nil,
            previewImageURL: nil,
            variants: [],
            width: nil,
            height: nil,
            durationMilliseconds: nil
        )
        let post = BookmarkedPost(
            id: "unknown",
            text: "",
            createdAt: Date(),
            authorID: nil,
            authorName: nil,
            authorUsername: nil,
            media: [unknownVideo]
        )
        var filter = BookmarkFilter()
        filter.includePhotos = false
        filter.includeGIFs = false

        XCTAssertTrue(filter.contains(post))
        filter.minimumDuration = .oneMinute
        XCTAssertFalse(filter.contains(post))
    }

    func testPersistenceStoresPostMetadataWithoutMediaFiles() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("bookmarks.json")
        defer {
            try? FileManager.default.removeItem(
                at: fileURL.deletingLastPathComponent()
            )
        }

        let store = BookmarkPersistenceStore(fileURL: fileURL)
        let expected = [
            makePost(
                id: "42",
                date: Date(timeIntervalSince1970: 100),
                types: [.photo],
                text: "Persist me",
                authorID: "123",
                authorName: "Example",
                authorUsername: "example"
            )
        ]
        try await store.save(expected)

        let restored = try await store.load()
        XCTAssertEqual(restored, expected)
        try await store.clear()
        let cleared = try await store.load()
        XCTAssertEqual(cleared, [])
    }

    func testPhotoSaveHistoryDeduplicatesAcrossReloads() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("saved.jsonl")
        defer {
            try? FileManager.default.removeItem(
                at: fileURL.deletingLastPathComponent()
            )
        }

        let firstStore = MediaSaveHistoryStore(fileURL: fileURL)
        _ = try await firstStore.insert("media-1")
        _ = try await firstStore.insert("media-1")
        _ = try await firstStore.insert("media-2")

        let secondStore = MediaSaveHistoryStore(fileURL: fileURL)
        let restored = try await secondStore.load()
        XCTAssertEqual(restored, Set(["media-1", "media-2"]))
    }

    func testLocalMediaLibraryPrefersExistingExportedFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let imageURL = root
            .appendingPathComponent("Images", isDirectory: true)
            .appendingPathComponent("one.jpg")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: imageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x01]).write(to: imageURL)
        let state = """
        {"mediaKey":"media-1","relativePath":"Images/one.jpg"}

        """
        try Data(state.utf8).write(
            to: root.appendingPathComponent("export-state.jsonl")
        )

        let library = LocalMediaLibrary(roots: [root])
        let resolved = await library.localURL(for: "media-1")
        XCTAssertEqual(resolved?.path, imageURL.path)
        let missing = await library.localURL(for: "missing")
        XCTAssertNil(missing)
    }

    func testRepeatedCaptureUsesCompletedIndexedSizeMetadata() {
        let incoming = makePost(
            id: "repeated",
            date: Date(),
            types: [.photo]
        )
        let incomingMedia = incoming.media[0]
        let completedMedia = BookmarkedMedia(
            mediaKey: incomingMedia.mediaKey,
            type: incomingMedia.type,
            url: incomingMedia.url,
            previewImageURL: incomingMedia.previewImageURL,
            variants: incomingMedia.variants,
            width: incomingMedia.width,
            height: incomingMedia.height,
            durationMilliseconds: incomingMedia.durationMilliseconds,
            byteSize: 12_345,
            sizeProbeCompleted: true
        )
        let indexed = BookmarkedPost(
            id: incoming.id,
            text: incoming.text,
            createdAt: incoming.createdAt,
            authorID: incoming.authorID,
            authorName: incoming.authorName,
            authorUsername: incoming.authorUsername,
            media: [completedMedia]
        )

        let candidates = BrowserSessionModel.sizeProbePosts(
            received: [incoming],
            indexed: [indexed.id: indexed]
        )

        XCTAssertEqual(candidates[0].media[0].byteSize, 12_345)
        XCTAssertEqual(candidates[0].media[0].sizeProbeCompleted, true)
    }

    func testStorageEstimateSumsKnownMediaAndCountsUnknownValues() {
        let known = BookmarkedMedia(
            mediaKey: "known",
            type: .photo,
            url: nil,
            previewImageURL: nil,
            variants: [],
            width: nil,
            height: nil,
            durationMilliseconds: nil,
            byteSize: 12_345,
            sizeProbeCompleted: true
        )
        let unknown = BookmarkedMedia(
            mediaKey: "unknown",
            type: .video,
            url: nil,
            previewImageURL: nil,
            variants: [],
            width: nil,
            height: nil,
            durationMilliseconds: nil
        )

        let estimate = MediaStorageEstimate(media: [known, unknown])

        XCTAssertEqual(estimate.itemCount, 2)
        XCTAssertEqual(estimate.knownBytes, 12_345)
        XCTAssertEqual(estimate.unknownSizeCount, 1)
    }

    func testBookmarkFilterRoundTripsThroughPersistenceEncoding() throws {
        var expected = BookmarkFilter()
        expected.includePhotos = false
        expected.minimumDuration = .oneMinute
        expected.maximumDuration = .oneHour
        expected.minimumSize = .tenMB
        expected.maximumSize = .fiveHundredMB
        expected.useStartDate = true
        expected.startDate = Date(timeIntervalSince1970: 1_700_000_000)

        let data = try JSONEncoder().encode(expected)
        let restored = try JSONDecoder().decode(
            BookmarkFilter.self,
            from: data
        )

        XCTAssertEqual(restored, expected)
    }

    func testSaveFailureStoreClearsSuccessfulRetry() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("save-failures.json")
        defer {
            try? FileManager.default.removeItem(
                at: fileURL.deletingLastPathComponent()
            )
        }
        let post = makePost(
            id: "failed-post",
            date: Date(timeIntervalSince1970: 100),
            types: [.photo]
        )
        let mediaKey = post.media[0].mediaKey
        let store = MediaSaveFailureStore(fileURL: fileURL)

        let failed = try await store.recordAttempt(
            posts: [post],
            successfulMediaKeys: [],
            failureReasons: [mediaKey: "network unavailable"]
        )
        XCTAssertEqual(failed.map(\.id), [post.id])
        XCTAssertEqual(failed[0].failureReasons[mediaKey], "network unavailable")

        let recovered = try await store.recordAttempt(
            posts: [post],
            successfulMediaKeys: [mediaKey],
            failureReasons: [:]
        )
        XCTAssertTrue(recovered.isEmpty)
        let persisted = try await store.load()
        XCTAssertTrue(persisted.isEmpty)
    }

    func testFolderLibraryMediaDeletionKeepsPostManifest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let images = root.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(
            at: images,
            withIntermediateDirectories: true
        )
        try Data([0x01]).write(
            to: images.appendingPathComponent("one.jpg")
        )
        try Data([0x02]).write(
            to: images.appendingPathComponent("two.jpg")
        )

        let media = [
            ExportedMediaRecord(
                mediaKey: "media-1",
                type: .photo,
                remoteURL: URL(string: "https://example.com/one.jpg"),
                localRelativePath: "Images/one.jpg",
                width: 100,
                height: 100,
                durationMilliseconds: nil,
                byteSize: 1
            ),
            ExportedMediaRecord(
                mediaKey: "media-2",
                type: .photo,
                remoteURL: URL(string: "https://example.com/two.jpg"),
                localRelativePath: "Images/two.jpg",
                width: 100,
                height: 100,
                durationMilliseconds: nil,
                byteSize: 1
            )
        ]
        let post = ExportedPostRecord(
            id: "post-1",
            postURL: URL(string: "https://x.com/user/status/post-1"),
            text: "Persist this Post",
            createdAt: Date(timeIntervalSince1970: 100),
            authorID: "author-1",
            authorName: "Author",
            authorUsername: "user",
            media: media
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try lineData([post], encoder: encoder).write(
            to: root.appendingPathComponent("posts.jsonl")
        )
        try lineData([
            ExportStateRecord(
                mediaKey: "media-1",
                relativePath: "Images/one.jpg"
            ),
            ExportStateRecord(
                mediaKey: "media-2",
                relativePath: "Images/two.jpg"
            )
        ]).write(to: root.appendingPathComponent("export-state.jsonl"))

        let library = LocalFolderLibrary(root: root)
        try await library.deleteMedia(withKeys: ["media-1"])
        var restored = try await library.loadPosts()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].media.map(\.mediaKey), ["media-2"])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: images.appendingPathComponent("one.jpg").path
            )
        )

        try await library.deleteMedia(withKeys: ["media-2"])
        restored = try await library.loadPosts()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].text, "Persist this Post")
        XCTAssertTrue(restored[0].media.isEmpty)
    }

    func testFolderLibraryPostDeletionRemovesItsExclusiveMedia() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let images = root.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(
            at: images,
            withIntermediateDirectories: true
        )
        try Data([0x01]).write(
            to: images.appendingPathComponent("only.jpg")
        )
        let media = ExportedMediaRecord(
            mediaKey: "only-media",
            type: .photo,
            remoteURL: URL(string: "https://example.com/only.jpg"),
            localRelativePath: "Images/only.jpg",
            width: nil,
            height: nil,
            durationMilliseconds: nil,
            byteSize: 1
        )
        let post = ExportedPostRecord(
            id: "delete-me",
            postURL: nil,
            text: "Delete this Post",
            createdAt: nil,
            authorID: nil,
            authorName: nil,
            authorUsername: nil,
            media: [media]
        )
        try lineData([post]).write(
            to: root.appendingPathComponent("posts.jsonl")
        )
        try lineData([
            ExportStateRecord(
                mediaKey: "only-media",
                relativePath: "Images/only.jpg"
            )
        ]).write(to: root.appendingPathComponent("export-state.jsonl"))

        let library = LocalFolderLibrary(root: root)
        try await library.deletePosts(withIDs: ["delete-me"])

        let remainingPosts = try await library.loadPosts()
        XCTAssertTrue(remainingPosts.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: images.appendingPathComponent("only.jpg").path
            )
        )
    }

    private func lineData<T: Encodable>(
        _ values: [T],
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> Data {
        var result = Data()
        for value in values {
            result.append(try encoder.encode(value))
            result.append(0x0A)
        }
        return result
    }

    private func makePost(
        id: String,
        date: Date?,
        types: [BookmarkMediaType],
        text: String = "",
        authorID: String? = nil,
        authorName: String? = nil,
        authorUsername: String? = nil
    ) -> BookmarkedPost {
        BookmarkedPost(
            id: id,
            text: text,
            createdAt: date,
            authorID: authorID,
            authorName: authorName,
            authorUsername: authorUsername,
            media: types.enumerated().map { index, type in
                BookmarkedMedia(
                    mediaKey: "\(id)-\(index)",
                    type: type,
                    url: type == .photo
                        ? URL(string: "https://pbs.twimg.com/media/test.jpg")
                        : nil,
                    previewImageURL: nil,
                    variants: [],
                    width: nil,
                    height: nil,
                    durationMilliseconds: nil
                )
            }
        )
    }
}
