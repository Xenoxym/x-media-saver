import Combine
import Foundation

extension Notification.Name {
    static let localMediaLibraryChanged = Notification.Name("XMediaSaver.LocalMediaLibraryChanged")
    static let localMediaAvailabilityChanged = Notification.Name("XMediaSaver.LocalMediaAvailabilityChanged")
}

@MainActor
final class LocalMediaAvailability: ObservableObject {
    static let shared = LocalMediaAvailability()
    @Published private(set) var keys: Set<String> = []

    func replace(with updated: Set<String>) {
        guard keys != updated else { return }
        keys = updated
        NotificationCenter.default.post(name: .localMediaAvailabilityChanged, object: nil)
    }
}

enum LibraryFilePaths {
    static func relativePath(of url: URL, under root: URL, resolvingSymlinks: Bool = false) -> String? {
        guard url.isFileURL, root.isFileURL else { return nil }
        func components(_ value: URL) -> [String] {
            let normalized = value.standardizedFileURL
            let resolved = resolvingSymlinks ? normalized.resolvingSymlinksInPath() : normalized
            return resolved.pathComponents.filter { !$0.isEmpty && $0 != "/" }
        }
        let base = components(root)
        let candidate = components(url)
        guard !base.isEmpty, candidate.starts(with: base) else { return nil }
        return candidate.dropFirst(base.count).joined(separator: "/")
    }

    static func fileURL(for relativePath: String, root: URL, resolvingSymlinks: Bool = true) -> URL? {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"), !relativePath.contains("\0"),
              !parts.contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) else { return nil }
        let base = resolvingSymlinks ? root.standardizedFileURL.resolvingSymlinksInPath() : root.standardizedFileURL
        let candidate = base.appendingPathComponent(relativePath).standardizedFileURL
        guard let path = self.relativePath(of: candidate, under: base, resolvingSymlinks: resolvingSymlinks),
              !path.isEmpty else { return nil }
        return candidate
    }

    static func isReadableRegularFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.int64Value ?? 0) > 0 else { return false }
        return FileManager.default.isReadableFile(atPath: url.path)
    }
}

enum FolderPathSafety {
    // Manifest lookup is lexical only. Resolve symlinks/check the actual file
    // when opening it, not thousands of times on every navigation transition.
    static func recordedMediaURL(_ relativePath: String, root: URL) -> URL? {
        guard let folder = ["Images/", "Animated GIFs/", "Videos/"].first(where: relativePath.hasPrefix),
              let candidate = LibraryFilePaths.fileURL(for: relativePath, root: root, resolvingSymlinks: false),
              let path = LibraryFilePaths.relativePath(of: candidate, under: root.appendingPathComponent(folder)),
              !path.isEmpty else { return nil }
        return candidate
    }

    static func mediaURL(_ relativePath: String, root: URL) -> URL? {
        guard let mediaFolder = ["Images/", "Animated GIFs/", "Videos/"].first(where: relativePath.hasPrefix) else { return nil }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        guard let candidate = LibraryFilePaths.fileURL(for: relativePath, root: base) else { return nil }
        let mediaBase = base.appendingPathComponent(mediaFolder).standardizedFileURL.resolvingSymlinksInPath()
        guard let folderPath = LibraryFilePaths.relativePath(of: mediaBase, under: base, resolvingSymlinks: true), !folderPath.isEmpty,
              let filePath = LibraryFilePaths.relativePath(of: candidate, under: mediaBase, resolvingSymlinks: true), !filePath.isEmpty,
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
    private var knownMissingPaths: Set<String> = []

    init(roots: [URL]? = nil) {
        self.roots = roots ?? [StorageManager.appDocumentsLibraryURL]
    }

    func reload(publish: Bool = true) async {
        localURLsByMediaKey = [:]
        for root in roots {
            loadState(from: root)
        }
        hasLoaded = true
        if publish { await publishAvailability() }
    }

    func register(root: URL) async {
        if !roots.contains(root) {
            roots.append(root)
            _ = root.startAccessingSecurityScopedResource()
        }
        loadState(from: root)
        hasLoaded = true
        await publishAvailability()
        NotificationCenter.default.post(name: .localMediaLibraryChanged, object: nil)
    }

    func recordedMediaKeys() async -> Set<String> {
        if !hasLoaded { await reload() }
        return Set(localURLsByMediaKey.keys)
    }

    func localURL(for mediaKey: String) async -> URL? {
        if !hasLoaded { await reload() }
        guard let url = localURLsByMediaKey[mediaKey] else { return nil }
        guard isUsableFile(url) else {
            await discardUnavailable(url)
            return nil
        }
        return url
    }

    // Explicit audits use this method. Normal browsing reads recordedMediaKeys
    // and validates only files actually opened by a thumbnail/player/export.
    func availableMediaKeys() async -> Set<String> {
        if !hasLoaded { await reload() }
        let keysByURL = Dictionary(grouping: localURLsByMediaKey.keys, by: { localURLsByMediaKey[$0]! })
        let invalid = Set(keysByURL.keys.filter { !isUsableFile($0) })
        localURLsByMediaKey = localURLsByMediaKey.filter { !invalid.contains($0.value) }
        knownMissingPaths.formUnion(invalid.map(\.path))
        for root in roots {
            let issues = invalid.compactMap { url -> LocalFileIssue? in
                guard let path = LibraryFilePaths.relativePath(of: url, under: root, resolvingSymlinks: true)
                    ?? LibraryFilePaths.relativePath(of: url, under: root) else { return nil }
                return LocalFileIssue(path: path,
                    reason: FileManager.default.fileExists(atPath: url.path) ? "unreadable_or_empty" : "missing",
                    mediaKeys: (keysByURL[url] ?? []).sorted(), observedAt: Date())
            }
            await LocalFileIssueLog.shared.record(issues, root: root)
        }
        if !invalid.isEmpty { await publishAvailability() }
        return Set(localURLsByMediaKey.keys)
    }

    func availableFiles() async -> [String: URL] {
        _ = await availableMediaKeys()
        return localURLsByMediaKey
    }

    func reconcileAfterScan(existingRelativePaths: Set<String>, root: URL = StorageManager.appDocumentsLibraryURL) async {
        await reload(publish: false)
        localURLsByMediaKey = localURLsByMediaKey.filter { _, url in
            guard let relative = LibraryFilePaths.relativePath(of: url, under: root, resolvingSymlinks: true)
                ?? LibraryFilePaths.relativePath(of: url, under: root) else { return true }
            // A scan/path-format mismatch is not proof that a file disappeared.
            // Verify only negative candidates before changing availability.
            let exists = existingRelativePaths.contains(relative) || isUsableFile(url)
            if !exists { knownMissingPaths.insert(url.path) }
            return exists
        }
        await publishAvailability()
    }

    private func isUsableFile(_ url: URL) -> Bool {
        guard roots.contains(where: {
            guard let relative = LibraryFilePaths.relativePath(of: url, under: $0, resolvingSymlinks: true) else { return false }
            return !relative.isEmpty
        }) else { return false }
        return LibraryFilePaths.isReadableRegularFile(url)
    }

    private func discardUnavailable(_ url: URL, publish: Bool = true) async {
        let keys = localURLsByMediaKey.filter { $0.value == url }.map(\.key)
        guard !keys.isEmpty else { return }
        for key in keys { localURLsByMediaKey.removeValue(forKey: key) }
        knownMissingPaths.insert(url.path)
        if let root = roots.first(where: { LibraryFilePaths.relativePath(of: url, under: $0, resolvingSymlinks: true) != nil }),
           let path = LibraryFilePaths.relativePath(of: url, under: root, resolvingSymlinks: true) {
            await LocalFileIssueLog.shared.record(root: root, path: path,
                reason: FileManager.default.fileExists(atPath: url.path) ? "unreadable_or_empty" : "missing", mediaKeys: keys)
        }
        if publish { await publishAvailability() }
    }

    private func publishAvailability() async {
        guard roots.contains(StorageManager.appDocumentsLibraryURL) else { return }
        let keys = Set(localURLsByMediaKey.keys)
        await MainActor.run { LocalMediaAvailability.shared.replace(with: keys) }
    }

    func validateFile(at url: URL) async -> Bool {
        if !hasLoaded { await reload() }
        guard !isUsableFile(url) else { return true }
        await discardUnavailable(url)
        return false
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
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        for record in records {
            guard let url = FolderPathSafety.recordedMediaURL(record.relativePath, root: canonicalRoot) else { continue }
            if knownMissingPaths.contains(url.path), !isUsableFile(url) { continue }
            knownMissingPaths.remove(url.path)
            localURLsByMediaKey[record.mediaKey] = url
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

    func deleteMedia(withKeys keys: Set<String>) async throws {
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
            } else {
                await LocalFileIssueLog.shared.record(root: root, path: path, reason: "missing_during_delete", mediaKeys: Array(keys))
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
    private var hasLoaded = false
    private var isReloading = false

    func reload(force: Bool = false) {
        guard !isReloading, force || !hasLoaded else { return }
        isReloading = true
        Task { [weak self] in
            guard let self else { return }
            defer { isReloading = false }
            do {
                posts = try await library.loadPosts()
                unavailablePosts = try await library.loadUnavailablePosts()
                hasLoaded = true
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
