import SwiftUI

struct DuplicateMediaView: View {
    let posts: [BookmarkedPost]
    @State private var groups: [DuplicateMediaGroup] = []
    @State private var localKeys: Set<String> = []
    @State private var isScanning = false
    @State private var progress = ""
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?
    @State private var visibleLimit = 90
    private let analyzer = MediaDuplicateAnalyzer()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("先按相同媒体 ID／来源地址归组；本地文件内容扫描使用 SHA-256，不会修改或删除文件。")
                    .font(.caption).foregroundStyle(.secondary)
                if isScanning {
                    HStack {
                        ProgressView()
                        Text(progress).font(.caption)
                        Spacer()
                        Button("取消") { task?.cancel() }
                    }
                } else {
                    Button { scan(hashFiles: true) } label: {
                        Label("扫描本地重复文件内容", systemImage: "doc.text.magnifyingglass")
                    }.buttonStyle(.bordered)
                }
                if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
                Text(L10n.format("%lld 组重复媒体", groups.count)).font(.caption)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                    ForEach(Array(groups.prefix(visibleLimit))) { group in
                        NavigationLink {
                            DuplicatePostsView(group: group, relatedPosts: posts)
                        } label: {
                            duplicateCell(group)
                        }.buttonStyle(.plain)
                    }
                }
                if groups.count > visibleLimit {
                    Button("再显示 100 条") { visibleLimit += 100 }
                }
            }.padding()
        }
        .navigationTitle("重复媒体")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if task == nil { scan(hashFiles: false) } }
        .onDisappear { task?.cancel() }
    }

    private func duplicateCell(_ group: DuplicateMediaGroup) -> some View {
        let representative = group.references.first { localKeys.contains($0.media.mediaKey) } ?? group.references[0]
        return GeometryReader { geometry in
            LocalMediaThumbnailView(media: representative.media, maximumPixelSize: 420, showsLocalIndicator: false)
                .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                .overlay(alignment: .bottomTrailing) {
                    Text(L10n.format("%lld 条 Post", group.posts.count))
                        .font(.caption2).foregroundStyle(.white).padding(4)
                        .background(.black.opacity(0.65)).clipShape(RoundedRectangle(cornerRadius: 4)).padding(4)
                }
        }.aspectRatio(1, contentMode: .fit).clipped()
    }

    private func scan(hashFiles: Bool) {
        task?.cancel()
        isScanning = true
        errorMessage = nil
        progress = L10n.string("正在扫描…")
        task = Task { @MainActor in
            do {
                let found = try await analyzer.scan(posts: posts, hashLocalFiles: hashFiles) { done, total in
                    Task { @MainActor in progress = "\(done) / \(total)" }
                }
                guard !Task.isCancelled else { isScanning = false; return }
                groups = found
                localKeys = await LocalMediaLibrary.shared.availableMediaKeys()
            } catch is CancellationError {
            } catch { errorMessage = error.localizedDescription }
            isScanning = false
        }
    }
}

private struct DuplicatePostsView: View {
    let group: DuplicateMediaGroup
    let relatedPosts: [BookmarkedPost]
    @State private var sort = BookmarkPostSort.newest

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(BookmarkPostOrdering.sorted(group.posts, by: sort)) { post in
                    NavigationLink {
                        BookmarkPostDetailView(post: post, relatedPosts: relatedPosts)
                    } label: {
                        BookmarkPostRowView(post: post, showsAuthor: true, previewMode: .media)
                            .padding()
                    }.buttonStyle(.plain)
                    Divider()
                }
            }
        }
        .navigationTitle("包含此媒体的 Post")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("Post 排序", selection: $sort) {
                        ForEach(BookmarkPostSort.allCases) { Text($0.title).tag($0) }
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
            }
        }
    }
}

struct FolderExportAuditView: View {
    @State private var report: FolderExportAudit?
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var visibleLimit = 100

    private var entries: [FolderExportAudit.PostEntry] {
        (report?.posts ?? []).filter { searchText.isEmpty || $0.postID.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            if let report {
                Section {
                    Text(report.createdAt, style: .date)
                    Text("报告包含已保存、下载失败，以及未进入下载队列的 Post；可按 Post ID 搜索。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(entries.prefix(visibleLimit)), id: \.postID) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.postID).font(.subheadline.monospaced())
                        Text(L10n.format("索引媒体 %lld · 本次选择 %lld", entry.indexedMediaCount, entry.selectedMediaCount))
                            .font(.caption).foregroundStyle(.secondary)
                        if let reason = entry.exclusionReason {
                            Text(exclusionTitle(reason)).font(.caption).foregroundStyle(.orange)
                        }
                        ForEach(entry.media, id: \.mediaKey) { media in
                            Text(media.error ?? media.relativePath ?? media.outcome)
                                .font(.caption2).foregroundStyle(media.error == nil ? Color.secondary : .orange)
                        }
                        if let url = entry.postURL { Link("在 X 中查看原帖", destination: url).font(.caption) }
                    }
                }
                if entries.count > visibleLimit {
                    Button("再显示 100 条") { visibleLimit += 100 }
                }
            } else {
                Text(errorMessage ?? L10n.string("完成一次 Folder 保存后可在这里查看报告。"))
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("最近保存报告")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Post ID")
        .task {
            do {
                report = try await Task.detached(priority: .utility) {
                    let url = StorageManager.appDocumentsLibraryURL.appendingPathComponent("last-export-report.json")
                    guard FileManager.default.fileExists(atPath: url.path) else { return nil as FolderExportAudit? }
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    return try decoder.decode(FolderExportAudit.self, from: Data(contentsOf: url))
                }.value
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func exclusionTitle(_ reason: String) -> String {
        switch reason {
        case "no_parsed_media": return L10n.string("索引未解析到媒体；可重新打开原帖以更新索引")
        case "filter_search_or_local_save_state": return L10n.string("未通过下载筛选、搜索或本地保存状态条件")
        default: return L10n.string("本次未选择此 Post 的媒体")
        }
    }
}
