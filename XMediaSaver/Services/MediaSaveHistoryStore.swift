import Foundation

actor MediaSaveHistoryStore {
    private let fileURL: URL
    private var cachedValues: Set<String>?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let baseURL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.fileURL = baseURL
                .appendingPathComponent("XMediaSaver", isDirectory: true)
                .appendingPathComponent("saved-media-keys.json")
        }
    }

    func load() throws -> Set<String> {
        if let cachedValues {
            return cachedValues
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cachedValues = []
            return []
        }
        let data = try Data(contentsOf: fileURL)
        if let legacy = try? JSONDecoder().decode([String].self, from: data) {
            let values = Set(legacy)
            try rewrite(values)
            cachedValues = values
            return values
        }
        let values = Set(
            data.split(separator: 0x0A).compactMap {
                try? JSONDecoder().decode(String.self, from: Data($0))
            }
        )
        cachedValues = values
        return values
    }

    func insert(_ mediaKey: String) throws -> Set<String> {
        var values = try load()
        guard values.insert(mediaKey).inserted else { return values }
        try append(mediaKey)
        cachedValues = values
        return values
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cachedValues = []
            return
        }
        try FileManager.default.removeItem(at: fileURL)
        cachedValues = []
    }

    private func append(_ mediaKey: String) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var line = try JSONEncoder().encode(mediaKey)
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try line.write(to: fileURL, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    private func rewrite(_ values: Set<String>) throws {
        var data = Data()
        for value in values.sorted() {
            data.append(try JSONEncoder().encode(value))
            data.append(0x0A)
        }
        try data.write(to: fileURL, options: .atomic)
    }
}
