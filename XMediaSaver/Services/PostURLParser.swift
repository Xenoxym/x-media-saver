import Foundation

enum PostURLParser {
    private static let supportedHosts: Set<String> = [
        "x.com",
        "www.x.com",
        "mobile.x.com",
        "twitter.com",
        "www.twitter.com",
        "mobile.twitter.com"
    ]

    static func postID(from input: String) throws -> String {
        let url = try postURL(from: input)
        let pathComponents = url.path
            .split(separator: "/")
            .map(String.init)

        guard let statusIndex = pathComponents.firstIndex(
            where: { $0.lowercased() == "status" || $0.lowercased() == "statuses" }
        ),
        pathComponents.indices.contains(statusIndex + 1)
        else {
            throw AppError.invalidURL
        }

        let id = pathComponents[statusIndex + 1]
        guard id.count >= 5, id.allSatisfy(\.isNumber) else {
            throw AppError.invalidURL
        }
        return id
    }

    static func postURL(from input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.invalidURL
        }

        let candidate = trimmed
            .split(whereSeparator: \.isWhitespace)
            .first(where: { $0.contains("x.com/") || $0.contains("twitter.com/") })
            .map(String.init) ?? trimmed
        let cleaned = candidate.trimmingCharacters(
            in: CharacterSet(charactersIn: ".,;:!?()[]{}<>\"'")
        )
        let normalized = cleaned.contains("://") ? cleaned : "https://\(cleaned)"

        guard let components = URLComponents(string: normalized),
              let host = components.host?.lowercased(),
              supportedHosts.contains(host),
              let url = components.url
        else {
            throw AppError.invalidURL
        }

        return url
    }
}
