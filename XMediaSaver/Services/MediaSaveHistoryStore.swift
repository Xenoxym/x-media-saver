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

actor MediaSaveFailureStore {
    private let fileURL: URL
    private var cachedRecords: [SaveFailureRecord]?

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
                .appendingPathComponent("save-failures.json")
        }
    }

    func load() throws -> [SaveFailureRecord] {
        if let cachedRecords { return cachedRecords }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cachedRecords = []
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let records = try? decoder.decode(
            [SaveFailureRecord].self,
            from: Data(contentsOf: fileURL)
        ) else {
            // A partial/corrupt diagnostic file must not prevent future
            // attempts from replacing it with valid failure information.
            cachedRecords = []
            return []
        }
        cachedRecords = records
        return records
    }

    func recordAttempt(
        posts: [BookmarkedPost],
        successfulMediaKeys: Set<String>,
        failureReasons: [String: String]
    ) throws -> [SaveFailureRecord] {
        var records = Dictionary(
            uniqueKeysWithValues: try load().map { ($0.id, $0) }
        )
        let attemptedKeys = successfulMediaKeys.union(failureReasons.keys)

        for post in posts {
            let postKeys = Set(post.media.map(\.mediaKey))
            guard !postKeys.isDisjoint(with: attemptedKeys) else { continue }
            var reasons = records[post.id]?.failureReasons ?? [:]
            for key in successfulMediaKeys.intersection(postKeys) {
                reasons.removeValue(forKey: key)
            }
            for key in postKeys {
                if let reason = failureReasons[key] {
                    reasons[key] = reason
                }
            }
            if reasons.isEmpty {
                records.removeValue(forKey: post.id)
            } else {
                records[post.id] = SaveFailureRecord(
                    post: post,
                    failureReasons: reasons,
                    lastAttemptAt: Date()
                )
            }
        }

        let updated = records.values.sorted {
            $0.lastAttemptAt > $1.lastAttemptAt
        }
        try persist(updated)
        cachedRecords = updated
        return updated
    }

    private func persist(_ records: [SaveFailureRecord]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(records).write(to: fileURL, options: .atomic)
    }
}
