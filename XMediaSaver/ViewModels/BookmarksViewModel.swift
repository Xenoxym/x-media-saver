import Combine
import Foundation

@MainActor
final class BookmarksViewModel: ObservableObject {
    @Published var filter = BookmarkFilter()
    @Published var searchText = ""
    @Published var searchField = BookmarkSearchField.all
    @Published var browseMode = BookmarkBrowseMode.accounts
    @Published var accountSort = BookmarkAccountSort.countDescending
    @Published private(set) var isSaving = false
    @Published private(set) var progress = BatchSaveProgress(
        completed: 0,
        total: 0,
        currentFraction: 0,
        currentType: nil
    )
    @Published private(set) var result: BatchSaveResult?
    @Published var presentedError: PresentedError?

    private let saver: BatchMediaSaver
    private var saveTask: Task<Void, Never>?

    init(saver: BatchMediaSaver = BatchMediaSaver()) {
        self.saver = saver
    }

    func filteredPosts(from posts: [BookmarkedPost]) -> [BookmarkedPost] {
        posts
            .filter { filter.contains($0) && matchesSearch($0) }
            .sorted(by: Self.postComesFirst)
    }

    func accountGroups(from posts: [BookmarkedPost]) -> [BookmarkAccountGroup] {
        let groups = Dictionary(grouping: filteredPosts(from: posts)) { post in
            post.authorID
                ?? post.authorUsername?.lowercased()
                ?? "unknown-author"
        }
        return groups.map { key, posts in
            let first = posts.first
            return BookmarkAccountGroup(
                id: key,
                authorID: first?.authorID,
                authorName: first?.authorName,
                authorUsername: first?.authorUsername,
                posts: posts.sorted(by: Self.postComesFirst)
            )
        }
        .sorted { lhs, rhs in
            switch accountSort {
            case .countDescending:
                if lhs.posts.count != rhs.posts.count {
                    return lhs.posts.count > rhs.posts.count
                }
                return Self.accountLabel(lhs)
                    .localizedCaseInsensitiveCompare(Self.accountLabel(rhs))
                    == .orderedAscending
            case .handleAscending:
                return (lhs.authorUsername ?? "\u{10FFFF}")
                    .localizedCaseInsensitiveCompare(
                        rhs.authorUsername ?? "\u{10FFFF}"
                    ) == .orderedAscending
            case .nameAscending:
                return (lhs.authorName ?? "\u{10FFFF}")
                    .localizedCaseInsensitiveCompare(
                        rhs.authorName ?? "\u{10FFFF}"
                    ) == .orderedAscending
            }
        }
    }

    func hashtagGroups(from posts: [BookmarkedPost]) -> [BookmarkHashtagGroup] {
        var grouped: [String: (title: String, posts: [BookmarkedPost])] = [:]
        for post in filteredPosts(from: posts) {
            for hashtag in Self.hashtags(in: post.text) {
                let key = hashtag.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )
                var group = grouped[key] ?? (title: hashtag, posts: [])
                group.posts.append(post)
                grouped[key] = group
            }
        }
        return grouped.map { key, value in
            BookmarkHashtagGroup(
                id: key,
                title: value.title,
                posts: value.posts.sorted(by: Self.postComesFirst)
            )
        }
        .sorted {
            if $0.posts.count != $1.posts.count {
                return $0.posts.count > $1.posts.count
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title)
                == .orderedAscending
        }
    }

    func selectedMedia(from posts: [BookmarkedPost]) -> [BookmarkedMedia] {
        var seen: Set<String> = []
        return filteredPosts(from: posts)
            .flatMap { filter.media(in: $0) }
            .filter { seen.insert($0.mediaKey).inserted }
    }

    func startSaving(posts: [BookmarkedPost]) {
        guard !isSaving else { return }
        let media = selectedMedia(from: posts)
        guard !media.isEmpty else {
            show(AppError.noMediaSelected)
            return
        }

        result = nil
        progress = BatchSaveProgress(
            completed: 0,
            total: media.count,
            currentFraction: 0,
            currentType: nil
        )
        isSaving = true
        saveTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await saver.save(media) { update in
                    Task { @MainActor [weak self] in
                        self?.progress = update
                    }
                }
                self.result = result
            } catch is CancellationError {
                // A user cancellation is not shown as an error.
            } catch {
                show(error)
            }
            isSaving = false
            saveTask = nil
        }
    }

    func cancelSaving() {
        saver.cancel()
        saveTask?.cancel()
    }

    private func show(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        presentedError = PresentedError(
            message: message,
            offersSettings: (error as? AppError) == .photoPermissionDenied
        )
    }

    private func matchesSearch(_ post: BookmarkedPost) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }

        let plainQuery = query
            .trimmingCharacters(in: CharacterSet(charactersIn: "@#"))
        switch searchField {
        case .all:
            return contains(post.authorUsername, query: plainQuery)
                || contains(post.authorName, query: query)
                || contains(post.authorID, query: plainQuery)
                || contains(post.text, query: query)
                || Self.hashtags(in: post.text).contains {
                    contains($0, query: plainQuery)
                }
        case .handle:
            return contains(post.authorUsername, query: plainQuery)
        case .displayName:
            return contains(post.authorName, query: query)
        case .userID:
            return contains(post.authorID, query: plainQuery)
        case .content:
            return contains(post.text, query: query)
        case .hashtag:
            return Self.hashtags(in: post.text).contains {
                contains($0, query: plainQuery)
            }
        }
    }

    private func contains(_ value: String?, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return value?.localizedCaseInsensitiveContains(query) == true
    }

    static func hashtags(in text: String) -> [String] {
        let pattern = #"#[\p{L}\p{M}\p{N}_]+"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else {
                return nil
            }
            return String(text[swiftRange].dropFirst())
        }
    }

    private static func postComesFirst(
        _ lhs: BookmarkedPost,
        _ rhs: BookmarkedPost
    ) -> Bool {
        switch (lhs.createdAt, rhs.createdAt) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.id > rhs.id
        }
    }

    private static func accountLabel(_ group: BookmarkAccountGroup) -> String {
        group.authorUsername ?? group.authorName ?? group.authorID ?? ""
    }
}
