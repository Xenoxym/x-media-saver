import SwiftUI

struct IndexedPostsView: View {
    @ObservedObject var session: BrowserSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var sort = BookmarkPostSort.bookmarkNewest
    @State private var visibleLimit = 100
    @State private var isSelecting = false
    @State private var selectedPostIDs: Set<String> = []
    @State private var confirmsIndexRemoval = false
    @AppStorage("bookmarkPostPreviewMode")
    private var previewModeRaw = BookmarkPostPreviewMode.media.rawValue

    private var previewMode: BookmarkPostPreviewMode {
        BookmarkPostPreviewMode(rawValue: previewModeRaw) ?? .media
    }

    private var posts: [BookmarkedPost] {
        let query = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let filtered = session.capturedPosts.filter {
            matches($0, query: query)
        }
        switch sort {
        case .bookmarkNewest:
            return filtered
        case .bookmarkOldest:
            return Array(filtered.reversed())
        case .newest:
            return filtered.sorted {
                Self.newestFirst($0, $1)
            }
        case .oldest:
            return filtered.sorted {
                Self.newestFirst($1, $0)
            }
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
                    if isSelecting {
                        Button {
                            toggleSelection(for: post.id)
                        } label: {
                            indexedPostRow(post, showsSelection: true)
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink {
                            BookmarkPostDetailView(post: post)
                        } label: {
                            indexedPostRow(post, showsSelection: false)
                        }
                        .buttonStyle(.plain)
                    }

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
        .navigationTitle(L10n.string("已索引 Post"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .edgeSwipeBack()
        .searchable(text: $searchText, prompt: "搜索账号或正文")
        .onChange(of: searchText) { _ in
            visibleLimit = 100
            selectedPostIDs.removeAll()
        }
        .onReceive(session.$capturedPosts) { updatedPosts in
            selectedPostIDs.formIntersection(updatedPosts.map(\.id))
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .accessibilityLabel(L10n.string("返回"))

                if !isSelecting {
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
                }
            }

            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if isSelecting {
                    Button("完成") {
                        endSelection()
                    }
                } else {
                    Menu {
                        Picker("Post 排序", selection: $sort) {
                            ForEach(BookmarkPostSort.allCases) {
                                Text($0.title).tag($0)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }

                    Button {
                        isSelecting = true
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .accessibilityLabel("多选")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBar
            }
        }
        .alert(
            "从本地索引移除所选 Post？",
            isPresented: $confirmsIndexRemoval
        ) {
            Button("取消", role: .cancel) {}
            Button("删除索引", role: .destructive) {
                session.removeIndexedPosts(withIDs: selectedPostIDs)
                endSelection()
            }
        } message: {
            Text(
                "所选 Post 会同时从媒体聚合、账号、标签和搜索结果中移除，但不会删除 Files 或照片中的媒体。仍在 X 书签中的 Post 可能在下次同步时重新出现。"
            )
        }
    }

    private func indexedPostRow(
        _ post: BookmarkedPost,
        showsSelection: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if showsSelection {
                Image(
                    systemName: selectedPostIDs.contains(post.id)
                        ? "checkmark.circle.fill"
                        : "circle"
                )
                .font(.title3)
                .foregroundStyle(
                    selectedPostIDs.contains(post.id)
                        ? Color.accentColor
                        : Color.secondary
                )
                .padding(.top, 2)
            }

            BookmarkPostRowView(
                post: post,
                showsAuthor: true,
                previewMode: previewMode
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var selectionBar: some View {
        HStack {
            Text(
                L10n.format(
                    "已选择 %lld 项",
                    selectedPostIDs.count
                )
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            Spacer()

            Button("删除索引", role: .destructive) {
                confirmsIndexRemoval = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(selectedPostIDs.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private func toggleSelection(for postID: String) {
        if selectedPostIDs.contains(postID) {
            selectedPostIDs.remove(postID)
        } else {
            selectedPostIDs.insert(postID)
        }
    }

    private func endSelection() {
        isSelecting = false
        selectedPostIDs.removeAll()
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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if showsAuthor {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(post.authorName ?? "未知作者")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let username = post.authorUsername {
                            Text("@\(username)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !showsAuthor {
                    Spacer(minLength: 0)
                }
                if let date = post.createdAt {
                    Text(date, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
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
                    .fixedSize(horizontal: false, vertical: true)
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func postMediaGrid(_ media: [BookmarkedMedia]) -> some View {
        if media.count == 1, let item = media.first {
            GeometryReader { geometry in
                LocalMediaThumbnailView(
                    media: item,
                    maximumPixelSize: 900
                )
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height
                )
                .clipped()
            }
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
                return L10n.format(
                    "%@ + 待分析",
                    Self.byteFormatter.string(fromByteCount: known)
                )
            }
            return L10n.string("大小待分析")
        }
        return Self.byteFormatter.string(fromByteCount: bytes)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
