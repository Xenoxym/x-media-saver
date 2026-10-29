import Combine
import Foundation
import NaturalLanguage

struct BookmarkSearchSourceFingerprint: Equatable {
    let postID: String
    let text: String
    let authorID: String?
    let authorName: String?
    let username: String?
    let mediaKeys: [String]

    init(post: BookmarkedPost) {
        postID = post.id
        text = post.text
        authorID = post.authorID
        authorName = post.authorName
        username = post.authorUsername
        mediaKeys = post.media.map(\.mediaKey)
    }
}

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

struct BookmarkRuleDocumentCacheEntry: Sendable {
    let text: String
    let authorID: String?
    let authorName: String?
    let username: String?
    let document: BookmarkSearchDocument

    init(post: BookmarkedPost) {
        text = post.text
        authorID = post.authorID
        authorName = post.authorName
        username = post.authorUsername
        document = BookmarkSearchDocument(post: post)
    }

    func describes(_ post: BookmarkedPost) -> Bool {
        text == post.text && authorID == post.authorID && authorName == post.authorName && username == post.authorUsername
    }
}

enum BookmarkRuleGrouping {
    struct Result {
        let groups: [BookmarkRuleGroup]
        let cache: [String: BookmarkRuleDocumentCacheEntry]
    }

    static func build(
        posts: [BookmarkedPost], rules: [BookmarkRuleCategory],
        cache existing: [String: BookmarkRuleDocumentCacheEntry] = [:]
    ) throws -> Result {
        let enabled = rules.filter(\.isEnabled)
        guard !enabled.isEmpty else { return Result(groups: [], cache: existing) }
        var cache = existing
        for post in posts {
            try Task.checkCancellation()
            if cache[post.id]?.describes(post) != true { cache[post.id] = BookmarkRuleDocumentCacheEntry(post: post) }
        }
        var groups: [BookmarkRuleGroup] = []
        for rule in enabled {
            let matcher = rule.matcher
            let matches = try posts.filter { post in
                try Task.checkCancellation()
                return cache[post.id].map { matcher.matches($0.document) } ?? false
            }
            groups.append(BookmarkRuleGroup(rule: rule, posts: matches))
        }
        return Result(groups: groups, cache: cache)
    }
}

struct BookmarkTermSuggestion: Identifiable, Sendable {
    let term: String
    let count: Int
    let cooccurrence: Int
    var id: String { term }
}

struct BookmarkSuggestionIndex: Sendable {
    struct Entry: Sendable {
        let text: String
        let hashtags: Set<String>
    }
    let entries: [Entry]
    let tagCounts: [String: Int]

    init(posts: [BookmarkedPost]) throws {
        var entries: [Entry] = []
        var counts: [String: Int] = [:]
        var seen: Set<String> = []
        for post in posts where seen.insert(post.id).inserted {
            try Task.checkCancellation()
            let document = BookmarkSearchDocument(post: post)
            entries.append(Entry(text: post.text, hashtags: document.hashtags))
            for tag in document.hashtags { counts[tag, default: 0] += 1 }
        }
        self.entries = entries
        self.tagCounts = counts
    }

    func tags(query: String, selected: [String], limit: Int = 12) throws -> [BookmarkTermSuggestion] {
        let selected = Set(selected.map(BookmarkSearchDocument.normalizeTag))
        let query = BookmarkSearchDocument.normalizeTag(query)
        var related: [String: Int] = [:]
        if !selected.isEmpty {
            for entry in entries {
                try Task.checkCancellation()
                if !entry.hashtags.isDisjoint(with: selected) {
                    for tag in entry.hashtags where !selected.contains(tag) { related[tag, default: 0] += 1 }
                }
            }
        }
        return tagCounts.compactMap { tag, count -> BookmarkTermSuggestion? in
            guard !selected.contains(tag), query.isEmpty || tag.contains(query) else { return nil }
            return BookmarkTermSuggestion(term: tag, count: count, cooccurrence: related[tag] ?? 0)
        }.sorted {
            if $0.cooccurrence != $1.cooccurrence { return $0.cooccurrence > $1.cooccurrence }
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.term < $1.term
        }.prefix(limit).map { $0 }
    }

    func keywords(hashtags: [String], excluding: [String], limit: Int = 16) throws -> [BookmarkTermSuggestion] {
        let selected = Set(hashtags.map(BookmarkSearchDocument.normalizeTag))
        guard !selected.isEmpty else { return [] }
        let excluded = Set(excluding.map(BookmarkSearchDocument.normalize)).union(selected).union(Self.stopWords)
        let strip = try NSRegularExpression(pattern: #"https?://\S+|[@#＃][\p{L}\p{M}\p{N}_]+"#)
        var counts: [String: Int] = [:]
        let tokenizer = NLTokenizer(unit: .word)
        for entry in entries where !entry.hashtags.isDisjoint(with: selected) {
            try Task.checkCancellation()
            let text = strip.stringByReplacingMatches(in: entry.text,
                range: NSRange(entry.text.startIndex..<entry.text.endIndex, in: entry.text), withTemplate: " ")
            tokenizer.string = text
            var words: Set<String> = []
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                let word = BookmarkSearchDocument.normalize(String(text[range]))
                if word.count >= 2, word.count <= 40, !excluded.contains(word),
                   word.unicodeScalars.contains(where: CharacterSet.letters.contains) { words.insert(word) }
                return true
            }
            for word in words { counts[word, default: 0] += 1 }
        }
        return counts.map { BookmarkTermSuggestion(term: $0.key, count: $0.value, cooccurrence: 0) }
            .sorted { $0.count == $1.count ? $0.term < $1.term : $0.count > $1.count }
            .prefix(limit).map { $0 }
    }

    private static let stopWords: Set<String> = Set((
        "the a an and or but for to of in on at by with from is are was were be been being this that these those " +
        "it its as not no yes you your i my me we our us they their he his she her them have has had do does did " +
        "can will would could should just very so more all any now today new also than then if when what how " +
        "です ます ある いる する した して ください これ それ こと もの ため よう さん ちゃん " +
        "这个 那个 这些 那些 一个 我们 你们 他们 自己 可以 不是 还是 就是 已经 没有 什么 今天 真的"
    ).split(separator: " ").map(String.init))
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
