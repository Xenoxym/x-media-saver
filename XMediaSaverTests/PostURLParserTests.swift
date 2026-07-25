import XCTest
@testable import XMediaSaver

final class PostURLParserTests: XCTestCase {
    func testParsesSupportedURLs() throws {
        XCTAssertEqual(
            try PostURLParser.postID(
                from: "https://x.com/example/status/1293593516040269825?s=20"
            ),
            "1293593516040269825"
        )
        XCTAssertEqual(
            try PostURLParser.postID(
                from: "twitter.com/i/status/1293593516040269825/video/1"
            ),
            "1293593516040269825"
        )
        XCTAssertEqual(
            try PostURLParser.postID(
                from: "Look: https://mobile.x.com/a/statuses/1293593516040269825"
            ),
            "1293593516040269825"
        )
    }

    func testRejectsUnsupportedOrMalformedURLs() {
        XCTAssertThrowsError(
            try PostURLParser.postID(
                from: "https://example.com/account/status/1293593516040269825"
            )
        )
        XCTAssertThrowsError(
            try PostURLParser.postID(from: "https://x.com/example")
        )
        XCTAssertThrowsError(
            try PostURLParser.postID(from: "https://x.com/example/status/not-a-number")
        )
    }
}
