import Combine
import Foundation

struct BookmarkSearchDocument: Sendable {
    let postID: String
    let account: String
    let text: String
    let hashtags: Set<String>

    init(post: BookmarkedPost) {
        postID = post.id
        account = Self.normalize([post.authorUsername, post.authorName, post.authorID].compactMap { $0 }.joined(separator: "\n"))
        text = Self.normalize(post.text)
        let range = NSRange(post.text.startIndex..<post.text.endIndex, in: post.text)
        hashtags = Set(Self.hashtagExpression.matches(in: post.text, range: range).compactMap { match in
            guard let range = Range(match.range, in: post.text) else { return nil }
            return Self.normalizeTag(String(post.text[range]))
        })
    }

    func matches(query: String, field: BookmarkSearchField) -> Bool {
        BookmarkSearchQuery(query, field: field).matches(self)
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func normalizeTag(_ text: String) -> String {
        normalize(text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#＃")))
    }

    private static let hashtagExpression = try! NSRegularExpression(pattern: #"[#＃][\p{L}\p{M}\p{N}_]+"#)
}

private struct BookmarkSearchQuery {
    let isEmpty: Bool
    let normalized: String
    let accountQuery: String
    let tagQuery: String
    let field: BookmarkSearchField

    init(_ query: String, field: BookmarkSearchField) {
        let plain = query.trimmingCharacters(in: .whitespacesAndNewlines)
        isEmpty = plain.isEmpty
        normalized = BookmarkSearchDocument.normalize(plain)
        accountQuery = BookmarkSearchDocument.normalize(plain.trimmingCharacters(in: CharacterSet(charactersIn: "@#")))
        tagQuery = BookmarkSearchDocument.normalizeTag(plain)
        self.field = field
    }

    func matches(_ document: BookmarkSearchDocument) -> Bool {
        if isEmpty { return true }
        let accountMatch = !accountQuery.isEmpty && document.account.contains(accountQuery)
        let textMatch = document.text.contains(normalized)
        let tagMatch = !tagQuery.isEmpty && document.hashtags.contains { $0.contains(tagQuery) }
        switch field {
        case .all: return accountMatch || textMatch || tagMatch
        case .account: return accountMatch
        case .content: return textMatch
        case .hashtag: return tagMatch
        }
    }

}

enum BookmarkSearchEngine {
    static func matchingPostIDs(
        documents: [BookmarkSearchDocument], query: String, field: BookmarkSearchField,
        rule: BookmarkRuleCategory? = nil
    ) throws -> Set<String> {
        if rule?.isEnabled == false { return [] }
        let preparedQuery = BookmarkSearchQuery(query, field: field)
        let matcher = rule?.matcher
        var ids: Set<String> = []
        for document in documents {
            try Task.checkCancellation()
            if preparedQuery.matches(document), matcher?.matches(document) ?? true { ids.insert(document.postID) }
        }
        return ids
    }
}

struct BookmarkRuleCategory: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var hashtags: [String]
    var keywords: [String]
    var isEnabled = true

    struct Matcher: Sendable {
        let hashtags: Set<String>
        let keywords: [String]
        func matches(_ document: BookmarkSearchDocument) -> Bool {
            !hashtags.isDisjoint(with: document.hashtags)
                || keywords.contains { document.text.contains($0) }
        }
    }

    var matcher: Matcher {
        Matcher(hashtags: Set(hashtags.map(BookmarkSearchDocument.normalizeTag).filter { !$0.isEmpty }),
                keywords: keywords.map { BookmarkSearchDocument.normalize($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .filter { !$0.isEmpty })
    }

    static func terms(from input: String, hashtags: Bool) -> [String] {
        var seen: Set<String> = []
        return input.components(separatedBy: CharacterSet(charactersIn: "\n,，;；、")).compactMap {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = hashtags ? BookmarkSearchDocument.normalizeTag(value) : BookmarkSearchDocument.normalize(value)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return hashtags ? value.trimmingCharacters(in: CharacterSet(charactersIn: "#＃")) : value
        }
    }
}

struct BookmarkRuleGroup: Identifiable {
    let rule: BookmarkRuleCategory
    let posts: [BookmarkedPost]
    var id: UUID { rule.id }
}

@MainActor
final class BookmarkRuleStore: ObservableObject {
    static let shared = BookmarkRuleStore()
    @Published private(set) var rules: [BookmarkRuleCategory] = []
    @Published private(set) var loadError: String?
    private let fileURL: URL
    private var readFailure: Error?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("rule-categories.json")
        reload()
    }

    func reload() {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                rules = try JSONDecoder().decode([BookmarkRuleCategory].self, from: Data(contentsOf: fileURL))
            } else { rules = [] }
            readFailure = nil
            loadError = nil
        } catch {
            readFailure = error
            loadError = error.localizedDescription
        }
    }

    func upsert(_ rule: BookmarkRuleCategory) throws {
        var updated = rules
        if let index = updated.firstIndex(where: { $0.id == rule.id }) { updated[index] = rule }
        else { updated.append(rule) }
        try persist(updated)
    }

    func remove(_ ids: Set<UUID>) throws { try persist(rules.filter { !ids.contains($0.id) }) }

    private func persist(_ updated: [BookmarkRuleCategory]) throws {
        if let readFailure { throw readFailure }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(updated).write(to: fileURL, options: .atomic)
        rules = updated
    }
}
