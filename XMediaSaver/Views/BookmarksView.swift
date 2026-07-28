import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct BookmarksView: View {
    @ObservedObject var session: BrowserSessionModel
    @ObservedObject var viewModel: BookmarksViewModel
    let onRequestVisibleSync: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var expandedAccounts: Set<String> = []
    @State private var expandedHashtags: Set<String> = []
    @State private var groupLimits: [String: Int] = [:]
    @State private var postLimit = 100
    @State private var choosesExportFolder = false
    @State private var showsRangeFilters = false
    @State private var dateRange: BookmarkDateRange = .all
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
            .navigationTitle("Bookmarks")
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
                    if session.isAutoCapturing {
                        Button("停止") { session.stopAutoCapture() }
                    } else {
                        Button {
                            onRequestVisibleSync()
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
            Text("首次在“X 浏览器”登录后点击“同步”，即可快速增量读取；已有 Post 不会重复添加。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if session.isAutoCapturing {
                ProgressView("正在同步…")
            } else {
                Button {
                    onRequestVisibleSync()
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
                indexedPostsStat
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
                        ?? L10n.string("正在快速增量同步…")
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

    private var indexedPostsStat: some View {
        NavigationLink {
            IndexedPostsView(session: session)
        } label: {
            HStack {
                Image(systemName: "bookmark")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statistics.bookmarkCount, format: .number)
                        .font(.title3.bold().monospacedDigit())
                    Text("已索引 Post")
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
                    Text(LocalizedStringKey(title))
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
            Toggle("动图（MP4）", isOn: $viewModel.filter.includeGIFs)
            Toggle("视频", isOn: $viewModel.filter.includeVideos)

            Divider()

            DisclosureGroup(isExpanded: $showsRangeFilters) {
                VStack(alignment: .leading, spacing: 16) {
                    compactRangeFilter(
                        title: "视频/动图时长",
                        lowerTitle: viewModel.filter.minimumDuration.title,
                        upperTitle: viewModel.filter.maximumDuration.title,
                        lowerValue: minimumDurationBinding,
                        upperValue: maximumDurationBinding,
                        labels: ["0", "1m", "10m", "30m", "1h", "∞"]
                    )

                    Divider()

                    compactRangeFilter(
                        title: "Post 媒体总大小",
                        lowerTitle: viewModel.filter.minimumSize.title,
                        upperTitle: viewModel.filter.maximumSize.title,
                        lowerValue: minimumSizeBinding,
                        upperValue: maximumSizeBinding,
                        labels: ["0", "10M", "50M", "200M", "500M", "∞"]
                    )

                    Text("区间包含左端、不包含右端；右端“不限”表示不设置上限。设置范围后，大小或时长未知的项目不会匹配。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 12)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("时长与大小")
                        .font(.subheadline.weight(.semibold))
                    Text(rangeFiltersSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Divider()

            HStack {
                Text("时间范围")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Menu {
                    ForEach(BookmarkDateRange.allCases) { range in
                        Button {
                            applyDateRange(range)
                        } label: {
                            if dateRange == range {
                                Label(range.title, systemImage: "checkmark")
                            } else {
                                Text(range.title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(dateRange.title)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                }
            }

            if dateRange == .custom {
                DatePicker(
                    "起始日期",
                    selection: $viewModel.filter.startDate,
                    displayedComponents: .date
                )
            }
            Text("时间范围按 Post 发布时间筛选至今天；媒体大小是该 Post 内全部媒体的合计。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .saverCard()
    }

    private var rangeFiltersSummary: String {
        L10n.format(
            "时长 %@–%@ · 大小 %@–%@",
            viewModel.filter.minimumDuration.title,
            viewModel.filter.maximumDuration.title,
            viewModel.filter.minimumSize.title,
            viewModel.filter.maximumSize.title
        )
    }

    private func applyDateRange(_ range: BookmarkDateRange) {
        dateRange = range
        viewModel.filter.useEndDate = false
        switch range {
        case .all:
            viewModel.filter.useStartDate = false
        case .oneDay, .threeDays, .sevenDays:
            viewModel.filter.useStartDate = true
            viewModel.filter.startDate = Calendar.current.date(
                byAdding: .day,
                value: -(range.dayCount - 1),
                to: Date()
            ) ?? Date()
        case .custom:
            viewModel.filter.useStartDate = true
        }
    }

    private func compactRangeFilter(
        title: String,
        lowerTitle: String,
        upperTitle: String,
        lowerValue: Binding<Double>,
        upperValue: Binding<Double>,
        labels: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(LocalizedStringKey(title))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(lowerTitle) – \(upperTitle)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            DiscreteRangeSlider(
                lowerValue: lowerValue,
                upperValue: upperValue,
                bounds: 0...5,
                minimumDistance: 1,
                labels: labels,
                lowerAccessibilityLabel: "\(title)下限",
                upperAccessibilityLabel: "\(title)上限"
            )
        }
    }

    private var minimumDurationBinding: Binding<Double> {
        Binding(
            get: { Double(viewModel.filter.minimumDuration.rawValue) },
            set: { value in
                let rawValue = Int(value.rounded())
                guard let limit = MediaDurationLimit(rawValue: rawValue) else {
                    return
                }
                viewModel.filter.minimumDuration = limit
                let maximum = viewModel.filter.maximumDuration
                if maximum != .unlimited,
                   maximum.rawValue <= rawValue,
                   let adjusted = MediaDurationLimit(rawValue: rawValue + 1) {
                    viewModel.filter.maximumDuration = adjusted
                }
            }
        )
    }

    private var maximumDurationBinding: Binding<Double> {
        Binding(
            get: { Double(viewModel.filter.maximumDuration.rawValue) },
            set: { value in
                let rawValue = Int(value.rounded())
                guard let limit = MediaDurationLimit(rawValue: rawValue) else {
                    return
                }
                viewModel.filter.maximumDuration = limit
                if rawValue <= viewModel.filter.minimumDuration.rawValue,
                   let adjusted = MediaDurationLimit(rawValue: rawValue - 1) {
                    viewModel.filter.minimumDuration = adjusted
                }
            }
        )
    }

    private var minimumSizeBinding: Binding<Double> {
        Binding(
            get: { Double(viewModel.filter.minimumSize.rawValue) },
            set: { value in
                let rawValue = Int(value.rounded())
                guard let limit = MediaSizeLimit(rawValue: rawValue) else {
                    return
                }
                viewModel.filter.minimumSize = limit
                let maximum = viewModel.filter.maximumSize
                if maximum != .unlimited,
                   maximum.rawValue <= rawValue,
                   let adjusted = MediaSizeLimit(rawValue: rawValue + 1) {
                    viewModel.filter.maximumSize = adjusted
                }
            }
        )
    }

    private var maximumSizeBinding: Binding<Double> {
        Binding(
            get: { Double(viewModel.filter.maximumSize.rawValue) },
            set: { value in
                let rawValue = Int(value.rounded())
                guard let limit = MediaSizeLimit(rawValue: rawValue) else {
                    return
                }
                viewModel.filter.maximumSize = limit
                if rawValue <= viewModel.filter.minimumSize.rawValue,
                   let adjusted = MediaSizeLimit(rawValue: rawValue - 1) {
                    viewModel.filter.minimumSize = adjusted
                }
            }
        )
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
                    "保存到照片：\(storageEstimateText(viewModel.selectedStorageEstimate))；文件夹预计新增：\(storageEstimateText(viewModel.filesNewStorageEstimate))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Text("保存到照片不做历史去重；重复操作会在相册中再次保存。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            .padding(10)
            .background(Color(uiColor: .tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))

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
                        "保存到 X Media Saver 文件夹",
                        systemImage: "folder.badge.plus"
                    )
                    .frame(maxWidth: .infinity)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
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
        value += L10n.format(" / %lld 项", estimate.itemCount)
        if estimate.unknownSizeCount > 0 {
            value += L10n.format(
                "（另 %lld 项大小未知）",
                estimate.unknownSizeCount
            )
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
            Text("“帖子”显示当前筛选结果；账号和 Hashtag 用于聚合浏览。搜索范围请直接在顶部搜索栏选择。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("查看方式", selection: $viewModel.browseMode) {
                ForEach(BookmarkBrowseMode.allCases) {
                    Text(LocalizedStringKey($0.titleKey)).tag($0)
                }
            }
            .pickerStyle(.segmented)

            sortMenu
            Divider()

            switch viewModel.browseMode {
            case .posts: postResults
            case .accounts: accountResults
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
            case .posts:
                Picker("Post 排序", selection: $viewModel.postSort) {
                    ForEach(BookmarkPostSort.allCases) {
                        Text($0.title).tag($0)
                    }
                }
            case .accounts:
                Picker("账号排序", selection: $viewModel.accountSort) {
                    ForEach(BookmarkAccountSort.allCases) {
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
    private var postResults: some View {
        if viewModel.visiblePosts.isEmpty {
            noResults("没有符合条件的 Post")
        } else {
            ForEach(Array(viewModel.visiblePosts.prefix(postLimit))) {
                postLink($0, showsAuthor: true)
                Divider()
            }
            if viewModel.visiblePosts.count > postLimit {
                Button("再显示 100 条") {
                    postLimit += 100
                }
                .font(.caption)
            }
        }
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
            BookmarkPostRowView(
                post: post,
                showsAuthor: showsAuthor,
                previewMode: previewMode
            )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

private enum BookmarkDateRange: String, CaseIterable, Identifiable {
    case all
    case oneDay
    case threeDays
    case sevenDays
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return L10n.string("不限")
        case .oneDay: return L10n.string("最近一天")
        case .threeDays: return L10n.string("最近三天")
        case .sevenDays: return L10n.string("最近七天")
        case .custom: return L10n.string("自定义起始日期")
        }
    }

    var dayCount: Int {
        switch self {
        case .oneDay: return 1
        case .threeDays: return 3
        case .sevenDays: return 7
        case .all, .custom: return 0
        }
    }
}

private struct DiscreteRangeSlider: View {
    @Binding var lowerValue: Double
    @Binding var upperValue: Double

    let bounds: ClosedRange<Double>
    let minimumDistance: Double
    let labels: [String]
    let lowerAccessibilityLabel: String
    let upperAccessibilityLabel: String

    private let thumbDiameter: CGFloat = 28
    private static let coordinateSpaceName = "DiscreteRangeSliderTrack"

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                let usableWidth = max(
                    proxy.size.width - thumbDiameter,
                    1
                )
                let lowerX = xPosition(
                    for: lowerValue,
                    usableWidth: usableWidth
                )
                let upperX = xPosition(
                    for: upperValue,
                    usableWidth: usableWidth
                )

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(uiColor: .systemFill))
                        .frame(width: usableWidth, height: 4)
                        .position(
                            x: thumbDiameter / 2 + usableWidth / 2,
                            y: proxy.size.height / 2
                        )

                    Capsule()
                        .fill(Color.accentColor)
                        .frame(
                            width: max(upperX - lowerX, 0),
                            height: 4
                        )
                        .position(
                            x: lowerX + max(upperX - lowerX, 0) / 2,
                            y: proxy.size.height / 2
                        )

                    lowerThumb(usableWidth: usableWidth)
                        .position(x: lowerX, y: proxy.size.height / 2)

                    upperThumb(usableWidth: usableWidth)
                        .position(x: upperX, y: proxy.size.height / 2)
                }
                .coordinateSpace(name: Self.coordinateSpaceName)
            }
            .frame(height: thumbDiameter + 4)

            HStack(spacing: 0) {
                ForEach(Array(labels.enumerated()), id: \.offset) {
                    _, label in
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .minimumScaleFactor(0.65)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func lowerThumb(usableWidth: CGFloat) -> some View {
        sliderThumb
            .gesture(
                DragGesture(
                    minimumDistance: 0,
                    coordinateSpace: .named(Self.coordinateSpaceName)
                )
                    .onChanged { value in
                        lowerValue = clampedLowerValue(
                            trackValue(
                                at: value.location.x,
                                usableWidth: usableWidth
                            )
                        )
                    }
            )
            .accessibilityLabel(lowerAccessibilityLabel)
            .accessibilityValue(accessibilityTitle(for: lowerValue))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    lowerValue = clampedLowerValue(lowerValue + 1)
                case .decrement:
                    lowerValue = clampedLowerValue(lowerValue - 1)
                @unknown default:
                    break
                }
            }
    }

    private func upperThumb(usableWidth: CGFloat) -> some View {
        sliderThumb
            .gesture(
                DragGesture(
                    minimumDistance: 0,
                    coordinateSpace: .named(Self.coordinateSpaceName)
                )
                    .onChanged { value in
                        upperValue = clampedUpperValue(
                            trackValue(
                                at: value.location.x,
                                usableWidth: usableWidth
                            )
                        )
                    }
            )
            .accessibilityLabel(upperAccessibilityLabel)
            .accessibilityValue(accessibilityTitle(for: upperValue))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    upperValue = clampedUpperValue(upperValue + 1)
                case .decrement:
                    upperValue = clampedUpperValue(upperValue - 1)
                @unknown default:
                    break
                }
            }
    }

    private var sliderThumb: some View {
        Circle()
            .fill(Color(uiColor: .systemBackground))
            .overlay {
                Circle()
                    .stroke(Color.accentColor, lineWidth: 2)
            }
            .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
            .frame(width: thumbDiameter, height: thumbDiameter)
            .contentShape(Circle())
    }

    private func xPosition(
        for value: Double,
        usableWidth: CGFloat
    ) -> CGFloat {
        let span = max(bounds.upperBound - bounds.lowerBound, 1)
        let progress = (value - bounds.lowerBound) / span
        return thumbDiameter / 2 + usableWidth * CGFloat(progress)
    }

    private func trackValue(
        at xPosition: CGFloat,
        usableWidth: CGFloat
    ) -> Double {
        let span = bounds.upperBound - bounds.lowerBound
        let progress = min(
            max(
                Double(
                    (xPosition - thumbDiameter / 2) / usableWidth
                ),
                0
            ),
            1
        )
        return bounds.lowerBound + progress * span
    }

    private func clampedLowerValue(_ value: Double) -> Double {
        snapped(
            min(
                max(value, bounds.lowerBound),
                upperValue - minimumDistance
            )
        )
    }

    private func clampedUpperValue(_ value: Double) -> Double {
        snapped(
            max(
                min(value, bounds.upperBound),
                lowerValue + minimumDistance
            )
        )
    }

    private func snapped(_ value: Double) -> Double {
        min(
            max(value.rounded(), bounds.lowerBound),
            bounds.upperBound
        )
    }

    private func accessibilityTitle(for value: Double) -> String {
        let index = min(
            max(Int(value.rounded()), 0),
            labels.count - 1
        )
        return labels[index]
    }
}
