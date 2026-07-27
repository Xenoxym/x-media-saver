import Foundation

enum BrowserCaptureParser {
    static func parse(data: Data, sourceURL: String) throws -> BrowserCapture {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AppError.browserCaptureFailed("响应不是有效 JSON")
        }

        let entryResults = timelineResults(in: root)
            + directTweetResults(in: root)
        var postsByID: [String: BookmarkedPost] = [:]
        var orderedIDs: [String] = []

        for result in entryResults {
            guard let post = parsePost(from: result) else { continue }
            if postsByID[post.id] == nil {
                orderedIDs.append(post.id)
            }
            postsByID[post.id] = post
        }

        return BrowserCapture(
            posts: orderedIDs.compactMap { postsByID[$0] },
            bottomCursor: bottomCursor(in: root),
            sourceURL: sourceURL
        )
    }

    private static func timelineResults(in value: Any) -> [[String: Any]] {
        var results: [[String: Any]] = []
        walk(value) { dictionary in
            guard let entryID = dictionary["entryId"] as? String,
                  entryID.hasPrefix("tweet-") || entryID.hasPrefix("profile-conversation-")
            else {
                return
            }
            if let result = resultFromEntry(dictionary) {
                results.append(result)
            }
        }
        return results
    }

    private static func directTweetResults(in value: Any) -> [[String: Any]] {
        var results: [[String: Any]] = []
        walk(value) { dictionary in
            if let tweetResults = dictionary["tweet_results"] as? [String: Any],
               let result = tweetResults["result"] as? [String: Any] {
                results.append(result)
            }
            if let tweetResult = dictionary["tweetResult"] as? [String: Any],
               let result = tweetResult["result"] as? [String: Any] {
                results.append(result)
            }
        }
        return results
    }

    private static func resultFromEntry(
        _ entry: [String: Any]
    ) -> [String: Any]? {
        guard let content = entry["content"] as? [String: Any] else {
            return nil
        }

        if let result = tweetResult(in: content) {
            return result
        }

        if let items = content["items"] as? [[String: Any]] {
            for item in items {
                if let result = tweetResult(in: item) {
                    return result
                }
            }
        }
        return nil
    }

    private static func tweetResult(in value: Any) -> [String: Any]? {
        guard let dictionary = value as? [String: Any] else { return nil }

        if let tweetResults = dictionary["tweet_results"] as? [String: Any],
           let result = tweetResults["result"] as? [String: Any] {
            return result
        }
        if let tweetResult = dictionary["tweetResult"] as? [String: Any],
           let result = tweetResult["result"] as? [String: Any] {
            return result
        }

        for key in ["itemContent", "item", "content"] {
            if let nested = dictionary[key],
               let result = tweetResult(in: nested) {
                return result
            }
        }
        return nil
    }

    private static func parsePost(
        from rawResult: [String: Any]
    ) -> BookmarkedPost? {
        let result = unwrapVisibilityResult(rawResult)
        guard let id = (result["rest_id"] as? String)
                ?? (result["id_str"] as? String),
              let legacy = result["legacy"] as? [String: Any]
        else {
            return nil
        }

        let directMedia = parseMedia(from: legacy)
        let fallbackMedia: [BookmarkedMedia]
        if directMedia.isEmpty,
           let quoted = nestedStatusResult(
            in: result,
            keys: ["quoted_status_result", "retweeted_status_result"]
           ) {
            fallbackMedia = parseMediaFromResult(quoted)
        } else {
            fallbackMedia = []
        }

        let userResult = ((result["core"] as? [String: Any])?["user_results"]
            as? [String: Any])?["result"] as? [String: Any]
        let unwrappedUser = userResult.map(unwrapVisibilityResult)
        let userLegacy = unwrappedUser?["legacy"] as? [String: Any]
        let userCore = unwrappedUser?["core"] as? [String: Any]

        return BookmarkedPost(
            id: id,
            text: (legacy["full_text"] as? String)
                ?? (legacy["text"] as? String)
                ?? "",
            createdAt: parseXDate(legacy["created_at"] as? String),
            authorID: (legacy["user_id_str"] as? String)
                ?? (unwrappedUser?["rest_id"] as? String),
            authorName: (userCore?["name"] as? String)
                ?? (userLegacy?["name"] as? String),
            authorUsername: (userCore?["screen_name"] as? String)
                ?? (userLegacy?["screen_name"] as? String),
            media: directMedia.isEmpty ? fallbackMedia : directMedia
        )
    }

    private static func parseMediaFromResult(
        _ rawResult: [String: Any]
    ) -> [BookmarkedMedia] {
        let result = unwrapVisibilityResult(rawResult)
        guard let legacy = result["legacy"] as? [String: Any] else {
            return []
        }
        return parseMedia(from: legacy)
    }

    private static func parseMedia(
        from legacy: [String: Any]
    ) -> [BookmarkedMedia] {
        guard let extended = legacy["extended_entities"] as? [String: Any],
              let media = extended["media"] as? [[String: Any]]
        else {
            return []
        }

        return media.compactMap { item in
            guard let typeString = item["type"] as? String,
                  let type = BookmarkMediaType(rawValue: typeString)
            else {
                return nil
            }

            let mediaKey = (item["media_key"] as? String)
                ?? (item["id_str"] as? String)
                ?? UUID().uuidString
            let videoInfo = item["video_info"] as? [String: Any]
            let variants = (videoInfo?["variants"] as? [[String: Any]] ?? [])
                .compactMap { variant -> XMediaVariant? in
                    guard let contentType = variant["content_type"] as? String,
                          let urlString = variant["url"] as? String,
                          let url = URL(string: urlString),
                          url.scheme?.lowercased() == "https",
                          url.host?.lowercased().hasSuffix(".twimg.com") == true
                    else {
                        return nil
                    }
                    return XMediaVariant(
                        bitRate: (variant["bitrate"] as? Int)
                            ?? (variant["bit_rate"] as? Int),
                        contentType: contentType,
                        url: url
                    )
                }

            let imageURL = (item["media_url_https"] as? String)
                .flatMap(originalImageURL)
            let sizes = ((item["original_info"] as? [String: Any]))

            return BookmarkedMedia(
                mediaKey: mediaKey,
                type: type,
                url: type == .photo ? imageURL : nil,
                previewImageURL: imageURL,
                variants: variants,
                width: (sizes?["width"] as? Int),
                height: (sizes?["height"] as? Int),
                durationMilliseconds: videoInfo?["duration_millis"] as? Int
            )
        }
    }

    private static func originalImageURL(_ value: String) -> URL? {
        guard var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "pbs.twimg.com"
        else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "name", value: "orig")]
        return components.url
    }

    private static func nestedStatusResult(
        in result: [String: Any],
        keys: [String]
    ) -> [String: Any]? {
        for key in keys {
            if let container = result[key] as? [String: Any],
               let nested = container["result"] as? [String: Any] {
                return nested
            }
            if let legacy = result["legacy"] as? [String: Any],
               let container = legacy[key] as? [String: Any],
               let nested = container["result"] as? [String: Any] {
                return nested
            }
        }
        return nil
    }

    private static func unwrapVisibilityResult(
        _ value: [String: Any]
    ) -> [String: Any] {
        if let tweet = value["tweet"] as? [String: Any] {
            return tweet
        }
        if let result = value["result"] as? [String: Any] {
            return unwrapVisibilityResult(result)
        }
        return value
    }

    private static func bottomCursor(in value: Any) -> String? {
        var result: String?
        walk(value) { dictionary in
            guard result == nil,
                  let cursorType = dictionary["cursorType"] as? String,
                  cursorType.lowercased() == "bottom",
                  let cursorValue = dictionary["value"] as? String
            else {
                return
            }
            result = cursorValue
        }
        return result
    }

    private static func walk(
        _ value: Any,
        visit: ([String: Any]) -> Void
    ) {
        if let dictionary = value as? [String: Any] {
            visit(dictionary)
            for nested in dictionary.values {
                walk(nested, visit: visit)
            }
        } else if let array = value as? [Any] {
            for nested in array {
                walk(nested, visit: visit)
            }
        }
    }

    private static func parseXDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return formatter.date(from: value)
    }
}
