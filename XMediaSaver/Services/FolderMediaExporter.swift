import Foundation

struct FolderExportProgress: Equatable {
    let completed: Int
    let total: Int
    let currentFraction: Double
    let currentType: BookmarkMediaType?
}

struct FolderExportResult: Equatable {
    let saved: Int
    let skipped: Int
    let failed: Int
    let destination: URL
    let issues: [String]
}

final class FolderMediaExporter: @unchecked Sendable {
    private let downloadClient: DownloadClient

    init(downloadClient: DownloadClient = DownloadClient()) {
        self.downloadClient = downloadClient
    }

    func export(
        posts: [BookmarkedPost],
        mediaByPostID: [String: [BookmarkedMedia]],
        destination: URL,
        progress: @escaping @Sendable (FolderExportProgress) -> Void
    ) async throws -> FolderExportResult {
        let accessed = destination.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                destination.stopAccessingSecurityScopedResource()
            }
        }

        try prepareFolders(at: destination)
        var state = try loadState(at: destination)
        var ordered: [(post: BookmarkedPost, media: BookmarkedMedia)] = []
        var seen: Set<String> = []
        for post in posts {
            for media in mediaByPostID[post.id] ?? []
                where seen.insert(media.mediaKey).inserted {
                ordered.append((post, media))
            }
        }

        var saved = 0
        var skipped = 0
        var failed = 0
        var issues: [String] = []

        for (index, item) in ordered.enumerated() {
            try Task.checkCancellation()
            if let relativePath = state[item.media.mediaKey],
               FileManager.default.fileExists(
                atPath: destination
                    .appendingPathComponent(relativePath)
                    .path
               ) {
                skipped += 1
                progress(
                    FolderExportProgress(
                        completed: index + 1,
                        total: ordered.count,
                        currentFraction: 1,
                        currentType: item.media.type
                    )
                )
                continue
            }

            guard let remoteURL = item.media.downloadURL else {
                skipped += 1
                issues.append("\(item.media.mediaKey)：没有直接媒体地址")
                continue
            }

            progress(
                FolderExportProgress(
                    completed: index,
                    total: ordered.count,
                    currentFraction: 0,
                    currentType: item.media.type
                )
            )

            var temporaryURL: URL?
            do {
                let fileExtension = Self.fileExtension(
                    for: item.media,
                    url: remoteURL
                )
                temporaryURL = try await downloadClient.download(
                    from: remoteURL,
                    fileExtension: fileExtension
                ) { fraction in
                    progress(
                        FolderExportProgress(
                            completed: index,
                            total: ordered.count,
                            currentFraction: fraction,
                            currentType: item.media.type
                        )
                    )
                }
                guard let downloadedURL = temporaryURL else {
                    throw AppError.downloadFailed
                }

                let relativePath = Self.relativePath(
                    postID: item.post.id,
                    media: item.media,
                    fileExtension: fileExtension
                )
                let targetURL = destination.appendingPathComponent(relativePath)
                if FileManager.default.fileExists(atPath: targetURL.path) {
                    try FileManager.default.removeItem(at: targetURL)
                }
                try FileManager.default.moveItem(
                    at: downloadedURL,
                    to: targetURL
                )
                temporaryURL = nil
                state[item.media.mediaKey] = relativePath
                try appendState(
                    mediaKey: item.media.mediaKey,
                    relativePath: relativePath,
                    at: destination
                )
                saved += 1
            } catch is CancellationError {
                if let temporaryURL {
                    try? FileManager.default.removeItem(at: temporaryURL)
                }
                throw CancellationError()
            } catch {
                if let temporaryURL {
                    try? FileManager.default.removeItem(at: temporaryURL)
                }
                failed += 1
                issues.append(
                    "\(item.media.mediaKey)：\(error.localizedDescription)"
                )
            }

            progress(
                FolderExportProgress(
                    completed: index + 1,
                    total: ordered.count,
                    currentFraction: 1,
                    currentType: item.media.type
                )
            )
        }

        try writePostManifest(
            posts: posts,
            mediaByPostID: mediaByPostID,
            state: state,
            destination: destination
        )

        return FolderExportResult(
            saved: saved,
            skipped: skipped,
            failed: failed,
            destination: destination,
            issues: issues
        )
    }

    func cancel() {
        downloadClient.cancel()
    }

    private func prepareFolders(at root: URL) throws {
        for folder in ["Images", "Animated GIFs", "Videos"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(folder, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    private func loadState(at root: URL) throws -> [String: String] {
        let url = root.appendingPathComponent("export-state.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }
        let data = try Data(contentsOf: url)
        if let legacy = try? JSONDecoder().decode(
            [String: String].self,
            from: data
        ) {
            try rewriteState(legacy, at: root)
            return legacy
        }
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

    private func appendState(
        mediaKey: String,
        relativePath: String,
        at root: URL
    ) throws {
        let url = root.appendingPathComponent("export-state.jsonl")
        var data = try JSONEncoder().encode(
            ExportStateRecord(
                mediaKey: mediaKey,
                relativePath: relativePath
            )
        )
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func rewriteState(
        _ state: [String: String],
        at root: URL
    ) throws {
        var data = Data()
        for (key, path) in state.sorted(by: { $0.key < $1.key }) {
            data.append(
                try JSONEncoder().encode(
                    ExportStateRecord(mediaKey: key, relativePath: path)
                )
            )
            data.append(0x0A)
        }
        try data.write(
            to: root.appendingPathComponent("export-state.jsonl"),
            options: .atomic
        )
    }

    private func writePostManifest(
        posts: [BookmarkedPost],
        mediaByPostID: [String: [BookmarkedMedia]],
        state: [String: String],
        destination: URL
    ) throws {
        let temporaryURL = destination.appendingPathComponent("posts.jsonl.tmp")
        let targetURL = destination.appendingPathComponent("posts.jsonl")
        FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: nil
        )
        let handle = try FileHandle(forWritingTo: temporaryURL)
        defer { try? handle.close() }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        for post in posts {
            let record = ExportedPostRecord(
                id: post.id,
                postURL: post.postURL,
                text: post.text,
                createdAt: post.createdAt,
                authorID: post.authorID,
                authorName: post.authorName,
                authorUsername: post.authorUsername,
                media: (mediaByPostID[post.id] ?? []).map { media in
                    ExportedMediaRecord(
                        mediaKey: media.mediaKey,
                        type: media.type,
                        remoteURL: media.downloadURL,
                        localRelativePath: state[media.mediaKey],
                        width: media.width,
                        height: media.height,
                        durationMilliseconds: media.durationMilliseconds,
                        byteSize: media.byteSize
                    )
                }
            )
            var line = try encoder.encode(record)
            line.append(0x0A)
            try handle.write(contentsOf: line)
        }
        try handle.synchronize()
        try handle.close()
        if FileManager.default.fileExists(atPath: targetURL.path) {
            _ = try FileManager.default.replaceItemAt(
                targetURL,
                withItemAt: temporaryURL
            )
        } else {
            try FileManager.default.moveItem(
                at: temporaryURL,
                to: targetURL
            )
        }
    }

    private static func relativePath(
        postID: String,
        media: BookmarkedMedia,
        fileExtension: String
    ) -> String {
        let folder: String
        switch media.type {
        case .photo: folder = "Images"
        case .animatedGIF: folder = "Animated GIFs"
        case .video: folder = "Videos"
        }
        let key = safeComponent(media.mediaKey)
        return "\(folder)/\(safeComponent(postID))_\(key).\(fileExtension)"
    }

    private static func safeComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_")
        )
        let sanitized = value.unicodeScalars.map {
            allowed.contains($0) ? String($0) : "_"
        }.joined()
        return String(sanitized.prefix(120))
    }

    private static func fileExtension(
        for media: BookmarkedMedia,
        url: URL
    ) -> String {
        guard media.type == .photo else { return "mp4" }
        let value = url.pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "heic", "webp"].contains(value)
            ? value
            : "jpg"
    }
}

private struct ExportedPostRecord: Codable {
    let id: String
    let postURL: URL?
    let text: String
    let createdAt: Date?
    let authorID: String?
    let authorName: String?
    let authorUsername: String?
    let media: [ExportedMediaRecord]
}

private struct ExportStateRecord: Codable {
    let mediaKey: String
    let relativePath: String
}

private struct ExportedMediaRecord: Codable {
    let mediaKey: String
    let type: BookmarkMediaType
    let remoteURL: URL?
    let localRelativePath: String?
    let width: Int?
    let height: Int?
    let durationMilliseconds: Int?
    let byteSize: Int64?
}
