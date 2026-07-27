import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct BookmarksView: View {
    @ObservedObject var session: BrowserSessionModel
    @ObservedObject var viewModel: BookmarksViewModel
    @Environment(\.openURL) private var openURL
    @State private var expandedAccounts: Set<String> = []
    @State private var expandedHashtags: Set<String> = []
    @State private var groupLimits: [String: Int] = [:]
    @State private var postLimit = 100
    @State private var showsStorage = false
    @State private var choosesExportFolder = false
    @AppStorage("bookmarkPostPreviewMode")
    private var previewModeRaw = BookmarkPostPreviewMode.media.rawValue

    private var previewMode: BookmarkPostPreviewMode {
        BookmarkPostPreviewMode(rawValue: previewModeRaw) ?? .media
    }

    private var statistics: BookmarkStatistics {
        BookmarkStatistics.calculate(from: session.capturedPosts)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    if session.capturedPosts.isEmpty {
                        emptyState
                    } else {
                        statisticsCard
                        filterCard
                        saveCard
                        browseCard
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("书签媒体")
            .searchable(
                text: $viewModel.searchText,
                prompt: "搜索账号、正文或 #标签"
            )
            .searchScopes($viewModel.searchField) {
                ForEach(BookmarkSearchField.allCases) { field in
                    Text(field.title).tag(field)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        showsStorage = true
                    } label: {
                        Image(systemName: "internaldrive")
                    }
                    if session.isAutoCapturing {
                        Button("停止") { session.stopAutoCapture() }
                    } else {
                        Button {
                            session.startAutoCapture()
                        } label: {
                            Label(
                                "同步",
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                        }
                    }
                }
            }
        }
        .onAppear {
            viewModel.update(posts: session.capturedPosts)
        }
        .onReceive(session.$capturedPosts) {
            viewModel.update(posts: $0)
        }
        .sheet(isPresented: $showsStorage) {
            StorageManagementView(
                session: session,
                bookmarksViewModel: viewModel
            )
        }
        .fileImporter(
            isPresented: $choosesExportFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    viewModel.startExporting(
                        posts: session.capturedPosts,
                        destination: url
                    )
                }
            case .failure(let error):
                viewModel.presentedError = PresentedError(
                    message: error.localizedDescription,
                    offersSettings: false
                )
            }
        }
        .alert(item: $viewModel.presentedError) { error in
            if error.offersSettings {
                return Alert(
                    title: Text("需要照片权限"),
                    message: Text(error.message),
                    primaryButton: .default(Text("打开设置")) {
                        guard let url = URL(
                            string: UIApplication.openSettingsURLString
                        ) else { return }
                        openURL(url)
                    },
                    secondaryButton: .cancel()
                )
            }
            return Alert(
                title: Text("操作未完成"),
                message: Text(error.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bookmark.square")
                .font(.system(size: 48))
                .foregroundStyle(.cyan, .purple)
                .symbolRenderingMode(.palette)
            Text("还没有捕获书签")
                .font(.title3.bold())
            Text("首次在“X 浏览器”登录后，App 会自动快速增量同步；已有 Post 不会重复添加。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if session.isAutoCapturing {
                ProgressView("正在同步…")
            } else {
                Button {
                    session.startAutoCapture()
                } label: {
                    Label(
                        "同步书签",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .saverCard()
    }

    private var statisticsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("本地增量索引", systemImage: "chart.bar.xaxis")
                .font(.headline)
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 10
            ) {
                stat("已索引 Post", statistics.bookmarkCount, "bookmark")
                galleryStat(
                    "含媒体",
                    statistics.photoCount
                        + statistics.gifCount
                        + statistics.videoCount,
                    "paperclip",
                    type: nil
                )
                galleryStat(
                    "图片",
                    statistics.photoCount,
                    "photo",
                    type: .photo
                )
                galleryStat(
                    "动图",
                    statistics.gifCount,
                    "sparkles.tv",
                    type: .animatedGIF
                )
                galleryStat(
                    "视频",
                    statistics.videoCount,
                    "video",
                    type: .video
                )
            }

            if session.isAutoCapturing {
                ProgressView(
                    session.syncStatusText
                        ?? "正在快速增量同步…"
                )
            } else if let status = session.syncStatusText {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if session.sizeAnalysisRemaining > 0 {
                ProgressView(
                    "后台分析媒体大小：剩余 \(session.sizeAnalysisRemaining) 项"
                )
                .font(.caption)
            } else {
                Button {
                    session.analyzeMissingMediaSizes(
                        retryUnavailable: true
                    )
                } label: {
                    Label("分析未识别的媒体大小", systemImage: "ruler")
                }
                .font(.caption)
            }

            Text("重新同步只更新已有 Post 并追加新 Post；不会因 X 端删除而移除本地记录。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .saverCard()
    }

    private func stat(
        _ title: String,
        _ value: Int,
        _ systemImage: String
    ) -> some View {
        HStack {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(value, format: .number)
                    .font(.title3.bold().monospacedDigit())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color(uiColor: .tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func galleryStat(
        _ title: String,
        _ value: Int,
        _ systemImage: String,
        type: BookmarkMediaType?
    ) -> some View {
        NavigationLink {
            MediaGalleryView(
                posts: session.capturedPosts,
                mediaType: type
            )
        } label: {
            HStack {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(value, format: .number)
                        .font(.title3.bold().monospacedDigit())
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Color(uiColor: .tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var filterCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("下载与浏览筛选", systemImage: "line.3.horizontal.decrease.circle")
                .font(.headline)
            Toggle("图片", isOn: $viewModel.filter.includePhotos)
            Toggle("动图（最高质量 MP4）", isOn: $viewModel.filter.includeGIFs)
            Toggle("视频", isOn: $viewModel.filter.includeVideos)

            Divider()

            Picker("视频/动图时长", selection: $viewModel.filter.durationRange) {
                ForEach(MediaDurationRange.allCases) {
                    Text($0.title).tag($0)
                }
            }
            Picker("Post 媒体总大小", selection: $viewModel.filter.sizeRange) {
                ForEach(MediaSizeRange.allCases) {
                    Text($0.title).tag($0)
                }
            }

            Toggle("设置起始日期", isOn: $viewModel.filter.useStartDate)
            if viewModel.filter.useStartDate {
                DatePicker(
                    "从",
                    selection: $viewModel.filter.startDate,
                    displayedComponents: .date
                )
            }
            Toggle("设置结束日期", isOn: $viewModel.filter.useEndDate)
            if viewModel.filter.useEndDate {
                DatePicker(
                    "到",
                    selection: $viewModel.filter.endDate,
                    displayedComponents: .date
                )
            }
            Text("日期按 Post 发布时间；媒体大小是该 Post 内全部媒体的合计。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .saverCard()
    }

    private var saveCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("保存与导出", systemImage: "square.and.arrow.down")
                    .font(.headline)
                Spacer()
                Text(
                    "\(viewModel.selectedStorageEstimate.itemCount) 项筛选结果"
                )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 5) {
                Label(
                    "筛选合计：\(storageEstimateText(viewModel.selectedStorageEstimate))",
                    systemImage: "externaldrive"
                )
                .font(.subheadline.weight(.semibold))

                Text(
                    "去重后预计新增：照片 \(storageEstimateText(viewModel.photoNewStorageEstimate))；App 资料库 \(storageEstimateText(viewModel.filesNewStorageEstimate))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Text("这是已分析媒体文件大小的加和；Photos 的实际磁盘占用可能因系统处理略有差异，另选 Files 文件夹则以该文件夹已有内容为准。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Color(uiColor: .tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if viewModel.alreadySavedCount > 0 {
                Toggle(
                    "允许重新保存已完成的 \(viewModel.alreadySavedCount) 项",
                    isOn: $viewModel.allowResaving
                )
                .font(.caption)
            }

            if viewModel.isSaving || viewModel.isExporting {
                operationProgress
            } else {
                Button {
                    viewModel.startSaving(posts: session.capturedPosts)
                } label: {
                    Label(
                        "批量下载并保存到照片",
                        systemImage: "photo.badge.arrow.down"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.selectedMediaCount == 0)

                Button {
                    viewModel.startExporting(posts: session.capturedPosts)
                } label: {
                    Label(
                        "流式保存到“我的 iPhone/X Media Saver”",
                        systemImage: "folder.badge.plus"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    choosesExportFolder = true
                } label: {
                    Label(
                        "选择其他 Files/iCloud 文件夹",
                        systemImage: "folder"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if let result = viewModel.result {
                resultLabel(
                    "照片：保存 \(result.saved)，跳过 \(result.skipped)，失败 \(result.failed)",
                    failed: result.failed
                )
            }
            if let result = viewModel.exportResult {
                resultLabel(
                    "Files：写入 \(result.saved)，已存在 \(result.skipped)，失败 \(result.failed)",
                    failed: result.failed
                )
                Text(result.destination.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("Files 资料库按 Images、Animated GIFs、Videos 分类，并生成 posts.jsonl；已存在的 media_key 会跳过。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu("已有旧版照片？") {
                Button("将当前筛选标记为已保存（不下载）") {
                    Task {
                        await viewModel.markCurrentSelectionAsSaved(
                            posts: session.capturedPosts
                        )
                    }
                }
            }
            .font(.caption)
        }
        .saverCard()
    }

    private var operationProgress: some View {
        let completed = viewModel.isSaving
            ? viewModel.progress.completed
            : viewModel.exportProgress.completed
        let total = max(
            viewModel.isSaving
                ? viewModel.progress.total
                : viewModel.exportProgress.total,
            1
        )
        let fraction = viewModel.isSaving
            ? viewModel.progress.currentFraction
            : viewModel.exportProgress.currentFraction
        return VStack(spacing: 8) {
            ProgressView(
                value: min(
                    (Double(completed) + fraction) / Double(total),
                    1
                )
            )
            HStack {
                Text("\(completed)/\(total)")
                    .font(.caption.monospacedDigit())
                Spacer()
                Button("取消", role: .cancel) {
                    viewModel.cancelCurrentOperation()
                }
            }
        }
    }

    private func resultLabel(_ text: String, failed: Int) -> some View {
        Label(
            text,
            systemImage: failed == 0
                ? "checkmark.circle.fill"
                : "exclamationmark.triangle.fill"
        )
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(failed == 0 ? Color.green : Color.orange)
    }

    private func storageEstimateText(
        _ estimate: MediaStorageEstimate
    ) -> String {
        var value = Self.byteFormatter.string(
            fromByteCount: estimate.knownBytes
        )
        value += " / \(estimate.itemCount) 项"
        if estimate.unknownSizeCount > 0 {
            value += "（另 \(estimate.unknownSizeCount) 项大小未知）"
        }
        return value
    }

    private var browseCard: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("浏览与搜索")
                    .font(.headline)
                Spacer()
                Button {
                    previewModeRaw = previewMode == .media
                        ? BookmarkPostPreviewMode.text.rawValue
                        : BookmarkPostPreviewMode.media.rawValue
                } label: {
                    Label(
                        previewMode == .media ? "媒体" : "纯文字",
                        systemImage: previewMode == .media
                            ? "photo.on.rectangle"
                            : "text.alignleft"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Text("\(viewModel.visiblePosts.count) 条")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("默认显示媒体时间线；右上角可切换纯文字。搜索范围请直接在顶部搜索栏选择。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("查看方式", selection: $viewModel.browseMode) {
                ForEach(BookmarkBrowseMode.allCases) {
                    Text($0.title).tag($0)
                }
            }
            .pickerStyle(.segmented)

            sortMenu
            Divider()

            switch viewModel.browseMode {
            case .accounts: accountResults
            case .posts: postResults
            case .hashtags: hashtagResults
            }
        }
        .saverCard()
    }

    @ViewBuilder
    private var sortMenu: some View {
        HStack {
            Spacer()
            switch viewModel.browseMode {
            case .accounts:
                Picker("账号排序", selection: $viewModel.accountSort) {
                    ForEach(BookmarkAccountSort.allCases) {
                        Text($0.title).tag($0)
                    }
                }
            case .posts:
                Picker("Post 排序", selection: $viewModel.postSort) {
                    ForEach(BookmarkPostSort.allCases) {
                        Text($0.title).tag($0)
                    }
                }
            case .hashtags:
                Picker("标签排序", selection: $viewModel.hashtagSort) {
                    ForEach(BookmarkHashtagSort.allCases) {
                        Text($0.title).tag($0)
                    }
                }
            }
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private var accountResults: some View {
        if viewModel.visibleAccountGroups.isEmpty {
            noResults("没有符合条件的账号")
        } else {
            ForEach(viewModel.visibleAccountGroups) { group in
                DisclosureGroup(
                    isExpanded: expansionBinding(
                        for: group.id,
                        in: $expandedAccounts
                    )
                ) {
                    let limit = groupLimits[group.id] ?? 40
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(group.posts.prefix(limit))) { post in
                            postLink(post, showsAuthor: false)
                        }
                        if group.posts.count > limit {
                            Button("再显示 40 条") {
                                groupLimits[group.id] = limit + 40
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.authorName ?? "未知作者")
                                .font(.subheadline.weight(.semibold))
                            if let username = group.authorUsername {
                                Text("@\(username)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text("\(group.posts.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
            }
        }
    }

    @ViewBuilder
    private var postResults: some View {
        if viewModel.visiblePosts.isEmpty {
            noResults("没有符合条件的 Post")
        } else {
            ForEach(Array(viewModel.visiblePosts.prefix(postLimit))) {
                postLink($0, showsAuthor: true)
                Divider()
            }
            if viewModel.visiblePosts.count > postLimit {
                Button("再显示 100 条") { postLimit += 100 }
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var hashtagResults: some View {
        if viewModel.visibleHashtagGroups.isEmpty {
            noResults("筛选结果中没有 Hashtag")
        } else {
            ForEach(viewModel.visibleHashtagGroups) { group in
                DisclosureGroup(
                    isExpanded: expansionBinding(
                        for: group.id,
                        in: $expandedHashtags
                    )
                ) {
                    let limit = groupLimits[group.id] ?? 40
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(group.posts.prefix(limit))) {
                            postLink($0, showsAuthor: true)
                        }
                        if group.posts.count > limit {
                            Button("再显示 40 条") {
                                groupLimits[group.id] = limit + 40
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    HStack {
                        Text("#\(group.title)")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(group.posts.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
            }
        }
    }

    private func postLink(
        _ post: BookmarkedPost,
        showsAuthor: Bool
    ) -> some View {
        NavigationLink {
            BookmarkPostDetailView(post: post)
        } label: {
            postRow(post, showsAuthor: showsAuthor)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func postRow(
        _ post: BookmarkedPost,
        showsAuthor: Bool
    ) -> some View {
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

    private func noResults(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func expansionBinding(
        for id: String,
        in values: Binding<Set<String>>
    ) -> Binding<Bool> {
        Binding(
            get: { values.wrappedValue.contains(id) },
            set: {
                if $0 {
                    values.wrappedValue.insert(id)
                } else {
                    values.wrappedValue.remove(id)
                }
            }
        )
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

private enum BookmarkPostPreviewMode: String {
    case media
    case text
}
