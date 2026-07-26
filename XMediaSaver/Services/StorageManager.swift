import Foundation

struct StorageSnapshot: Equatable {
    let bookmarkIndexBytes: Int64
    let downloadLibraryBytes: Int64
    let temporaryBytes: Int64
    let urlCacheBytes: Int64
    let privateLibraryBytes: Int64

    var knownTotalBytes: Int64 {
        bookmarkIndexBytes
            + downloadLibraryBytes
            + temporaryBytes
            + urlCacheBytes
            + privateLibraryBytes
    }
}

actor StorageManager {
    static var appDocumentsLibraryURL: URL {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return documents.appendingPathComponent("Library", isDirectory: true)
    }

    func snapshot() -> StorageSnapshot {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("XMediaSaver", isDirectory: true)
        let privateLibrary = fileManager.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first

        let indexBytes = appSupport.map(directorySize) ?? 0
        let documentsBytes = directorySize(Self.appDocumentsLibraryURL)
        let temporaryBytes = temporaryDownloadSize()
        let urlCacheBytes = Int64(URLCache.shared.currentDiskUsage)
        let allPrivateBytes = privateLibrary.map(directorySize) ?? 0

        return StorageSnapshot(
            bookmarkIndexBytes: indexBytes,
            downloadLibraryBytes: documentsBytes,
            temporaryBytes: temporaryBytes,
            urlCacheBytes: urlCacheBytes,
            privateLibraryBytes: max(
                0,
                allPrivateBytes - indexBytes - urlCacheBytes
            )
        )
    }

    func clearTemporaryAndURLCache() {
        URLCache.shared.removeAllCachedResponses()
        let fileManager = FileManager.default
        let temporaryURL = fileManager.temporaryDirectory
        guard let contents = try? fileManager.contentsOfDirectory(
            at: temporaryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for url in contents where url.lastPathComponent.hasPrefix("XMediaSaver-") {
            try? fileManager.removeItem(at: url)
        }
    }

    func clearDownloadLibrary() throws {
        let url = Self.appDocumentsLibraryURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func temporaryDownloadSize() -> Int64 {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        return contents
            .filter { $0.lastPathComponent.hasPrefix("XMediaSaver-") }
            .reduce(0) { $0 + directorySize($1) }
    }

    private func directorySize(_ root: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            let values = try? root.resourceValues(forKeys: keys)
            return Int64(
                values?.totalFileAllocatedSize
                    ?? values?.fileAllocatedSize
                    ?? 0
            )
        }

        var result: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true
            else {
                continue
            }
            result += Int64(
                values.totalFileAllocatedSize
                    ?? values.fileAllocatedSize
                    ?? 0
            )
        }
        return result
    }
}
