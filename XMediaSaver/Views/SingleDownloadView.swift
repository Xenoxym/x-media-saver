import SwiftUI
import UIKit

struct SingleDownloadView: View {
    @ObservedObject var session: BrowserSessionModel
    @StateObject private var viewModel = SaverViewModel()
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    urlCard
                    if viewModel.isResolving {
                        ProgressView("正在查找媒体…")
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    if let post = viewModel.post {
                        resultCard(post)
                    }
                    sessionNote
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("X Media Saver")
            .toolbar {
                if viewModel.post != nil || !viewModel.postURL.isEmpty {
                    Button("清空") {
                        viewModel.clear()
                    }
                    .disabled(viewModel.isDownloading)
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

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.to.line.compact")
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(.cyan, .purple)
                .symbolRenderingMode(.palette)
            Text("单链接保存视频与动图")
                .font(.title2.bold())
            Text("保留原有快捷下载；如果帖子已在内置浏览器中加载，会优先使用该浏览器会话捕获到的媒体。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 8)
    }

    private var urlCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("帖子地址")
                .font(.headline)

            TextField(
                "https://x.com/account/status/…",
                text: $viewModel.postURL,
                axis: .vertical
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .lineLimit(2...4)
            .textFieldStyle(.roundedBorder)

            HStack {
                Button {
                    if let value = UIPasteboard.general.string {
                        viewModel.postURL = value
                    }
                } label: {
                    Label("粘贴", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button {
                    Task {
                        let postID = try? PostURLParser.postID(
                            from: viewModel.postURL
                        )
                        await viewModel.resolve(
                            browserPost: postID.flatMap {
                                session.post(withID: $0)
                            }
                        )
                    }
                } label: {
                    if viewModel.isResolving {
                        ProgressView()
                    } else {
                        Label("查找视频", systemImage: "magnifyingglass")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canResolve)
            }
        }
        .saverCard()
    }

    private func resultCard(_ post: PostMedia) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("已找到媒体", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)

            if let name = post.authorName {
                Text(
                    post.authorHandle.map { "\(name)  @\($0)" } ?? name
                )
                .font(.subheadline.weight(.semibold))
            }
            if let text = post.text, !text.isEmpty {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if post.items.count > 1 {
                Picker(
                    "媒体",
                    selection: Binding(
                        get: { viewModel.selectedItemID },
                        set: { viewModel.selectItem($0) }
                    )
                ) {
                    ForEach(Array(post.items.enumerated()), id: \.element.id) {
                        index, item in
                        Text("\(item.kind.displayName) \(index + 1)")
                            .tag(Optional(item.id))
                    }
                }
                .pickerStyle(.segmented)
            }

            if let item = viewModel.selectedItem {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("MP4 质量")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("默认最高质量")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("质量", selection: $viewModel.selectedVariantID) {
                        ForEach(item.variants) { variant in
                            Text(variant.qualityLabel)
                                .tag(Optional(variant.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if viewModel.isDownloading {
                VStack(spacing: 10) {
                    ProgressView(value: viewModel.downloadProgress)
                    HStack {
                        Text(
                            viewModel.downloadProgress > 0
                                ? "\(Int(viewModel.downloadProgress * 100))%"
                                : "正在开始下载…"
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        Spacer()
                        Button("取消", role: .cancel) {
                            viewModel.cancelDownload()
                        }
                    }
                }
            } else {
                Button {
                    Task { await viewModel.downloadAndSave() }
                } label: {
                    Label(
                        "下载并保存到照片",
                        systemImage: "photo.badge.arrow.down"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            if let success = viewModel.successMessage {
                Label(success, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline.weight(.semibold))
            }
        }
        .saverCard()
    }

    private var sessionNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("浏览器会话", systemImage: "person.crop.circle.badge.checkmark")
                .font(.subheadline.weight(.semibold))
            Text(
                "遇到登录后才能看到的帖子时，先在“X 浏览器”中正常登录并打开该帖子，再回到这里重试。APP 不使用 OAuth，也不读取或导出 Cookie。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}
