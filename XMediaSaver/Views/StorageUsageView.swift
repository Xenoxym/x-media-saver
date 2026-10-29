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
    @State private var showsPreview = false
    @State private var showsFileBrowser = false
    @State private var previewURL: URL?
    @State private var errorMessage: String?

    private var fileURL: URL? {
        let root = StorageManager.appDocumentsLibraryURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(node.relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        return candidate
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
                                previewURL = fileURL; showsPreview = true
                            } else { errorMessage = L10n.string("文件不存在或无法读取；本地保存状态已更新。") }
                        }
                    } label: { Label("打开文件", systemImage: "doc.viewfinder") }
                    Button { showsFileBrowser = true } label: {
                        Label("浏览所在文件夹", systemImage: "folder")
                    }
                    ShareLink(item: fileURL) { Label("共享文件", systemImage: "square.and.arrow.up") }
                }
                if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.orange) }
            }
            .navigationTitle("文件信息").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .sheet(isPresented: $showsPreview) {
            if let previewURL { LibraryQuickLookView(url: previewURL).ignoresSafeArea() }
        }
        .sheet(isPresented: $showsFileBrowser, onDismiss: {
            if let fileURL { Task { _ = await LocalMediaLibrary.shared.validateFile(at: fileURL) } }
        }) {
            if let fileURL {
                LibraryFolderBrowser(directory: fileURL.deletingLastPathComponent())
            }
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

private struct LibraryFolderBrowser: UIViewControllerRepresentable {
    let directory: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        picker.directoryURL = directory
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}
