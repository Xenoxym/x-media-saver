import Foundation

actor MediaSizeResolver {
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 3
        return URLSession(configuration: configuration)
    }()

    func resolve(_ url: URL) async -> Int64? {
        guard isAllowed(url) else { return nil }

        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        if let size = try? await contentLength(for: head), size > 0 {
            return size
        }

        var range = URLRequest(url: url)
        range.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        do {
            let (_, response) = try await session.data(for: range)
            guard let response = response as? HTTPURLResponse,
                  (200...299).contains(response.statusCode)
            else {
                return nil
            }
            if let contentRange = response.value(
                forHTTPHeaderField: "Content-Range"
            ), let total = contentRange.split(separator: "/").last,
               let value = Int64(total) {
                return value
            }
            return response.expectedContentLength > 0
                ? response.expectedContentLength
                : nil
        } catch {
            return nil
        }
    }

    private func contentLength(for request: URLRequest) async throws -> Int64 {
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode)
        else {
            return 0
        }
        return response.expectedContentLength
    }

    private func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else {
            return false
        }
        return host == "pbs.twimg.com"
            || host == "video.twimg.com"
            || host.hasSuffix(".twimg.com")
    }
}
