import SwiftUI
import QuickLook
import UniformTypeIdentifiers

struct StorageUsageView: View {
    @State private var tree: LibraryStorageNode?
    @State private var folderPath = ""
    @State private var selectedFile: LibraryStorageNode?
    @State private var isLoading = false
    @State private var visibleLimit = 100
    @State private var errorMessage: String?
    @State private var integrityReport: LibraryIntegrityReport?
    @State private var issueHistory: [LocalFileIssue] = []
    private let scanner = LibraryStorageScanner()

    private var current: LibraryStorageNode? {
        guard let tree else { return nil }
        func find(_ node: LibraryStorageNode) -> LibraryStorageNode? {
            if node.relativePath == folderPath { return node }
            for child in node.children where folderPath.hasPrefix(child.relativePath + "/") || folderPath == child.relativePath {
                if let found = find(child) { return found }
            }
            return nil
        }
        return find(tree) ?? tree
    }

    private var mapNodes: [LibraryStorageNode] {
        let nodes = current?.children ?? []
        if nodes.count <= 120 { return nodes }
        let rest = Array(nodes.dropFirst(119))
        return Array(nodes.prefix(119)) + [LibraryStorageNode(
            relativePath: "__other__", name: L10n.format("其余 %lld 个文件", rest.count),
            bytes: rest.reduce(0) { $0 + $1.bytes }, children: rest
        )]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let current {
                    HStack {
                        if !folderPath.isEmpty {
                            Button {
                                folderPath = (folderPath as NSString).deletingLastPathComponent
                                visibleLimit = 100
                            } label: { Image(systemName: "arrow.up") }
                        }
                        Text(folderPath.isEmpty ? "Library" : folderPath).font(.caption).lineLimit(2)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: current.bytes, countStyle: .file))
                            .monospacedDigit()
                    }
                    GeometryReader { geometry in
                        let tiles = LibraryTreemapLayout.tiles(mapNodes, in: CGRect(origin: .zero, size: geometry.size))
                        ZStack(alignment: .topLeading) {
                            ForEach(tiles) { tile in
                                Button { open(tile.node) } label: {
                                    ZStack {
                                        tileColor(tile.node).opacity(0.85)
                                        if tile.rect.width > 55, tile.rect.height > 34 {
                                            VStack(spacing: 2) {
                                                Text(tile.node.name).lineLimit(2)
                                                Text(ByteCountFormatter.string(fromByteCount: tile.node.bytes, countStyle: .file))
                                                    .lineLimit(1)
                                            }.font(.caption2).foregroundStyle(.white).padding(4)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .frame(width: max(0, tile.rect.width - 2), height: max(0, tile.rect.height - 2))
                                .position(x: tile.rect.midX, y: tile.rect.midY)
                                .accessibilityLabel(tile.node.name)
                            }
                        }
                    }.frame(height: 320).clipped()
                    Text("方块面积按文件字节数分配；点击文件夹可下钻。保存或删除后更新，也可手动刷新。")
                        .font(.caption).foregroundStyle(.secondary)
                    if current.children.count > 120 {
                        Text("为保持图表清晰，较小文件合并显示，不代表未知或异常文件。完整文件仍列在下方。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let integrityReport {
                        NavigationLink {
                            LibraryUntrackedFilesView(files: integrityReport.untrackedFiles)
                        } label: {
                            Label(L10n.format("未关联媒体（%lld）", integrityReport.untrackedFiles.count), systemImage: "questionmark.folder")
                        }
                        NavigationLink {
                            LibraryFileIssuesView(currentIssues: integrityReport.issues,
                                history: issueHistory, warnings: integrityReport.metadataWarnings)
                        } label: {
                            Label(L10n.format("文件检查记录（%lld）", max(issueHistory.count, integrityReport.issues.count) + integrityReport.metadataWarnings.count), systemImage: "exclamationmark.triangle")
                        }
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(Array(current.children.prefix(visibleLimit))) { node in
                            Button { open(node) } label: {
                                HStack {
                                    Image(systemName: node.isFolder ? "folder" : "doc")
                                    Text(node.name).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: node.bytes, countStyle: .file))
                                        .foregroundStyle(.secondary).monospacedDigit()
                                }.font(.subheadline).padding(.vertical, 10)
                            }.buttonStyle(.plain)
                            Divider()
                        }
                        if current.children.count > visibleLimit {
                            Button("再显示 100 条") { visibleLimit += 100 }.padding()
                        }
                    }
                } else if isLoading {
                    ProgressView()
                }
                if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
            }.padding()
        }
        .navigationTitle("Folder 空间分布")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isLoading { ProgressView() }
                else { Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") } }
            }
        }
        .task { await refresh() }
        .refreshable { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .localMediaLibraryChanged).receive(on: RunLoop.main)) { _ in
            Task { await refresh() }
        }
        .sheet(item: $selectedFile) { node in
            LibraryFileInformationView(node: node)
        }
    }

    private func open(_ node: LibraryStorageNode) {
        if node.relativePath == "__other__" { visibleLimit = current?.children.count ?? 100; return }
        if node.isFolder { folderPath = node.relativePath; visibleLimit = 100 }
        else { selectedFile = node }
    }

    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await scanner.scan()
            tree = result
            integrityReport = try await scanner.inspect(tree: result)
            issueHistory = await LocalFileIssueLog.shared.records()
            errorMessage = nil
        }
        catch { errorMessage = error.localizedDescription }
    }

    private func tileColor(_ node: LibraryStorageNode) -> Color {
        let colors: [Color] = [.blue, .indigo, .purple, .teal, .orange, .pink]
        let index = node.relativePath.utf8.reduce(0) { ($0 + Int($1)) % colors.count }
        return colors[index]
    }
}

private struct LibraryUntrackedFilesView: View {
    let files: [LibraryStorageNode]
    @State private var selectedFile: LibraryStorageNode?
    @State private var visibleLimit = 100
    var body: some View {
        List {
            Section {
                Text("这些媒体文件未能关联到 posts.jsonl 中的 Post。仅供检查，不会自动删除或猜测归属。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(files.prefix(visibleLimit))) { file in
                Button { selectedFile = file } label: {
                    HStack {
                        Text(file.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file)).foregroundStyle(.secondary)
                    }
                }
            }
            if files.count > visibleLimit { Button("再显示 100 条") { visibleLimit += 100 } }
        }
        .navigationTitle("未关联媒体").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedFile) { LibraryFileInformationView(node: $0) }
    }
}

private struct LibraryFileIssuesView: View {
    let currentIssues: [LocalFileIssue]
    let history: [LocalFileIssue]
    let warnings: [String]
    var body: some View {
        List {
            Section {
                Text("缺失或异常文件只会更新本地可用状态，不会自动删除 Post、索引或保存清单。记录不等于文件已永久失效。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("本次检查") {
                ForEach(currentIssues) { issue in issueRow(issue) }
                ForEach(Array(warnings.enumerated()), id: \.offset) { warning in
                    Text(L10n.format("无法解析清单记录：%@", warning.element)).font(.caption).foregroundStyle(.orange)
                }
                if currentIssues.isEmpty, warnings.isEmpty { Text("未发现文件问题") }
            }
            Section("最近记录（最多 200 条）") {
                ForEach(history) { issue in issueRow(issue) }
            }
        }
        .navigationTitle("文件检查记录").navigationBarTitleDisplayMode(.inline)
    }

    private func issueRow(_ issue: LocalFileIssue) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(issue.path).font(.caption).textSelection(.enabled)
            Text(issue.reason == "missing" || issue.reason == "missing_during_delete" ? "文件不存在" : "文件为空或无法读取")
                .font(.caption).foregroundStyle(.orange)
            Text(issue.observedAt, style: .date).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct LibraryFileInformationView: View {
    let node: LibraryStorageNode
    @Environment(\.dismiss) private var dismiss
    @State private var showsFileBrowser = false
    @State private var previewFile: LibraryPresentedFile?
    @State private var sharedFile: LibraryPresentedFile?
    @State private var errorMessage: String?
    @State private var resultMessage: String?
    @State private var isSaving = false

    private var fileURL: URL? {
        LibraryFilePaths.fileURL(for: node.relativePath, root: StorageManager.appDocumentsLibraryURL)
    }

    var body: some View {
        NavigationStack {
            List {
                Text(node.name)
                Text(ByteCountFormatter.string(fromByteCount: node.bytes, countStyle: .file))
                Text(node.relativePath).font(.caption).textSelection(.enabled)
                if let fileURL {
                    Button {
                        Task {
                            if await LocalMediaLibrary.shared.validateFile(at: fileURL) {
                                errorMessage = nil
                                previewFile = LibraryPresentedFile(url: fileURL)
                            } else { errorMessage = L10n.string("文件不存在或无法读取；本地保存状态已更新。") }
                        }
                    } label: { Label("打开文件", systemImage: "doc.viewfinder") }
                    Button { showsFileBrowser = true } label: {
                        Label("浏览所在文件夹", systemImage: "folder")
                    }
                    Button {
                        Task {
                            if await LocalMediaLibrary.shared.validateFile(at: fileURL) {
                                errorMessage = nil
                                sharedFile = LibraryPresentedFile(url: fileURL)
                            } else { errorMessage = L10n.string("文件不存在或无法读取；本地保存状态已更新。") }
                        }
                    } label: { Label("共享文件", systemImage: "square.and.arrow.up") }
                    if let type = UTType(filenameExtension: fileURL.pathExtension), type.conforms(to: .image) || type.conforms(to: .movie) {
                        Button {
                            Task { await saveToPhotos(fileURL, image: type.conforms(to: .image)) }
                        } label: {
                            if isSaving { ProgressView() }
                            else { Label("保存到照片", systemImage: "photo.badge.arrow.down") }
                        }.disabled(isSaving)
                    }
                    DisclosureGroup("实际文件路径") {
                        Text(fileURL.path).font(.caption2).textSelection(.enabled)
                    }
                }
                if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.orange) }
                if let resultMessage { Text(resultMessage).font(.caption).foregroundStyle(.secondary) }
            }
            .navigationTitle("文件信息").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .sheet(item: $previewFile) { file in
            LibraryQuickLookSheet(url: file.url)
        }
        .sheet(item: $sharedFile) { file in
            LibraryFileShareSheet(url: file.url) { savedToPhotos, error in
                if let error { errorMessage = error.localizedDescription }
                else if savedToPhotos { resultMessage = L10n.string("已保存到照片。") }
            }
        }
        .sheet(isPresented: $showsFileBrowser, onDismiss: {
            if let fileURL { Task { _ = await LocalMediaLibrary.shared.validateFile(at: fileURL) } }
        }) {
            if let fileURL {
                NavigationStack {
                    LibraryFolderContentsView(root: StorageManager.appDocumentsLibraryURL,
                        directory: fileURL.deletingLastPathComponent())
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showsFileBrowser = false } } }
                }
            }
        }
    }

    private func saveToPhotos(_ url: URL, image: Bool) async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        resultMessage = nil
        defer { isSaving = false }
        do {
            guard await LocalMediaLibrary.shared.validateFile(at: url) else {
                throw AppError.saveFailed(L10n.string("文件不存在或无法读取；本地保存状态已更新。"))
            }
            let saver = PhotoLibrarySaver()
            try await saver.requestAddPermission()
            if image { try await saver.saveImage(at: url) }
            else { try await saver.saveVideo(at: url) }
            resultMessage = L10n.string("已保存到照片。")
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct LibraryPresentedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct LibraryQuickLookSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            LibraryQuickLookView(url: url)
                .navigationTitle(url.lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

private struct LibraryQuickLookView: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

private struct LibraryFileShareSheet: UIViewControllerRepresentable {
    let url: URL
    let completion: (Bool, Error?) -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        // Supply the local file itself, not a generic URL Transferable/link.
        let controller = UIActivityViewController(activityItems: [url as NSURL], applicationActivities: nil)
        controller.completionWithItemsHandler = { activity, completed, _, error in
            Task { @MainActor in completion(completed && activity == .saveToCameraRoll, error) }
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct LibraryFolderFile: Identifiable {
    let url: URL
    let isDirectory: Bool
    let bytes: Int64
    var id: URL { url }
}

actor LibraryFolderReader {
    func contents(of directory: URL, root: URL) throws -> [LibraryFolderFile] {
        guard LibraryFilePaths.relativePath(of: directory, under: root, resolvingSymlinks: true) != nil else {
            throw CocoaError(.fileReadNoPermission)
        }
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        var files: [LibraryFolderFile] = []
        for url in urls {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { continue }
            files.append(LibraryFolderFile(url: url, isDirectory: values.isDirectory == true, bytes: Int64(values.fileSize ?? 0)))
        }
        files.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        return files
    }
}

private struct LibraryFolderContentsView: View {
    let root: URL
    let directory: URL
    @State private var files: [LibraryFolderFile] = []
    @State private var visibleLimit = 100
    @State private var previewFile: LibraryPresentedFile?
    @State private var errorMessage: String?
    @State private var isLoading = false
    private let reader = LibraryFolderReader()

    var body: some View {
        List {
            Section {
                Text(directory.path).font(.caption2).textSelection(.enabled)
            } footer: { Text("直接浏览 App 保存目录中的实际文件，不是系统“最近项目”。") }
            ForEach(Array(files.prefix(visibleLimit))) { file in
                if file.isDirectory {
                    NavigationLink {
                        LibraryFolderContentsView(root: root, directory: file.url)
                    } label: { fileRow(file) }
                } else {
                    Button {
                        Task {
                            if await LocalMediaLibrary.shared.validateFile(at: file.url) {
                                previewFile = LibraryPresentedFile(url: file.url)
                            } else { errorMessage = L10n.string("文件不存在或无法读取；本地保存状态已更新。") }
                        }
                    } label: { fileRow(file) }
                    .buttonStyle(.plain)
                }
            }
            if files.count > visibleLimit { Button("再显示 100 条") { visibleLimit += 100 } }
            if isLoading { ProgressView() }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.orange) }
        }
        .navigationTitle(directory.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: directory) { await reload() }
        .refreshable { await reload() }
        .sheet(item: $previewFile) { LibraryQuickLookSheet(url: $0.url) }
    }

    private func fileRow(_ file: LibraryFolderFile) -> some View {
        HStack {
            Image(systemName: file.isDirectory ? "folder" : "doc")
            Text(file.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            Spacer()
            if !file.isDirectory { Text(ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do { files = try await reader.contents(of: directory, root: root); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
}
