import XCTest
@testable import XMediaSaver

final class SyndicationServiceTests: XCTestCase {
    func testSelectsHighestBitrateMP4AndIgnoresHLS() throws {
        let json = """
        {
          "text": "Example",
          "user": { "name": "Example User", "screen_name": "example" },
          "mediaDetails": [{
            "type": "video",
            "video_info": {
              "duration_millis": 12000,
              "variants": [
                {
                  "content_type": "application/x-mpegURL",
                  "url": "https://video.twimg.com/path/master.m3u8"
                },
                {
                  "bitrate": 256000,
                  "content_type": "video/mp4",
                  "url": "https://video.twimg.com/path/vid/480x270/low.mp4"
                },
                {
                  "bitrate": 2176000,
                  "content_type": "video/mp4",
                  "url": "https://video.twimg.com/path/vid/1280x720/high.mp4"
                }
              ]
            }
          }]
        }
        """

        let result = try SyndicationService.parseResponse(
            Data(json.utf8),
            postID: "12345"
        )

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].variants.count, 2)
        XCTAssertEqual(result.items[0].bestVariant?.bitrate, 2_176_000)
        XCTAssertEqual(result.items[0].bestVariant?.resolution, "1280×720")
    }

    func testTreatsAnimatedGIFMP4AsDownloadable() throws {
        let json = """
        {
          "mediaDetails": [{
            "type": "animated_gif",
            "video_info": {
              "variants": [{
                "content_type": "video/mp4",
                "url": "https://video.twimg.com/tweet_video/example.mp4"
              }]
            }
          }]
        }
        """

        let result = try SyndicationService.parseResponse(
            Data(json.utf8),
            postID: "12345"
        )

        XCTAssertEqual(result.items[0].kind, .animatedGIF)
        XCTAssertEqual(result.items[0].variants.count, 1)
    }

    func testFallsBackToQuotedPostMedia() throws {
        let json = """
        {
          "text": "Quoted post",
          "quoted_tweet": {
            "mediaDetails": [{
              "type": "video",
              "video_info": {
                "variants": [{
                  "bitrate": 832000,
                  "content_type": "video/mp4",
                  "url": "https://video.twimg.com/quoted/vid/640x360/example.mp4"
                }]
              }
            }]
          }
        }
        """

        let result = try SyndicationService.parseResponse(
            Data(json.utf8),
            postID: "12345"
        )

        XCTAssertTrue(result.cameFromQuotedPost)
        XCTAssertEqual(result.items[0].bestVariant?.resolution, "640×360")
    }

    func testResolvesPhotoOnlyResponseAtOriginalQuality() throws {
        let json = """
        {
          "mediaDetails": [{
            "type": "photo",
            "media_url_https": "https://pbs.twimg.com/media/example.jpg"
          }]
        }
        """

        let result = try SyndicationService.parseResponse(
            Data(json.utf8),
            postID: "12345"
        )

        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.photos.count, 1)
        XCTAssertEqual(result.photos[0].type, .photo)
        XCTAssertEqual(
            result.photos[0].url?.absoluteString,
            "https://pbs.twimg.com/media/example.jpg?name=orig"
        )
    }

    func testRejectsTombstoneAndEmptyResponsesAsUnavailable() {
        let inputs = [
            #"{"__typename":"TweetTombstone"}"#,
            #"{}"#
        ]

        for json in inputs {
            XCTAssertThrowsError(
                try SyndicationService.parseResponse(
                    Data(json.utf8),
                    postID: "12345"
                )
            ) { error in
                XCTAssertEqual(
                    error as? AppError,
                    .unsupportedOrUnavailablePost
                )
            }
        }
    }

    func testRejectsMP4OutsideXVideoCDN() {
        let json = """
        {
          "mediaDetails": [{
            "type": "video",
            "video_info": {
              "variants": [{
                "bitrate": 2176000,
                "content_type": "video/mp4",
                "url": "https://example.com/untrusted.mp4"
              }]
            }
          }]
        }
        """

        XCTAssertThrowsError(
            try SyndicationService.parseResponse(
                Data(json.utf8),
                postID: "12345"
            )
        ) { error in
            XCTAssertEqual(error as? AppError, .noVideo)
        }
    }
}
