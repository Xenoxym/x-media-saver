import Combine
import Foundation

extension Notification.Name {
    static let localMediaLibraryChanged = Notification.Name("XMediaSaver.LocalMediaLibraryChanged")
}

enum FolderPathSafety {
    static func mediaURL(_ relativePath: String, root: URL) -> URL? {
        guard let mediaFolder = ["Images/", "Animated GIFs/", "Videos/"].first(where: relativePath.hasPrefix) else { return nil }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = base.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        let mediaBase = base.appendingPathComponent(mediaFolder).standardizedFileURL.resolvingSymlinksInPath()
        let mediaPrefix = mediaBase.path.hasSuffix("/") ? mediaBase.path : mediaBase.path + "/"
        guard mediaBase.path.hasPrefix(prefix), candidate.path.hasPrefix(mediaPrefix),
              (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        else { return nil }
        return candidate
    }
}

actor LocalMediaLibrary {
    static let shared = LocalMediaLibrary()

    private var localURLsByMediaKey: [String: URL] = [:]
    private var roots: [URL]
    private var hasLoaded = false

    init(roots: [URL]? = nil) {
        self.roots = roots ?? [StorageManager.appDocumentsLibraryURL]
    }

    func reload() {
        localURLsByMediaKey = [:]
        for root in roots {
            loadState(from: root)
        }
        hasLoaded = true
    }

    func register(root: URL) {
        if !roots.contains(root) {
            roots.append(root)
            _ = root.startAccessingSecurityScopedResource()
        }
        loadState(from: root)
        hasLoaded = true
        NotificationCenter.default.post(name: .localMediaLibraryChanged, object: nil)
    }

    func localURL(for mediaKey: String) -> URL? {
        if !hasLoaded {
            reload()
        }
        guard let url = localURLsByMediaKey[mediaKey],
              FileManager.default.fileExists(atPath: url.path)
        else {
            localURLsByMediaKey.removeValue(forKey: mediaKey)
            return nil
        }
        return url
    }

    func availableMediaKeys() -> Set<String> {
        if !hasLoaded {
            reload()
        }
        localURLsByMediaKey = localURLsByMediaKey.filter {
            FileManager.default.fileExists(atPath: $0.value.path)
        }
        return Set(localURLsByMediaKey.keys)
    }

    func availableFiles() -> [String: URL] {
        _ = availableMediaKeys()
        return localURLsByMediaKey
    }

    private func loadState(from root: URL) {
        let stateURL = root.appendingPathComponent("export-state.jsonl")
        guard let data = try? Data(contentsOf: stateURL) else { return }
        let records: [LocalExportStateRecord]
        if let single = try? JSONDecoder().decode(LocalExportStateRecord.self, from: data) {
            records = [single]
        } else if let legacy = try? JSONDecoder().decode([String: String].self, from: data) {
            records = legacy.map { LocalExportStateRecord(mediaKey: $0.key, relativePath: $0.value) }
        } else {
            records = data.split(separator: 0x0A).compactMap {
                try? JSONDecoder().decode(LocalExportStateRecord.self, from: Data($0))
            }
        }
        for record in records {
            guard let url = FolderPathSafety.mediaURL(record.relativePath, root: root) else { continue }
            if FileManager.default.fileExists(atPath: url.path) {
                localURLsByMediaKey[record.mediaKey] = url
            } else {
                localURLsByMediaKey.removeValue(forKey: record.mediaKey)
            }
        }
    }
}

private struct LocalExportStateRecord: Codable {
    let mediaKey: String
    let relativePath: String
}

actor LocalFolderLibrary {
    private let root: URL

    init(root: URL = StorageManager.appDocumentsLibraryURL) {
        self.root = root
    }

    func loadPosts() throws -> [BookmarkedPost] {
        let state = try loadExportState()
        return try loadPostRecords().map { record in
            let availableMedia = record.media.filter { item in
                guard let relativePath = state[item.mediaKey],
                      let fileURL = safeFileURL(for: relativePath)
                else {
                    return false
                }
                return FileManager.default.fileExists(atPath: fileURL.path)
            }
            return Self.bookmarkedPost(
                from: ExportedPostRecord(
                    id: record.id,
                    postURL: record.postURL,
                    text: record.text,
                    createdAt: record.createdAt,
                    authorID: record.authorID,
                    authorName: record.authorName,
                    authorUsername: record.authorUsername,
                    media: availableMedia
                )
            )
        }
    }

    func loadUnavailablePosts() async throws -> [SaveFailureRecord] {
        try await unavailableStore.reload()
    }

    func deleteMedia(withKeys keys: Set<String>) throws {
        guard !keys.isEmpty else { return }
        var state = try loadExportState()
        guard !keys.isDisjoint(with: Set(state.keys)) else { return }
        let records = try loadPostRecords().map { record in
            ExportedPostRecord(
                id: record.id,
                postURL: record.postURL,
                text: record.text,
                createdAt: record.createdAt,
                authorID: record.authorID,
                authorName: record.authorName,
                authorUsername: record.authorUsername,
                media: record.media.filter { !keys.contains($0.mediaKey) }
            )
        }

        let pathsToRemove = Set(keys.compactMap { state[$0] })
        for key in keys { state.removeValue(forKey: key) }
        // Distinct media keys can point at one physical file. Never break a
        // retained reference when deleting one media or one Post.
        let retainedPaths = Set(state.values)
        for path in pathsToRemove.subtracting(retainedPaths) {
            if let fileURL = safeFileURL(for: path), FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        }
        try rewriteExportState(state)
        try rewritePostRecords(records)
    }

    func deletePosts(withIDs ids: Set<String>) async throws {
        guard !ids.isEmpty else { return }
        var state = try loadExportState()
        let records = try loadPostRecords()
        let unavailable = try await unavailableStore.reload()
        let removedMediaKeys = Set(
            records.filter { ids.contains($0.id) }
                .flatMap(\.media)
                .map(\.mediaKey)
            + unavailable.filter { ids.contains($0.id) }
                .flatMap(\.post.media)
                .map(\.mediaKey)
        )
        let remainingRecords = records.filter { !ids.contains($0.id) }
        let remainingUnavailable = unavailable.filter {
            !ids.contains($0.id)
        }
        let retainedMediaKeys = Set(
            remainingRecords.flatMap(\.media).map(\.mediaKey)
            + remainingUnavailable.flatMap(\.post.media).map(\.mediaKey)
        )

        let keysToRemove = removedMediaKeys.subtracting(retainedMediaKeys)
        let pathsToRemove = Set(keysToRemove.compactMap { state[$0] })
        for key in keysToRemove { state.removeValue(forKey: key) }
        let retainedPaths = Set(state.values)
        for path in pathsToRemove.subtracting(retainedPaths) {
            if let fileURL = safeFileURL(for: path), FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        }
        try rewriteExportState(state)
        try rewritePostRecords(remainingRecords)
        _ = try await unavailableStore.removePosts(withIDs: ids)
    }

    private var postManifestURL: URL {
        root.appendingPathComponent("posts.jsonl")
    }

    private var exportStateURL: URL {
        root.appendingPathComponent("export-state.jsonl")
    }

    private var unavailableStore: MediaSaveFailureStore {
        MediaSaveFailureStore(
            fileURL: root.appendingPathComponent("unavailable-posts.json")
        )
    }

    private func loadPostRecords() throws -> [ExportedPostRecord] {
        guard FileManager.default.fileExists(atPath: postManifestURL.path)
        else { return [] }
        let data = try Data(contentsOf: postManifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap {
            try? decoder.decode(ExportedPostRecord.self, from: Data($0))
        }
    }

    private func loadExportState() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: exportStateURL.path)
        else { return [:] }
        let data = try Data(contentsOf: exportStateURL)
        if let single = try? JSONDecoder().decode(ExportStateRecord.self, from: data) {
            return [single.mediaKey: single.relativePath]
        }
        if let legacy = try? JSONDecoder().decode([String: String].self, from: data) { return legacy }
        var result: [String: String] = [:]
        for line in data.split(separator: 0x0A) {
            if let record = try? JSONDecoder().decode(
                ExportStateRecord.self,
                from: Data(line)
            ) {
                result[record.mediaKey] = record.relativePath
            }
        }
        return result
    }

    private func rewriteExportState(_ state: [String: String]) throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        var data = Data()
        for (key, path) in state.sorted(by: { $0.key < $1.key }) {
            data.append(
                try JSONEncoder().encode(
                    ExportStateRecord(mediaKey: key, relativePath: path)
                )
            )
            data.append(0x0A)
        }
        try data.write(to: exportStateURL, options: .atomic)
    }

    private func rewritePostRecords(
        _ records: [ExportedPostRecord]
    ) throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        try data.write(to: postManifestURL, options: .atomic)
    }

    private func safeFileURL(for relativePath: String) -> URL? {
        FolderPathSafety.mediaURL(relativePath, root: root)
    }

    private static func bookmarkedPost(
        from record: ExportedPostRecord
    ) -> BookmarkedPost {
        BookmarkedPost(
            id: record.id,
            text: record.text,
            createdAt: record.createdAt,
            authorID: record.authorID,
            authorName: record.authorName,
            authorUsername: record.authorUsername,
            media: record.media.map { item in
                let variants: [XMediaVariant]
                if item.type == .photo || item.remoteURL == nil {
                    variants = []
                } else {
                    variants = [
                        XMediaVariant(
                            bitRate: nil,
                            contentType: "video/mp4",
                            url: item.remoteURL!
                        )
                    ]
                }
                return BookmarkedMedia(
                    mediaKey: item.mediaKey,
                    type: item.type,
                    url: item.type == .photo ? item.remoteURL : nil,
                    previewImageURL: nil,
                    variants: variants,
                    width: item.width,
                    height: item.height,
                    durationMilliseconds: item.durationMilliseconds,
                    byteSize: item.byteSize,
                    sizeProbeCompleted: true
                )
            }
        )
    }
}

@MainActor
final class LocalFolderLibraryModel: ObservableObject {
    @Published private(set) var posts: [BookmarkedPost] = []
    @Published private(set) var unavailablePosts: [SaveFailureRecord] = []
    @Published private(set) var isWorking = false
    @Published var presentedError: PresentedError?

    private let library = LocalFolderLibrary()

    func reload() {
        Task { [weak self] in
            guard let self else { return }
            do {
                posts = try await library.loadPosts()
                unavailablePosts = try await library.loadUnavailablePosts()
                await LocalMediaLibrary.shared.reload()
            } catch {
                show(error)
            }
        }
    }

    func deleteMedia(withKeys keys: Set<String>) async throws {
        isWorking = true
        defer { isWorking = false }
        try await library.deleteMedia(withKeys: keys)
        posts = try await library.loadPosts()
        unavailablePosts = try await library.loadUnavailablePosts()
        await LocalMediaLibrary.shared.reload()
        NotificationCenter.default.post(name: .localMediaLibraryChanged, object: nil)
    }

    func deletePosts(withIDs ids: Set<String>) async throws {
        isWorking = true
        defer { isWorking = false }
        try await library.deletePosts(withIDs: ids)
        posts = try await library.loadPosts()
        unavailablePosts = try await library.loadUnavailablePosts()
        await LocalMediaLibrary.shared.reload()
        NotificationCenter.default.post(name: .localMediaLibraryChanged, object: nil)
    }

    private func show(_ error: Error) {
        presentedError = PresentedError(
            message: error.localizedDescription,
            offersSettings: false
        )
    }
}
