import CryptoKit
import Foundation

struct DuplicateMediaReference: Identifiable {
    let post: BookmarkedPost
    let media: BookmarkedMedia
    var id: String { post.id + ":" + media.mediaKey }
}

struct DuplicateMediaGroup: Identifiable {
    let id: String
    let references: [DuplicateMediaReference]
    let matchedByFileHash: Bool
    var posts: [BookmarkedPost] {
        var seen: Set<String> = []
        return references.compactMap { seen.insert($0.post.id).inserted ? $0.post : nil }
    }
}

actor MediaDuplicateAnalyzer {
    private struct FileHashRecord: Codable {
        let size: Int
        let modified: Date?
        let hash: String
    }

    // A shared X asset is still the same source at different image sizes.
    // This is source identity, not a claim of byte-for-byte equality.
    static func sourceIdentity(_ media: BookmarkedMedia) -> String? {
        guard let url = media.downloadURL,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.query = nil
        parts.fragment = nil
        if url.host?.lowercased() == "pbs.twimg.com" {
            if let colon = parts.path.lastIndex(of: ":") { parts.path = String(parts.path[..<colon]) }
            if ["jpg", "jpeg", "png", "webp"].contains(URL(fileURLWithPath: parts.path).pathExtension.lowercased()) {
                parts.path = (parts.path as NSString).deletingPathExtension
            }
        }
        return parts.string
    }

    static func groups(
        posts: [BookmarkedPost], hashesByMediaKey: [String: String] = [:]
    ) -> [DuplicateMediaGroup] {
        var seen: Set<String> = []
        let refs = posts.flatMap { post in post.media.map { DuplicateMediaReference(post: post, media: $0) } }
            .filter { seen.insert($0.id).inserted }
        var parents = Array(refs.indices)
        func root(_ index: Int) -> Int {
            var current = index
            while parents[current] != current { current = parents[current] }
            var node = index
            while parents[node] != current {
                let next = parents[node]; parents[node] = current; node = next
            }
            return current
        }
        var owner: [String: Int] = [:]
        for (index, ref) in refs.enumerated() {
            var tokens = ["key:" + ref.media.mediaKey]
            if let source = sourceIdentity(ref.media) { tokens.append("source:" + source) }
            if let hash = hashesByMediaKey[ref.media.mediaKey] { tokens.append("hash:" + hash) }
            for token in tokens {
                if let other = owner[token] {
                    let left = root(index), right = root(other)
                    parents[left] = right
                }
                else { owner[token] = index }
            }
        }
        var grouped: [Int: [DuplicateMediaReference]] = [:]
        for index in refs.indices { grouped[root(index), default: []].append(refs[index]) }
        return grouped.values.filter { $0.count > 1 }.map { refs in
            DuplicateMediaGroup(
                id: refs.map(\.id).min()!, references: refs,
                matchedByFileHash: {
                    let hashes = refs.compactMap { hashesByMediaKey[$0.media.mediaKey] }
                        .filter { !$0.hasPrefix("same-file:") }
                    return hashes.count > Set(hashes).count
                }()
            )
        }.sorted {
            $0.references.count == $1.references.count ? $0.id < $1.id : $0.references.count > $1.references.count
        }
    }

    func scan(
        posts: [BookmarkedPost], hashLocalFiles: Bool,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> [DuplicateMediaGroup] {
        guard hashLocalFiles else { return Self.groups(posts: posts) }
        await LocalMediaLibrary.shared.reload()
        let files = await LocalMediaLibrary.shared.availableFiles()
        let cacheURL = StorageManager.appDocumentsLibraryURL.appendingPathComponent("file-hashes.json")
        var cache = (try? Data(contentsOf: cacheURL)).flatMap {
            try? JSONDecoder().decode([String: FileHashRecord].self, from: $0)
        } ?? [:]
        let uniqueFiles = Set(files.values)
        var bySize: [Int: [URL]] = [:]
        for url in uniqueFiles {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            if let size = values?.fileSize { bySize[size, default: []].append(url) }
        }
        // Different file lengths cannot be byte-identical. One shared path is
        // included without reading twice; media-key/source matches need no I/O.
        let candidates = bySize.values.filter { $0.count > 1 }.flatMap { $0 }.sorted { $0.path < $1.path }
        var hashesByPath: [String: String] = [:]
        for (index, url) in candidates.enumerated() {
            try Task.checkCancellation()
            progress(index, candidates.count)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize else { continue }
            if let cached = cache[url.path], cached.size == size, cached.modified == values.contentModificationDate {
                hashesByPath[url.path] = cached.hash
                continue
            }
            // Stream at most 1 MiB at a time; never load a whole video in RAM.
            let handle = try FileHandle(forReadingFrom: url)
            var hasher = SHA256()
            do {
                while let block = try handle.read(upToCount: 1_048_576), !block.isEmpty {
                    try Task.checkCancellation()
                    hasher.update(data: block)
                }
                try handle.close()
            } catch { try? handle.close(); throw error }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            hashesByPath[url.path] = digest
            cache[url.path] = FileHashRecord(size: size, modified: values.contentModificationDate, hash: digest)
            await Task.yield()
        }
        let validPaths = Set(uniqueFiles.map(\.path))
        cache = cache.filter { validPaths.contains($0.key) }
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
        progress(candidates.count, candidates.count)
        var hashes: [String: String] = [:]
        for (key, url) in files {
            // The path itself also identifies aliased keys for the same file.
            hashes[key] = hashesByPath[url.path] ?? "same-file:" + url.path
        }
        return Self.groups(posts: posts, hashesByMediaKey: hashes)
    }
}

struct LibraryStorageNode: Identifiable {
    let relativePath: String
    let name: String
    let bytes: Int64
    let children: [LibraryStorageNode]
    var id: String { relativePath }
    var isFolder: Bool { !children.isEmpty }
}

struct LocalFileIssue: Codable, Identifiable {
    let path: String
    let reason: String
    let mediaKeys: [String]
    let observedAt: Date
    var id: String { path + ":" + reason }
}

actor LocalFileIssueLog {
    static let shared = LocalFileIssueLog()

    func records(root: URL = StorageManager.appDocumentsLibraryURL) -> [LocalFileIssue] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("file-issues.json")) else { return [] }
        return (try? JSONDecoder().decode([LocalFileIssue].self, from: data)) ?? []
    }

    func record(root: URL, path: String, reason: String, mediaKeys: [String]) {
        let item = LocalFileIssue(path: path, reason: reason, mediaKeys: mediaKeys.sorted(), observedAt: Date())
        record([item], root: root)
    }

    func record(_ issues: [LocalFileIssue], root: URL) {
        guard !issues.isEmpty else { return }
        var seen: Set<String> = []
        let entries = (issues + records(root: root)).filter { seen.insert($0.id).inserted }
        // Diagnostics only: never retain media data, and bound the metadata log.
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(Array(entries.prefix(200)))
                .write(to: root.appendingPathComponent("file-issues.json"), options: .atomic)
        } catch { /* A read-only/offline location must not prevent remote fallback. */ }
    }

    func reconcile(existingPaths: Set<String>, issues: [LocalFileIssue], root: URL) {
        let remaining = records(root: root).filter { !existingPaths.contains($0.path) }
        var seen: Set<String> = []
        let entries = (issues + remaining).filter { seen.insert($0.id).inserted }
        do {
            guard FileManager.default.fileExists(atPath: root.path) else { return }
            try JSONEncoder().encode(Array(entries.prefix(200)))
                .write(to: root.appendingPathComponent("file-issues.json"), options: .atomic)
        } catch { }
    }
}

struct LibraryIntegrityReport {
    let untrackedFiles: [LibraryStorageNode]
    let issues: [LocalFileIssue]
    let metadataWarnings: [String]
    let verifiedExistingPaths: Set<String>
}

enum LibraryIntegrityInspector {
    static func inspect(root: URL, tree: LibraryStorageNode) throws -> LibraryIntegrityReport {
        var warnings: [String] = []
        var state: [String: String] = [:]
        let stateURL = root.appendingPathComponent("export-state.jsonl")
        if FileManager.default.fileExists(atPath: stateURL.path) {
            let data = try Data(contentsOf: stateURL)
            if let single = try? JSONDecoder().decode(ExportStateRecord.self, from: data) {
                state[single.mediaKey] = single.relativePath
            } else if let legacy = try? JSONDecoder().decode([String: String].self, from: data) {
                state = legacy
            } else {
                for (offset, line) in data.split(separator: 0x0A).enumerated() {
                    try Task.checkCancellation()
                    if let row = try? JSONDecoder().decode(ExportStateRecord.self, from: Data(line)) {
                        state[row.mediaKey] = row.relativePath
                    } else { warnings.append("export-state.jsonl:\(offset + 1)") }
                }
            }
        }
        var files: [String: LibraryStorageNode] = [:]
        func collect(_ node: LibraryStorageNode) {
            if node.children.isEmpty { files[node.relativePath] = node }
            else { node.children.forEach(collect) }
        }
        collect(tree)
        var references: [String: Set<String>] = [:]
        var postLinkedPaths: Set<String> = []
        for (key, path) in state {
            if FolderPathSafety.recordedMediaURL(path, root: root) != nil {
                references[path, default: []].insert(key)
            } else { warnings.append("export-state.jsonl: " + key) }
        }
        let postURL = root.appendingPathComponent("posts.jsonl")
        if FileManager.default.fileExists(atPath: postURL.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for (offset, line) in try Data(contentsOf: postURL).split(separator: 0x0A).enumerated() {
                try Task.checkCancellation()
                guard let post = try? decoder.decode(ExportedPostRecord.self, from: Data(line)) else {
                    warnings.append("posts.jsonl:\(offset + 1)"); continue
                }
                for media in post.media {
                    guard let path = state[media.mediaKey] ?? media.localRelativePath else { continue }
                    guard FolderPathSafety.recordedMediaURL(path, root: root) != nil else {
                        warnings.append("posts.jsonl: " + post.id); continue
                    }
                    references[path, default: []].insert(media.mediaKey)
                    postLinkedPaths.insert(path)
                }
            }
        }
        var verified = Set(files.values.filter { $0.bytes > 0 }.map(\.relativePath))
        var issues: [LocalFileIssue] = []
        for (path, keys) in references {
            if let node = files[path], node.bytes > 0 { continue }
            // Never infer physical deletion from a string-key mismatch alone.
            if let url = FolderPathSafety.mediaURL(path, root: root), LibraryFilePaths.isReadableRegularFile(url) {
                verified.insert(path)
                continue
            }
            issues.append(LocalFileIssue(path: path, reason: files[path] == nil ? "missing" : "unreadable_or_empty",
                mediaKeys: keys.sorted(), observedAt: Date()))
        }
        issues.sort { $0.path < $1.path }
        let untracked = files.values.filter { node in
            FolderPathSafety.recordedMediaURL(node.relativePath, root: root) != nil
                && !postLinkedPaths.contains(node.relativePath)
        }.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
        return LibraryIntegrityReport(untrackedFiles: untracked, issues: issues,
            metadataWarnings: warnings, verifiedExistingPaths: verified)
    }
}

actor LibraryStorageScanner {
    func scan(root: URL = StorageManager.appDocumentsLibraryURL) throws -> LibraryStorageNode {
        if !FileManager.default.fileExists(atPath: root.path) {
            return LibraryStorageNode(relativePath: "", name: "Library", bytes: 0, children: [])
        }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        return try node(at: base, root: base)
    }

    func inspect(tree: LibraryStorageNode, root: URL = StorageManager.appDocumentsLibraryURL) async throws -> LibraryIntegrityReport {
        let report = try LibraryIntegrityInspector.inspect(root: root, tree: tree)
        await LocalFileIssueLog.shared.reconcile(existingPaths: report.verifiedExistingPaths, issues: report.issues, root: root)
        if root == StorageManager.appDocumentsLibraryURL {
            await LocalMediaLibrary.shared.reconcileAfterScan(existingRelativePaths: report.verifiedExistingPaths)
        }
        return report
    }

    private func node(at url: URL, root: URL) throws -> LibraryStorageNode {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
        guard let relative = LibraryFilePaths.relativePath(of: url, under: root) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        if values.isSymbolicLink == true {
            return LibraryStorageNode(relativePath: relative, name: url.lastPathComponent, bytes: 0, children: [])
        }
        if values.isDirectory == true {
            let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            let children = try urls.map { try node(at: $0, root: root) }
                .sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
            return LibraryStorageNode(relativePath: relative, name: url.lastPathComponent,
                                      bytes: children.reduce(0) { $0 + $1.bytes }, children: children)
        }
        return LibraryStorageNode(relativePath: relative, name: url.lastPathComponent,
                                  bytes: Int64(values.fileSize ?? 0), children: [])
    }
}

enum LibraryTreemapLayout {
    struct Tile: Identifiable {
        let node: LibraryStorageNode
        let rect: CGRect
        var id: String { node.id }
    }

    static func tiles(_ nodes: [LibraryStorageNode], in rect: CGRect) -> [Tile] {
        let nonempty = nodes.filter { $0.bytes > 0 }
        guard !nonempty.isEmpty else { return [] }
        if nonempty.count == 1 { return [Tile(node: nonempty[0], rect: rect)] }
        let total = nonempty.reduce(Int64(0)) { $0 + $1.bytes }
        var firstBytes: Int64 = 0
        var split = 1
        for index in 0..<(nonempty.count - 1) {
            firstBytes += nonempty[index].bytes
            split = index + 1
            if firstBytes >= total / 2 { break }
        }
        let fraction = CGFloat(Double(firstBytes) / Double(total))
        let first: CGRect
        let second: CGRect
        if rect.width >= rect.height {
            first = CGRect(x: rect.minX, y: rect.minY, width: rect.width * fraction, height: rect.height)
            second = CGRect(x: first.maxX, y: rect.minY, width: rect.width - first.width, height: rect.height)
        } else {
            first = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * fraction)
            second = CGRect(x: rect.minX, y: first.maxY, width: rect.width, height: rect.height - first.height)
        }
        return tiles(Array(nonempty[..<split]), in: first) + tiles(Array(nonempty[split...]), in: second)
    }
}
