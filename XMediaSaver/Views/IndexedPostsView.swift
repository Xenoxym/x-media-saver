import SwiftUI

struct IndexedPostsView: View {
    @ObservedObject var session: BrowserSessionModel
    @State private var searchText = ""
    @State private var sort = BookmarkPostSort.newest
    @State private var visibleLimit = 100
    @AppStorage("bookmarkPostPreviewMode")
    private var previewModeRaw = BookmarkPostPreviewMode.media.rawValue

    private var previewMode: BookmarkPostPreviewMode {
        BookmarkPostPreviewMode(rawValue: previewModeRaw) ?? .media
    }

    private var posts: [BookmarkedPost] {
        let query = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return session.capturedPosts
            .filter { matches($0, query: query) }
            .sorted {
                sort == .newest
                    ? Self.newestFirst($0, $1)
                    : Self.newestFirst($1, $0)
            }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                HStack {
                    Text("\(posts.count) 条 Post")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(previewMode == .media ? "媒体模式" : "纯文字模式")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                ForEach(Array(posts.prefix(visibleLimit))) { post in
                    NavigationLink {
                        BookmarkPostDetailView(post: post)
                    } label: {
                        BookmarkPostRowView(
                            post: post,
                            showsAuthor: true,
                            previewMode: previewMode
                        )
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .padding(.leading)
                }

                if posts.count > visibleLimit {
                    Button("再显示 100 条") {
                        visibleLimit += 100
                    }
                    .padding()
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("已索引 Post")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索账号或正文")
        .onChange(of: searchText) { _ in
            visibleLimit = 100
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    previewModeRaw = previewMode == .media
                        ? BookmarkPostPreviewMode.text.rawValue
                        : BookmarkPostPreviewMode.media.rawValue
                } label: {
                    Image(
                        systemName: previewMode == .media
                            ? "photo.on.rectangle"
                            : "text.alignleft"
                    )
                }
                .accessibilityLabel(
                    previewMode == .media ? "切换到纯文字" : "切换到媒体"
                )

                Menu {
                    Picker("Post 排序", selection: $sort) {
                        ForEach(BookmarkPostSort.allCases) {
                            Text($0.title).tag($0)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
        }
    }

    private static func newestFirst(
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

    private func matches(_ post: BookmarkedPost, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let accountQuery = query.trimmingCharacters(
            in: CharacterSet(charactersIn: "@")
        )
        let nameMatches = post.authorName.map {
            $0.localizedCaseInsensitiveContains(query)
        } ?? false
        let usernameMatches = post.authorUsername.map {
            $0.localizedCaseInsensitiveContains(accountQuery)
        } ?? false
        let idMatches = post.authorID.map {
            $0.localizedCaseInsensitiveContains(accountQuery)
        } ?? false
        return post.text.localizedCaseInsensitiveContains(query)
            || nameMatches
            || usernameMatches
            || idMatches
    }
}

struct BookmarkPostRowView: View {
    let post: BookmarkedPost
    let showsAuthor: Bool
    let previewMode: BookmarkPostPreviewMode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if showsAuthor {
                    HStack(spacing: 5) {
                        Text(post.authorName ?? "未知作者")
                            .font(.subheadline.weight(.semibold))
                        if let username = post.authorUsername {
                            Text("@\(username)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if let date = post.createdAt {
                    Text(date, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !post.text.isEmpty {
                Text(post.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(previewMode == .media ? nil : 3)
            }

            if previewMode == .media, !post.media.isEmpty {
                postMediaGrid(post.media)
            }

            HStack(spacing: 10) {
                ForEach(
                    BookmarkMediaType.allCases.filter { type in
                        post.media.contains { $0.type == type }
                    }
                ) { type in
                    Label(
                        "\(post.media.filter { $0.type == type }.count)",
                        systemImage: type.systemImage
                    )
                }
                Spacer()
                Text(postSizeText(post))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func postMediaGrid(_ media: [BookmarkedMedia]) -> some View {
        if media.count == 1, let item = media.first {
            LocalMediaThumbnailView(
                media: item,
                maximumPixelSize: 900
            )
            .frame(maxWidth: .infinity)
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 3),
                    GridItem(.flexible(), spacing: 3)
                ],
                spacing: 3
            ) {
                ForEach(Array(media.prefix(4))) { item in
                    LocalMediaThumbnailView(
                        media: item,
                        maximumPixelSize: 600
                    )
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func postSizeText(_ post: BookmarkedPost) -> String {
        guard let bytes = post.totalKnownByteSize else {
            let known = post.media.compactMap(\.byteSize).reduce(0, +)
            if known > 0 {
                return "\(Self.byteFormatter.string(fromByteCount: known)) + 待分析"
            }
            return "大小待分析"
        }
        return Self.byteFormatter.string(fromByteCount: bytes)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
