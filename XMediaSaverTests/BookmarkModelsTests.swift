import XCTest
@testable import XMediaSaver

final class BookmarkModelsTests: XCTestCase {
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

    private func makePost(
        id: String,
        date: Date?,
        types: [BookmarkMediaType]
    ) -> BookmarkedPost {
        BookmarkedPost(
            id: id,
            text: "",
            createdAt: date,
            authorID: nil,
            authorName: nil,
            authorUsername: nil,
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
