import XCTest
@testable import XMediaSaver

final class BookmarkModelsTests: XCTestCase {
    func testBrowseModesKeepOnlyAccountAndHashtagAggregation() {
        XCTAssertEqual(
            BookmarkBrowseMode.allCases.map(\.rawValue),
            ["accounts", "hashtags"]
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
        filter.durationRange = .tenToThirtyMinutes
        filter.sizeRange = .fiftyToTwoHundredMB

        XCTAssertTrue(filter.contains(post))
        filter.durationRange = .underOneMinute
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
