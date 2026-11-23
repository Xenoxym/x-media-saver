import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct SimilarMediaView: View {
    let posts: [BookmarkedPost]
    @State private var tab = MediaTab.photos

    private enum MediaTab: Hashable { case photos, videos }

    var body: some View {
        VStack(spacing: 0) {
            Picker("媒体类型", selection: $tab) {
                Text("图片").tag(MediaTab.photos)
                Text("视频").tag(MediaTab.videos)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            ZStack {
                PhotoSimilarityView(posts: posts)
                    .opacity(tab == .photos ? 1 : 0)
                    .allowsHitTesting(tab == .photos)
                    .accessibilityHidden(tab != .photos)
                VideoSimilarityView(posts: posts)
                    .opacity(tab == .videos ? 1 : 0)
                    .allowsHitTesting(tab == .videos)
                    .accessibilityHidden(tab != .videos)
            }
        }
        .navigationTitle("相似媒体")
        .navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
private struct PhotoSimilarityView: View {
    let posts: [BookmarkedPost]
    @State private var mode = PhotoSimilarityMode.standard
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var importsFile = false
    @State private var query: PhotoVisualFingerprint?
    @State private var result: PhotoScanResult?
    @State private var operation: Task<Void, Never>?
    @State private var operationID: UUID?
    @State private var progress: String?
    @State private var notice: String?

    var body: some View {
        List {
            Section {
                Picker("图片匹配方式", selection: $mode) {
                    ForEach(PhotoSimilarityMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Button {
                    scan(indexLocal: false)
                } label: {
                    Label(L10n.string(query == nil ? "快速扫描图片" : "查找参考图"), systemImage: "magnifyingglass")
                }
                .disabled(operationID != nil)
                Button {
                    scan(indexLocal: true)
                } label: {
                    Label("更新本地图片索引并搜索", systemImage: "externaldrive")
                }
                .disabled(operationID != nil)
            } footer: {
                Text("严格和标准档比较整图，深度档也比较局部，适合轻度裁切或角标。快速扫描使用已有指纹；更新索引才读取 Folder 图片。")
            }

            Section("以图找帖") {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label("从照片选择", systemImage: "photo.on.rectangle")
                }
                .disabled(operationID != nil)
                Button {
                    importsFile = true
                } label: {
                    Label("从 Files 选择图片", systemImage: "folder")
                }
                .disabled(operationID != nil)
                if query != nil {
                    Button("清除参考图") {
                        cancel()
                        query = nil
                        result = nil
                        notice = nil
                    }
                }
            }
            if operationID != nil {
                Section {
                    HStack {
                        ProgressView()
                        Text(progress ?? L10n.string("正在比较图片…"))
                            .font(.subheadline)
                        Spacer()
                        Button("取消", action: cancel)
                            .buttonStyle(.borderless)
                    }
                }
            }
            if let notice {
                Section {
                    Text(notice).foregroundStyle(.secondary)
                }
            }
            if let result {
                results(result)
            }
        }
        .fileImporter(isPresented: $importsFile, allowedContentTypes: [.image]) { selection in
            if case .success(let url) = selection {
                importQuery(.file(url))
            }
        }
        .onChange(of: selectedPhoto) { photo in
            guard let photo else { return }
            selectedPhoto = nil
            importQuery(.photos(photo))
        }
        .onChange(of: mode) { _ in
            cancel()
            notice = nil
            result = nil
        }
        .onDisappear { cancel() }
    }

    private func results(_ result: PhotoScanResult) -> some View {
        Section {
            if result.matches.isEmpty, result.groups.isEmpty {
                Text("没有找到符合条件的图片。")
                    .foregroundStyle(.secondary)
            }
            if result.isQuery, result.fingerprintCount == 0 {
                Text("暂时没有可比较的图片指纹。可先更新本地图片索引，或正常浏览图片以积累指纹。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(result.matches) { match in
                if let second = result.references[match.secondID] {
                    let first = match.firstID.flatMap { result.references[$0] }
                    NavigationLink {
                        PhotoSimilarityDetail(
                            first: first, second: second, evidence: match.evidence, posts: posts
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            if let first {
                                Label(first.description, systemImage: "photo")
                                    .lineLimit(1)
                            }
                            Label(second.description, systemImage: "photo")
                                .lineLimit(1)
                            Text(match.evidence.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            ForEach(result.groups) { group in
                photoGroup(group, result: result)
            }
        } header: {
            Text(result.isQuery
                ? L10n.format("%lld 条候选图片结果", result.matches.count)
                : L10n.format("%lld 组相似图片", result.groups.count))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.format(
                    "%lld 张索引图片 · %lld 张已有画面指纹",
                    result.photoCount, result.fingerprintCount
                ))
                if result.truncated {
                    Text("结果已达显示上限。")
                }
                Text("相似结果仅供核对，不会合并或删除文件。")
            }
        }
    }

    private func photoGroup(_ group: PhotoSimilarityGroup, result: PhotoScanResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.format("%lld 张图片", group.matches.count + 1))
                .font(.subheadline.weight(.semibold))
            let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                if let first = result.references[group.representativeID] {
                    photoTile(first, comparing: nil, evidence: group.matches.first?.evidence ?? .sameSource)
                    ForEach(group.matches) { match in
                        if let other = result.references[match.secondID] {
                            photoTile(other, comparing: first, evidence: match.evidence)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 5)
    }

    private func photoTile(
        _ reference: PhotoReference, comparing first: PhotoReference?, evidence: PhotoSimilarityEvidence
    ) -> some View {
        NavigationLink {
            PhotoSimilarityDetail(first: first, second: reference, evidence: evidence, posts: posts)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Color(uiColor: .secondarySystemGroupedBackground)
                    .aspectRatio(1.5, contentMode: .fit)
                    .overlay {
                        LocalMediaThumbnailView(
                            media: reference.media, maximumPixelSize: 420, contentMode: .fit,
                            showsLocalIndicator: false, allowsNetwork: false
                        )
                    }
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(reference.description).font(.caption).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    private func scan(indexLocal: Bool) {
        start(indexLocal: indexLocal, input: nil)
    }

    private func importQuery(_ source: QuerySource) {
        query = nil
        start(indexLocal: false, input: source)
    }

    private func start(indexLocal: Bool, input: QuerySource?) {
        cancel()
        let id = UUID()
        let selectedMode = mode
        let knownQuery = query
        let sourcePosts = posts
        operationID = id
        result = nil
        notice = nil
        operation = Task { @MainActor in
            let worker = Task.detached(priority: .utility) {
                let fingerprint: PhotoVisualFingerprint?
                if let input {
                    guard let imported = try await input.fingerprint() else { throw QueryError.unreadable }
                    fingerprint = imported
                } else {
                    fingerprint = knownQuery
                }
                try Task.checkCancellation()
                let photos = sourcePosts.flatMap(\.media).filter { $0.type == .photo }
                if indexLocal {
                    try await PhotoSimilarityIndex.shared.indexLocalPhotos(photos) { done, total in
                        await MainActor.run {
                            if operationID == id {
                                progress = L10n.format("本地图片索引：%lld / %lld", done, total)
                            }
                        }
                    }
                }
                let candidates = await PhotoSimilarityIndex.shared.descriptors(for: photos)
                let ranked: (matches: [PhotoSimilarityMatch], truncated: Bool)
                let groups: [PhotoSimilarityGroup]
                if let fingerprint {
                    ranked = try PhotoSimilarityMatcher.scan(candidates, mode: selectedMode, query: fingerprint)
                    groups = []
                } else {
                    ranked = ([], false)
                    groups = try PhotoSimilarityMatcher.groups(candidates, mode: selectedMode)
                }
                let found = PhotoScanResult.make(
                    posts: sourcePosts, candidates: candidates, query: fingerprint, ranked: ranked, groups: groups
                )
                return (fingerprint, found)
            }
            defer {
                if operationID == id {
                    operation = nil
                    operationID = nil
                    progress = nil
                }
            }
            do {
                let (fingerprint, found) = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                guard !Task.isCancelled, operationID == id else { return }
                query = fingerprint
                result = found
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled, operationID == id {
                    notice = L10n.string(input == nil ? "无法完成图片比较，请重试。" : "无法读取参考图，或画面信息不足。")
                }
            }
        }
    }

    private func cancel() {
        operation?.cancel()
        operation = nil
        operationID = nil
        progress = nil
    }

    private enum QueryError: Error { case unreadable }

    private enum QuerySource: Sendable {
        case file(URL)
        case photos(PhotosPickerItem)

        func fingerprint() async throws -> PhotoVisualFingerprint? {
            switch self {
            case .file(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return PhotoVisualFingerprint.from(file: url)
            case .photos(let item):
                guard let data = try await item.loadTransferable(type: Data.self) else { return nil }
                try Task.checkCancellation()
                return PhotoVisualFingerprint.from(data: data)
            }
        }
    }
}

private struct PhotoScanResult: Sendable {
    let matches: [PhotoSimilarityMatch]
    let groups: [PhotoSimilarityGroup]
    let truncated: Bool
    let isQuery: Bool
    let photoCount: Int
    let fingerprintCount: Int
    let references: [String: PhotoReference]

    static func make(
        posts: [BookmarkedPost], candidates: [PhotoSimilarityDescriptor],
        query: PhotoVisualFingerprint?, ranked: (matches: [PhotoSimilarityMatch], truncated: Bool),
        groups: [PhotoSimilarityGroup]
    ) -> Self {
        var ids = Set(ranked.matches.map(\.secondID))
        for group in groups {
            ids.insert(group.representativeID)
            ids.formUnion(group.matches.map(\.secondID))
        }
        var references: [String: PhotoReference] = [:]
        var seenByMediaKey: [String: Set<String>] = [:]
        for post in posts {
            for media in post.media where media.type == .photo && ids.contains(media.mediaKey) {
                guard seenByMediaKey[media.mediaKey, default: []].insert(post.id).inserted else { continue }
                references[media.mediaKey, default: PhotoReference(media: media)].posts.append(post)
            }
        }
        return Self(
            matches: ranked.matches, groups: groups, truncated: ranked.truncated, isQuery: query != nil,
            photoCount: candidates.count, fingerprintCount: candidates.filter { $0.fingerprint != nil }.count,
            references: references
        )
    }
}

private struct PhotoReference: Sendable {
    let media: BookmarkedMedia
    var posts: [BookmarkedPost] = []

    var description: String {
        let post = posts.first
        let author = post?.authorName ?? post?.authorUsername
        let caption = post?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let author, !caption.isEmpty { return author + " · " + caption }
        return author ?? (caption.isEmpty ? media.mediaKey : caption)
    }
}

private struct PhotoSimilarityDetail: View {
    let first: PhotoReference?
    let second: PhotoReference
    let evidence: PhotoSimilarityEvidence
    let posts: [BookmarkedPost]

    var body: some View {
        List {
            Section {
                Text(evidence.title)
                HStack(spacing: 8) {
                    if let first { preview(first) }
                    preview(second)
                }
            } footer: {
                Text("只预览本机已有图片。")
            }
            if let first { postSection("图片 A 的来源帖", reference: first) }
            postSection(first == nil ? "匹配图片的来源帖" : "图片 B 的来源帖", reference: second)
        }
        .navigationTitle("候选详情")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func preview(_ reference: PhotoReference) -> some View {
        LocalMediaThumbnailView(
            media: reference.media, maximumPixelSize: 420, showsLocalIndicator: false,
            allowsNetwork: false
        )
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func postSection(_ title: LocalizedStringKey, reference: PhotoReference) -> some View {
        Section(title) {
            ForEach(reference.posts) { post in
                NavigationLink {
                    BookmarkPostDetailView(post: post, relatedPosts: posts)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(post.authorName ?? post.authorUsername ?? post.id)
                            .font(.subheadline.weight(.semibold))
                        if !post.text.isEmpty {
                            Text(post.text).font(.caption).lineLimit(2)
                        }
                    }
                }
            }
        }
    }
}
