import Foundation

actor SyndicationService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func resolve(postID: String) async throws -> PostMedia {
        var components = URLComponents(
            string: "https://cdn.syndication.twimg.com/tweet-result"
        )!
        components.queryItems = [
            URLQueryItem(name: "id", value: postID),
            URLQueryItem(name: "lang", value: "en"),
            // This is a public embed-route parameter, not a credential.
            URLQueryItem(name: "token", value: "x")
        ]

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AppError.metadataServiceChanged
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.metadataServiceChanged
        }
        switch httpResponse.statusCode {
        case 200:
            return try Self.parseResponse(data, postID: postID)
        case 401, 403, 404:
            throw AppError.unsupportedOrUnavailablePost
        default:
            throw AppError.httpError(httpResponse.statusCode)
        }
    }

    static func parseResponse(_ data: Data, postID: String) throws -> PostMedia {
        if let object = try? JSONSerialization.jsonObject(with: data),
           let dictionary = object as? [String: Any],
           dictionary.isEmpty {
                throw AppError.unsupportedOrUnavailablePost
        }

        let response: SyndicationTweet
        do {
            response = try JSONDecoder().decode(SyndicationTweet.self, from: data)
        } catch {
            throw AppError.metadataServiceChanged
        }

        if response.typeName == "TweetTombstone" {
            throw AppError.unsupportedOrUnavailablePost
        }

        let directItems = videoItems(from: response.mediaDetails, prefix: postID)
        let quotedItems = videoItems(
            from: response.quotedTweet?.mediaDetails,
            prefix: "\(postID)-quoted"
        )
        let items = directItems.isEmpty ? quotedItems : directItems
        let directPhotos = photoItems(
            from: response.mediaDetails,
            prefix: postID
        )
        let quotedPhotos = photoItems(
            from: response.quotedTweet?.mediaDetails,
            prefix: "\(postID)-quoted"
        )
        let photos = directPhotos.isEmpty ? quotedPhotos : directPhotos

        guard !items.isEmpty || !photos.isEmpty else {
            throw AppError.noVideo
        }

        return PostMedia(
            postID: postID,
            authorName: response.user?.name,
            authorHandle: response.user?.screenName,
            text: response.text,
            items: items,
            photos: photos,
            cameFromQuotedPost:
                (directItems.isEmpty && !quotedItems.isEmpty)
                || (directPhotos.isEmpty && !quotedPhotos.isEmpty)
        )
    }

    private static func photoItems(
        from details: [SyndicationMedia]?,
        prefix: String
    ) -> [BookmarkedMedia] {
        (details ?? []).enumerated().compactMap { index, media in
            guard media.type == "photo",
                  let value = media.mediaURLHTTPS,
                  var components = URLComponents(string: value),
                  components.scheme?.lowercased() == "https",
                  components.host?.lowercased() == "pbs.twimg.com"
            else {
                return nil
            }
            components.queryItems = [URLQueryItem(name: "name", value: "orig")]
            guard let url = components.url else { return nil }
            return BookmarkedMedia(
                mediaKey: "\(prefix)-photo-\(index)",
                type: .photo,
                url: url,
                previewImageURL: url,
                variants: [],
                width: nil,
                height: nil,
                durationMilliseconds: nil
            )
        }
    }

    private static func videoItems(
        from details: [SyndicationMedia]?,
        prefix: String
    ) -> [VideoMediaItem] {
        (details ?? []).enumerated().compactMap { index, media in
            let mp4Variants = (media.videoInfo?.variants ?? [])
                .compactMap { variant -> VideoVariant? in
                    guard variant.contentType.lowercased() == "video/mp4",
                          let url = URL(string: variant.url),
                          url.scheme?.lowercased() == "https",
                          url.host?.lowercased() == "video.twimg.com"
                    else {
                        return nil
                    }
                    return VideoVariant(url: url, bitrate: variant.bitrate)
                }
                .sorted(by: VideoVariant.isHigherQuality)

            guard !mp4Variants.isEmpty else {
                return nil
            }
            return VideoMediaItem(
                id: "\(prefix)-\(index)",
                kind: MediaKind(rawValue: media.type) ?? .unknown,
                durationMilliseconds: media.videoInfo?.durationMilliseconds,
                variants: mp4Variants
            )
        }
    }
}

private final class SyndicationTweet: Decodable {
    let typeName: String?
    let text: String?
    let user: SyndicationUser?
    let mediaDetails: [SyndicationMedia]?
    let quotedTweet: SyndicationTweet?

    enum CodingKeys: String, CodingKey {
        case typeName = "__typename"
        case text
        case user
        case mediaDetails
        case quotedTweet = "quoted_tweet"
    }
}

private struct SyndicationUser: Decodable {
    let name: String?
    let screenName: String?

    enum CodingKeys: String, CodingKey {
        case name
        case screenName = "screen_name"
    }
}

private struct SyndicationMedia: Decodable {
    let type: String
    let videoInfo: SyndicationVideoInfo?
    let mediaURLHTTPS: String?

    enum CodingKeys: String, CodingKey {
        case type
        case videoInfo = "video_info"
        case mediaURLHTTPS = "media_url_https"
    }
}

private struct SyndicationVideoInfo: Decodable {
    let durationMilliseconds: Int?
    let variants: [SyndicationVariant]

    enum CodingKeys: String, CodingKey {
        case durationMilliseconds = "duration_millis"
        case variants
    }
}

private struct SyndicationVariant: Decodable {
    let bitrate: Int?
    let contentType: String
    let url: String

    enum CodingKeys: String, CodingKey {
        case bitrate
        case contentType = "content_type"
        case url
    }
}
