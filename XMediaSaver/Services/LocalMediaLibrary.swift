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
