import SwiftUI

struct StorageManagementView: View {
    @ObservedObject var session: BrowserSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: StorageSnapshot?
    @State private var isWorking = false
    @State private var confirmClearIndex = false
    @State private var confirmClearDownloads = false
    private let storageManager = StorageManager()

    var body: some View {
        NavigationStack {
            List {
                Section("存储占用") {
                    storageRow(
                        "Post 索引",
                        bytes: snapshot?.bookmarkIndexBytes,
                        icon: "doc.text.magnifyingglass"
                    )
                    storageRow(
                        "Files 下载资料库",
                        bytes: snapshot?.downloadLibraryBytes,
                        icon: "folder"
                    )
                    storageRow(
                        "遗留临时下载",
                        bytes: snapshot?.temporaryBytes,
                        icon: "clock.arrow.circlepath"
                    )
                    storageRow(
                        "URLSession 缓存",
                        bytes: snapshot?.urlCacheBytes,
                        icon: "network"
                    )
                    storageRow(
                        "WebKit 与其他私有数据",
                        bytes: snapshot?.privateLibraryBytes,
                        icon: "globe"
                    )
                }

                Section {
                    Button {
                        Task {
                            isWorking = true
                            await session.clearCachesKeepingLogin()
                            await refresh()
                            isWorking = false
                        }
                    } label: {
                        Label("清理缓存并保留 X 登录", systemImage: "trash")
                    }

                    Button {
                        confirmClearIndex = true
                    } label: {
                        Label(
                            "清空本地书签索引",
                            systemImage: "bookmark.slash"
                        )
                    }

                    Button {
                        confirmClearDownloads = true
                    } label: {
                        Label(
                            "清空 Files 下载资料库",
                            systemImage: "folder.badge.minus"
                        )
                    }

                } footer: {
                    Text(
                        "普通“清理缓存”不会删除 X Cookie、书签索引、照片图库资产或 Files 中的导出文件。WebKit 精确分类大小受 iOS 公共 API 限制，因此显示为合并估算。"
                    )
                }
            }
            .navigationTitle("存储管理")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button {
                            Task { await refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .task { await refresh() }
            .confirmationDialog(
                "清空本地书签索引？",
                isPresented: $confirmClearIndex
            ) {
                Button("清空索引", role: .destructive) {
                    session.clearCapturedData()
                    Task { await refresh() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("不会删除照片或 Files 导出，但需要重新同步才能恢复列表。")
            }
            .confirmationDialog(
                "删除 Files 下载资料库？",
                isPresented: $confirmClearDownloads
            ) {
                Button("删除下载资料库", role: .destructive) {
                    Task {
                        try? await storageManager.clearDownloadLibrary()
                        await refresh()
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这会删除 Images、Animated GIFs、Videos、posts.jsonl 和导出状态。")
            }
        }
    }

    private func storageRow(
        _ title: String,
        bytes: Int64?,
        icon: String
    ) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if let bytes {
                Text(Self.byteFormatter.string(fromByteCount: bytes))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                ProgressView()
            }
        }
    }

    private func refresh() async {
        snapshot = await storageManager.snapshot()
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()
}
