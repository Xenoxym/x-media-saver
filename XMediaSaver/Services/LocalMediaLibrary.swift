import Combine
import Foundation

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

    private func loadState(from root: URL) {
        let stateURL = root.appendingPathComponent("export-state.jsonl")
        guard let data = try? Data(contentsOf: stateURL) else { return }
        for line in data.split(separator: 0x0A) {
            guard let record = try? JSONDecoder().decode(
                LocalExportStateRecord.self,
                from: Data(line)
            ) else {
                continue
            }
            let url = root.appendingPathComponent(record.relativePath)
            if FileManager.default.fileExists(atPath: url.path) {
                localURLsByMediaKey[record.mediaKey] = url
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

        for key in keys {
            if let relativePath = state[key],
               let fileURL = safeFileURL(for: relativePath),
               FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            state.removeValue(forKey: key)
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

        for key in removedMediaKeys.subtracting(retainedMediaKeys) {
            if let relativePath = state[key],
               let fileURL = safeFileURL(for: relativePath),
               FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            state.removeValue(forKey: key)
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
        let standardizedRoot = root.standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath)
            .standardizedFileURL
        let rootPrefix = standardizedRoot.path.hasSuffix("/")
            ? standardizedRoot.path
            : standardizedRoot.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else { return nil }
        return candidate
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
    }

    func deletePosts(withIDs ids: Set<String>) async throws {
        isWorking = true
        defer { isWorking = false }
        try await library.deletePosts(withIDs: ids)
        posts = try await library.loadPosts()
        unavailablePosts = try await library.loadUnavailablePosts()
        await LocalMediaLibrary.shared.reload()
    }

    private func show(_ error: Error) {
        presentedError = PresentedError(
            message: error.localizedDescription,
            offersSettings: false
        )
    }
}
