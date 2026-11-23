import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

enum PhotoSimilarityMode: String, CaseIterable, Identifiable, Sendable {
    case strict, standard, advanced
    var id: String { rawValue }

    var title: String {
        switch self {
        case .strict: return L10n.string("严格匹配")
        case .standard: return L10n.string("标准匹配")
        case .advanced: return L10n.string("深度匹配")
        }
    }

    var wholeThreshold: Int {
        switch self {
        case .strict: return 4
        case .standard: return 7
        case .advanced: return 9
        }
    }
}

struct PhotoVisualFingerprint: Codable, Equatable, Sendable {
    let whole: UInt64
    let center80: UInt64?
    let center64: UInt64?
    let aspect: Double

    static func from(image: CGImage) -> Self? {
        guard let hash = VideoPerceptualFingerprint.make(from: image) else { return nil }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        func center(inset: CGFloat) -> UInt64? {
            let rect = bounds.insetBy(dx: width * inset, dy: height * inset).integral
            return image.cropping(to: rect).flatMap { VideoPerceptualFingerprint.make(from: $0) }
        }
        return Self(
            whole: hash, center80: center(inset: 0.10), center64: center(inset: 0.18),
            aspect: Double(width / height)
        )
    }

    static func from(data: Data) -> Self? {
        read(CGImageSourceCreateWithData(data as CFData, nil))
    }

    static func from(file: URL) -> Self? {
        guard file.isFileURL else { return nil }
        return read(CGImageSourceCreateWithURL(file as CFURL, nil))
    }

    private static func read(_ source: CGImageSource?) -> Self? {
        guard let source else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 192
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            .flatMap { from(image: $0) }
    }
}

struct PhotoSimilarityDescriptor: Sendable {
    let id: String
    let source: String?
    let fingerprint: PhotoVisualFingerprint?
}

enum PhotoSimilarityEvidence: Equatable, Sendable {
    case sameSource
    case whole(Int)
    case cropped(Int)

    var title: String {
        switch self {
        case .sameSource: return L10n.string("同一图片来源")
        case .whole: return L10n.string("整图相似")
        case .cropped: return L10n.string("局部画面相似")
        }
    }

    var rank: Int {
        switch self {
        case .sameSource: return 0
        case .whole(let distance): return distance + 1
        case .cropped(let distance): return distance + 16
        }
    }
}

struct PhotoSimilarityMatch: Identifiable, Sendable {
    let firstID: String? // nil when comparing an imported query image
    let secondID: String
    let evidence: PhotoSimilarityEvidence

    var id: String {
        guard let firstID else { return secondID }
        return "\(firstID.utf8.count):\(firstID)\(secondID)"
    }
}

struct PhotoSimilarityGroup: Identifiable, Sendable {
    let representativeID: String
    let matches: [PhotoSimilarityMatch]
    var id: String { representativeID }
}

enum PhotoSimilarityMatcher {
    static func groups(
        _ input: [PhotoSimilarityDescriptor], mode: PhotoSimilarityMode
    ) throws -> [PhotoSimilarityGroup] {
        var seen = Set<String>()
        let photos = input.sorted {
            let a = $0.fingerprint != nil
            let b = $1.fingerprint != nil
            return a == b ? $0.id < $1.id : a
        }.filter { seen.insert($0.id).inserted && ($0.source != nil || $0.fingerprint != nil) }
        var assigned = Set<String>()
        var groups: [PhotoSimilarityGroup] = []
        for (index, anchor) in photos.enumerated() {
            try Task.checkCancellation()
            guard !assigned.contains(anchor.id) else { continue }
            var matches: [PhotoSimilarityMatch] = []
            for next in (index + 1)..<photos.count {
                if next.isMultiple(of: 256) { try Task.checkCancellation() }
                let candidate = photos[next]
                guard !assigned.contains(candidate.id) else { continue }
                let evidence: PhotoSimilarityEvidence?
                if let source = anchor.source, source == candidate.source {
                    evidence = .sameSource
                } else if let a = anchor.fingerprint, let b = candidate.fingerprint {
                    evidence = compare(a, b, mode: mode)
                } else {
                    evidence = nil
                }
                if let evidence {
                    assigned.insert(candidate.id)
                    matches.append(.init(firstID: anchor.id, secondID: candidate.id, evidence: evidence))
                }
            }
            if !matches.isEmpty {
                groups.append(.init(representativeID: anchor.id, matches: matches.sorted {
                    $0.evidence.rank == $1.evidence.rank ? $0.secondID < $1.secondID : $0.evidence.rank < $1.evidence.rank
                }))
            }
        }
        return groups.sorted {
            $0.matches.count == $1.matches.count ? $0.id < $1.id : $0.matches.count > $1.matches.count
        }
    }

    static func compare(
        _ a: PhotoVisualFingerprint, _ b: PhotoVisualFingerprint, mode: PhotoSimilarityMode
    ) -> PhotoSimilarityEvidence? {
        let delta = distance(a.whole, b.whole)
        let aspectDifference = abs(a.aspect - b.aspect) / max(a.aspect, b.aspect)
        if delta <= mode.wholeThreshold, aspectDifference <= (mode == .strict ? 0.03 : 0.10) {
            return .whole(delta)
        }
        // Require some whole-image agreement before testing regional hashes.
        // This avoids over-ranking a shared template/blank region and keeps
        // the broader mode cheap for unrelated images.
        guard mode == .advanced, delta <= 20, aspectDifference <= 0.40 else { return nil }
        var best: Int?
        func check(_ x: UInt64?, _ y: UInt64?) {
            guard let x, let y else { return }
            let value = distance(x, y)
            if value <= 5, value < (best ?? 6) { best = value }
        }
        check(a.center80, b.center80)
        check(a.whole, b.center80)
        check(b.whole, a.center80)
        check(a.whole, b.center64)
        check(b.whole, a.center64)
        return best.map { .cropped($0) }
    }

    static func scan(
        _ input: [PhotoSimilarityDescriptor], mode: PhotoSimilarityMode,
        query: PhotoVisualFingerprint? = nil, limit: Int = 300
    ) throws -> (matches: [PhotoSimilarityMatch], truncated: Bool) {
        var seen = Set<String>()
        let photos = input.sorted { $0.id < $1.id }
            .filter { seen.insert($0.id).inserted && ($0.source != nil || $0.fingerprint != nil) }
        var buckets: [Int: [PhotoSimilarityMatch]] = [:]
        let cap = max(0, limit)
        var truncated = false

        func offer(_ first: String?, _ second: String, _ evidence: PhotoSimilarityEvidence) {
            if buckets[evidence.rank, default: []].count < cap {
                buckets[evidence.rank, default: []].append(
                    PhotoSimilarityMatch(firstID: first, secondID: second, evidence: evidence)
                )
            } else {
                truncated = true
            }
        }
        if let query {
            for a in photos {
                try Task.checkCancellation()
                if let hash = a.fingerprint, let evidence = compare(query, hash, mode: mode) {
                    offer(nil, a.id, evidence)
                }
            }
        } else {
            var sourceGroups: [String: [String]] = [:]
            for photo in photos {
                if let source = photo.source { sourceGroups[source, default: []].append(photo.id) }
            }
            for source in sourceGroups.keys.sorted() {
                try Task.checkCancellation()
                guard let group = sourceGroups[source], group.count > 1 else { continue }
                for (index, id) in group.enumerated() {
                    if buckets[0, default: []].count >= cap {
                        truncated = truncated || index < group.count - 1
                        break
                    }
                    try Task.checkCancellation()
                    for other in group.dropFirst(index + 1) {
                        offer(id, other, .sameSource)
                        if buckets[0, default: []].count >= cap { break }
                    }
                }
            }
            let visual = photos.compactMap { photo -> (PhotoSimilarityDescriptor, PhotoVisualFingerprint)? in
                photo.fingerprint.map { (photo, $0) }
            }
            for (index, a) in visual.enumerated() {
                try Task.checkCancellation()
                for j in (index + 1)..<visual.count {
                    if j.isMultiple(of: 256) { try Task.checkCancellation() }
                    let b = visual[j]
                    if let source = a.0.source, source == b.0.source { continue }
                    if let evidence = compare(a.1, b.1, mode: mode) {
                        offer(a.0.id, b.0.id, evidence)
                    }
                }
            }
        }
        let ranked = buckets.keys.sorted().flatMap { buckets[$0] ?? [] }
        return (Array(ranked.prefix(cap)), truncated || ranked.count > cap)
    }

    private static func distance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }
}

/// Stores small, discardable fingerprints, never copies of images. A fast
/// scan does not ask the thumbnail loader or touch any Folder image files.
actor PhotoSimilarityIndex {
    static let shared = PhotoSimilarityIndex()

    private struct FileStamp: Codable, Hashable {
        let key: String
        let size: Int
        let modified: Date
    }

    private struct Entry: Codable {
        let fingerprint: PhotoVisualFingerprint?
        let stamp: FileStamp?
        let date: Date
    }

    private let cacheURL: URL
    private var entries: [String: Entry]?
    private var flushTask: Task<Void, Never>?
    private var isIndexing = false

    init(cacheURL: URL? = nil) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.cacheURL = cacheURL ?? caches.appendingPathComponent("XMediaSaver-photo-fingerprints-v1.json")
    }

    func remember(thumbnail: CGImage, media: BookmarkedMedia, isLocal: Bool) {
        guard media.type == .photo else { return }
        let key = isLocal ? Self.localKey(media) : Self.sourceKey(media)
        guard let key else { return }
        loadIfNeeded()
        guard entries?[key] == nil else { return }
        entries?[key] = Entry(fingerprint: PhotoVisualFingerprint.from(image: thumbnail), stamp: nil, date: .now)
        if !isIndexing { scheduleFlush() }
    }

    func descriptors(for photos: [BookmarkedMedia]) async -> [PhotoSimilarityDescriptor] {
        let localKeys = await MainActor.run { LocalMediaAvailability.shared.keys }
        loadIfNeeded()
        var descriptors: [String: PhotoSimilarityDescriptor] = [:]
        for photo in photos where photo.type == .photo {
            if Task.isCancelled { return [] }
            let prior = descriptors[photo.mediaKey]
            let local = localKeys.contains(photo.mediaKey)
                ? entries?[Self.localKey(photo)]?.fingerprint : nil
            let source = MediaDuplicateAnalyzer.sourceIdentity(photo)
            let remote = source.flatMap { entries?["source:" + Self.digest($0)]?.fingerprint }
            descriptors[photo.mediaKey] = .init(
                id: photo.mediaKey, source: prior?.source ?? source,
                fingerprint: prior?.fingerprint ?? local ?? remote
            )
        }
        return Array(descriptors.values)
    }

    func indexLocalPhotos(
        _ photos: [BookmarkedMedia], progress: @Sendable (Int, Int) async -> Void
    ) async throws {
        // A canceled worker can still be leaving a synchronous image decode.
        // Do not run another original-file pass concurrently.
        guard !isIndexing else { throw IndexError.busy }
        isIndexing = true
        loadIfNeeded()
        flushTask?.cancel()
        flushTask = nil
        defer {
            isIndexing = false
            flush()
        }
        let keys = await LocalMediaLibrary.shared.recordedMediaKeys()
        var seen = Set<String>()
        let localPhotos = photos.filter {
            $0.type == .photo && keys.contains($0.mediaKey) && seen.insert($0.mediaKey).inserted
        }
        await progress(0, localPhotos.count)
        var decoded: [FileStamp: Entry] = [:]
        var completed = 0
        for photo in localPhotos {
            try Task.checkCancellation()
            let url = await LocalMediaLibrary.shared.localURL(for: photo.mediaKey)
            try Task.checkCancellation()
            indexPhoto(photo, url: url, decoded: &decoded)
            completed += 1
            if completed.isMultiple(of: 25) || completed == localPhotos.count {
                await progress(completed, localPhotos.count)
            }
        }
        try Task.checkCancellation()
    }

    private func indexPhoto(_ photo: BookmarkedMedia, url: URL?, decoded: inout [FileStamp: Entry]) {
        let key = Self.localKey(photo)
        guard let url, let stamp = Self.stamp(for: url)
        else {
            entries?.removeValue(forKey: key)
            return
        }
        if let cached = entries?[key], cached.stamp == stamp {
            decoded[stamp] = cached
        } else if let shared = decoded[stamp] {
            entries?[key] = shared
        } else {
            let hash = autoreleasepool { PhotoVisualFingerprint.from(file: url) }
            let entry = Entry(fingerprint: hash, stamp: stamp, date: .now)
            entries?[key] = entry
            decoded[stamp] = entry
        }
    }

    private static func stamp(for url: URL) -> FileStamp? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
        return FileStamp(key: digest(url.standardizedFileURL.path), size: size, modified: modified)
    }

    private static func localKey(_ media: BookmarkedMedia) -> String {
        "local:" + digest(media.mediaKey)
    }

    private static func sourceKey(_ media: BookmarkedMedia) -> String? {
        MediaDuplicateAnalyzer.sourceIdentity(media).map { "source:" + digest($0) }
    }

    private static func digest(_ value: String) -> String {
        Data(SHA256.hash(data: Data(value.utf8))).base64EncodedString()
    }

    private func loadIfNeeded() {
        guard entries == nil else { return }
        entries = (try? Data(contentsOf: cacheURL))
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func flush() {
        flushTask = nil
        guard var entries else { return }
        if entries.count > 20_000 {
            let ranked = entries.sorted {
                let a = $0.value.stamp != nil
                let b = $1.value.stamp != nil
                return a == b ? $0.value.date > $1.value.date : a
            }
            entries = Dictionary(uniqueKeysWithValues: ranked.prefix(18_000).map { ($0.key, $0.value) })
            self.entries = entries
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    private enum IndexError: Error { case busy }
}
