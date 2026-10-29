import SwiftUI

struct StorageUsageView: View {
    @State private var tree: LibraryStorageNode?
    @State private var folderPath = ""
    @State private var selectedFile: LibraryStorageNode?
    @State private var isLoading = false
    @State private var visibleLimit = 100
    @State private var errorMessage: String?
    @Environment(\.scenePhase) private var scenePhase
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
            relativePath: "__other__", name: L10n.string("其他文件"),
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
                    Text("方块面积按文件字节数分配；点击文件夹可下钻。保存或删除后、回到 App 时会更新，也可手动刷新。")
                        .font(.caption).foregroundStyle(.secondary)
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
        .onChange(of: scenePhase) { if $0 == .active { Task { await refresh() } } }
        .sheet(item: $selectedFile) { node in
            NavigationStack {
                List {
                    Text(node.name)
                    Text(ByteCountFormatter.string(fromByteCount: node.bytes, countStyle: .file))
                    Text(node.relativePath).font(.caption).textSelection(.enabled)
                }.navigationTitle("文件信息").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { selectedFile = nil } } }
            }.presentationDetents([.medium])
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
        do { tree = try await scanner.scan(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    private func tileColor(_ node: LibraryStorageNode) -> Color {
        let colors: [Color] = [.blue, .indigo, .purple, .teal, .orange, .pink]
        let index = node.relativePath.utf8.reduce(0) { ($0 + Int($1)) % colors.count }
        return colors[index]
    }
}
