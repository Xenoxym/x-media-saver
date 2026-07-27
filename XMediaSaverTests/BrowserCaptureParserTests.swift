import XCTest
@testable import XMediaSaver

final class BrowserCaptureParserTests: XCTestCase {
    func testParsesPhotoGIFVideoAndHighestMP4Variant() throws {
        let json = """
        {
          "data": {
            "bookmark_timeline_v2": {
              "timeline": {
                "instructions": [{
                  "entries": [{
                    "entryId": "tweet-123",
                    "content": {
                      "itemContent": {
                        "tweet_results": {
                          "result": {
                            "rest_id": "123",
                            "core": {
                              "user_results": {
                                "result": {
                                  "rest_id": "42",
                                  "legacy": {
                                    "name": "Example",
                                    "screen_name": "example"
                                  }
                                }
                              }
                            },
                            "legacy": {
                              "full_text": "Saved post",
                              "created_at": "Wed Oct 10 20:19:24 +0000 2018",
                              "extended_entities": {
                                "media": [
                                  {
                                    "id_str": "p1",
                                    "media_key": "3_p1",
                                    "type": "photo",
                                    "media_url_https": "https://pbs.twimg.com/media/photo.jpg",
                                    "original_info": {"width": 1200, "height": 800}
                                  },
                                  {
                                    "id_str": "g1",
                                    "media_key": "16_g1",
                                    "type": "animated_gif",
                                    "media_url_https": "https://pbs.twimg.com/tweet_video_thumb/gif.jpg",
                                    "video_info": {
                                      "variants": [{
                                        "content_type": "video/mp4",
                                        "url": "https://video.twimg.com/tweet_video/gif.mp4"
                                      }]
                                    }
                                  },
                                  {
                                    "id_str": "v1",
                                    "media_key": "7_v1",
                                    "type": "video",
                                    "media_url_https": "https://pbs.twimg.com/ext_tw_video_thumb/video.jpg",
                                    "video_info": {
                                      "duration_millis": 9000,
                                      "variants": [
                                        {
                                          "bitrate": 256000,
                                          "content_type": "video/mp4",
                                          "url": "https://video.twimg.com/ext_tw_video/low.mp4"
                                        },
                                        {
                                          "bitrate": 2176000,
                                          "content_type": "video/mp4",
                                          "url": "https://video.twimg.com/ext_tw_video/high.mp4"
                                        },
                                        {
                                          "content_type": "application/x-mpegURL",
                                          "url": "https://video.twimg.com/ext_tw_video/master.m3u8"
                                        }
                                      ]
                                    }
                                  }
                                ]
                              }
                            }
                          }
                        }
                      }
                    }
                  }, {
                    "entryId": "cursor-bottom-1",
                    "content": {
                      "cursorType": "Bottom",
                      "value": "next-page"
                    }
                  }]
                }]
              }
            }
          }
        }
        """

        let capture = try BrowserCaptureParser.parse(
            data: Data(json.utf8),
            sourceURL: "https://x.com/i/api/graphql/example/Bookmarks"
        )

        XCTAssertEqual(capture.posts.count, 1)
        XCTAssertEqual(capture.bottomCursor, "next-page")
        XCTAssertEqual(capture.posts[0].authorUsername, "example")
        XCTAssertEqual(capture.posts[0].media.map(\.type), [
            .photo, .animatedGIF, .video
        ])
        XCTAssertEqual(
            capture.posts[0].media[2].bestMP4Variant?.bitRate,
            2_176_000
        )
        XCTAssertEqual(
            capture.posts[0].media[0].downloadURL?.absoluteString,
            "https://pbs.twimg.com/media/photo.jpg?name=orig"
        )
    }

    func testRejectsInvalidJSON() {
        XCTAssertThrowsError(
            try BrowserCaptureParser.parse(
                data: Data("not json".utf8),
                sourceURL: "https://x.com/"
            )
        )
    }

    func testParsesDirectTweetResultUsedBySingleLinkNavigation() throws {
        let json = """
        {
          "data": {
            "tweetResult": {
              "result": {
                "rest_id": "98765",
                "legacy": {
                  "full_text": "Login-only example",
                  "extended_entities": {
                    "media": [{
                      "id_str": "v1",
                      "type": "video",
                      "media_url_https": "https://pbs.twimg.com/media/thumb.jpg",
                      "video_info": {
                        "variants": [{
                          "bitrate": 832000,
                          "content_type": "video/mp4",
                          "url": "https://video.twimg.com/ext_tw_video/example.mp4"
                        }]
                      }
                    }]
                  }
                }
              }
            }
          }
        }
        """

        let capture = try BrowserCaptureParser.parse(
            data: Data(json.utf8),
            sourceURL: "https://x.com/i/api/graphql/example/TweetResultByRestId"
        )

        XCTAssertEqual(capture.posts.count, 1)
        XCTAssertEqual(capture.posts[0].id, "98765")
        XCTAssertEqual(
            capture.posts[0].media[0].bestMP4Variant?.bitRate,
            832_000
        )
    }
}
