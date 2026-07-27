import SwiftUI
import UIKit

struct SingleDownloadView: View {
    @ObservedObject var session: BrowserSessionModel
    @StateObject private var viewModel = SaverViewModel()
    @Environment(\.openURL) private var openURL
    @FocusState private var isURLFieldFocused: Bool

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
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("X Media Saver")
            .toolbar {
                if viewModel.post != nil || !viewModel.postURL.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("清空") {
                            isURLFieldFocused = false
                            viewModel.clear()
                        }
                        .disabled(
                            viewModel.isDownloading
                                || viewModel.isSavingPhotos
                        )
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        isURLFieldFocused = false
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

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.to.line.compact")
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(.cyan, .purple)
                .symbolRenderingMode(.palette)
            Text("单链接保存帖子媒体")
                .font(.title2.bold())
            Text("登录一次后，粘贴链接即可解析帖子中的图片、视频或动图，并选择需要保存的媒体。")
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
            .focused($isURLFieldFocused)
            .submitLabel(.done)
            .onSubmit {
                isURLFieldFocused = false
            }

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
                    isURLFieldFocused = false
                    Task {
                        await viewModel.resolve(
                            browserResolver: { postID in
                                let url = try PostURLParser.postURL(
                                    from: viewModel.postURL
                                )
                                return try await session.capturePost(
                                    withID: postID,
                                    from: url
                                )
                            }
                        )
                    }
                } label: {
                    if viewModel.isResolving {
                        ProgressView()
                    } else {
                        Label("查找帖子", systemImage: "magnifyingglass")
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

            if !post.photos.isEmpty {
                photoSection(post.photos)
            }

            if !post.items.isEmpty {
                Divider()
                videoSection(post)
            }

            if let success = viewModel.successMessage {
                Label(success, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline.weight(.semibold))
            }
        }
        .saverCard()
    }

    private func photoSection(
        _ photos: [BookmarkedMedia]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("图片", systemImage: "photo.on.rectangle.angled")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(photos.count) 张 · 原始画质")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 6),
                    count: min(photos.count, 2)
                ),
                spacing: 6
            ) {
                ForEach(photos) { photo in
                    LocalMediaThumbnailView(
                        media: photo,
                        maximumPixelSize: 640,
                        remoteImageName: "large"
                    )
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }

            if viewModel.isSavingPhotos {
                ProgressView(
                    value: Double(viewModel.photoSaveProgress.completed)
                        + viewModel.photoSaveProgress.currentFraction,
                    total: Double(max(viewModel.photoSaveProgress.total, 1))
                )
                HStack {
                    Text(
                        "\(viewModel.photoSaveProgress.completed)/\(viewModel.photoSaveProgress.total)"
                    )
                    .font(.caption.monospacedDigit())
                    Spacer()
                    Button("取消", role: .cancel) {
                        viewModel.cancelPhotoSave()
                    }
                }
            } else {
                Button {
                    Task { await viewModel.saveAllPhotos() }
                } label: {
                    Label(
                        "保存全部 \(photos.count) 张图片到照片",
                        systemImage: "photo.badge.arrow.down"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func videoSection(_ post: PostMedia) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("视频与动图", systemImage: "play.rectangle")
                .font(.subheadline.weight(.semibold))

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

        }
    }

    private var sessionNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("浏览器会话", systemImage: "person.crop.circle.badge.checkmark")
                .font(.subheadline.weight(.semibold))
            Text(
                "只需在“X 浏览器”中登录一次。登录有效期内，粘贴链接后会自动使用同一个 WebKit 会话打开并解析帖子，无需先手动浏览该帖子。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}
