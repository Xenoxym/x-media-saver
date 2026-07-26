import SwiftUI
import UIKit

struct BookmarksView: View {
    @ObservedObject var session: BrowserSessionModel
    @ObservedObject var viewModel: BookmarksViewModel
    @Environment(\.openURL) private var openURL

    private var statistics: BookmarkStatistics {
        BookmarkStatistics.calculate(from: session.capturedPosts)
    }

    private var filteredPosts: [BookmarkedPost] {
        viewModel.filteredPosts(from: session.capturedPosts)
    }

    private var selectedMediaCount: Int {
        viewModel.selectedMedia(from: session.capturedPosts).count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if session.capturedPosts.isEmpty {
                        emptyState
                    } else {
                        statisticsCard
                        filterCard
                        saveCard
                        postsCard
                    }
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("书签媒体")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if session.isAutoCapturing {
                        Button("停止") {
                            session.stopAutoCapture()
                        }
                    } else {
                        Button {
                            session.startAutoCapture()
                        } label: {
                            Label("同步", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                }
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
            Text(
                "首次使用请到“X 浏览器”登录。之后可直接在这里点击“同步书签”，APP 会自动打开书签页并滚动抓取。"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            if session.isAutoCapturing {
                ProgressView("正在自动同步书签…")
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

            if let error = session.captureError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .saverCard()
    }

    private var statisticsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("本次浏览器会话统计", systemImage: "chart.bar.xaxis")
                .font(.headline)

            LazyVGrid(
                columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ],
                spacing: 10
            ) {
                stat("已捕获书签", statistics.bookmarkCount, "bookmark")
                stat("含媒体帖子", statistics.bookmarksWithMedia, "paperclip")
                stat("图片", statistics.photoCount, "photo")
                stat("动图", statistics.gifCount, "sparkles.tv")
                stat("视频", statistics.videoCount, "video")
            }

            Text("统计范围是当前内置浏览器已经滚动并加载到的书签，不代表 X 服务端未加载的总量。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if session.isAutoCapturing {
                ProgressView("正在自动同步，已捕获 \(session.capturedPosts.count) 条…")
            } else if let error = session.captureError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
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

    private var filterCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("下载筛选", systemImage: "line.3.horizontal.decrease.circle")
                .font(.headline)

            Toggle("图片", isOn: $viewModel.filter.includePhotos)
            Toggle("动图（X 以 MP4 变体提供）", isOn: $viewModel.filter.includeGIFs)
            Toggle("视频", isOn: $viewModel.filter.includeVideos)

            Divider()

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

            Text("日期按帖子的发布时间筛选；X 页面响应不提供“加入书签的时间”。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .saverCard()
    }

    private var saveCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("准备保存", systemImage: "photo.stack")
                    .font(.headline)
                Spacer()
                Text("\(selectedMediaCount) 项")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if viewModel.isSaving {
                let total = max(viewModel.progress.total, 1)
                let overall = (
                    Double(viewModel.progress.completed)
                    + viewModel.progress.currentFraction
                ) / Double(total)
                ProgressView(value: min(overall, 1))
                HStack {
                    Text(
                        "\(viewModel.progress.completed)/\(viewModel.progress.total)"
                    )
                    .font(.caption.monospacedDigit())
                    Spacer()
                    Button("取消", role: .cancel) {
                        viewModel.cancelSaving()
                    }
                }
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
                .controlSize(.large)
                .disabled(selectedMediaCount == 0)
            }

            if let result = viewModel.result {
                Label(
                    "完成：保存 \(result.saved)，跳过 \(result.skipped)，失败 \(result.failed)",
                    systemImage: result.failed == 0
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(
                    result.failed == 0 ? Color.green : Color.orange
                )

                ForEach(
                    Array(result.issues.prefix(3).enumerated()),
                    id: \.offset
                ) { _, issue in
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if result.issues.count > 3 {
                    Text("另有 \(result.issues.count - 3) 项问题。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .saverCard()
    }

    private var postsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("筛选结果（\(filteredPosts.count) 条帖子）")
                .font(.headline)

            ForEach(filteredPosts.prefix(50)) { post in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(
                            post.authorUsername.map { "@\($0)" }
                                ?? post.authorName
                                ?? "未知作者"
                        )
                        .font(.subheadline.weight(.semibold))
                        Spacer()
                        if let date = post.createdAt {
                            Text(date, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !post.text.isEmpty {
                        Text(post.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
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
                            .font(.caption)
                        }
                    }
                }
                if post.id != filteredPosts.prefix(50).last?.id {
                    Divider()
                }
            }

            if filteredPosts.count > 50 {
                Text("列表只预览前 50 条；批量保存仍会处理全部筛选结果。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .saverCard()
    }
}
