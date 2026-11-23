import CoreGraphics
import CryptoKit
import Foundation

/// Compact low-frequency luminance hash. Used on thumbnails already drawn for
/// browsing and on small frames explicitly requested for manual verification.
enum VideoPerceptualFingerprint {
    static let matchingDistance = 6
    private static let side = 32
    private static let frequencies = 8
    private static let basis: [[Double]] = (0..<frequencies).map { frequency in
        (0..<side).map { sample in
            cos(.pi * (Double(sample) + 0.5) * Double(frequency) / Double(side))
        }
    }

    static func make(from image: CGImage) -> UInt64? {
        var pixels = [UInt8](repeating: 0, count: side * side)
        let rendered = pixels.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
            return true
        }
        guard rendered else { return nil }
        return make(luminance: pixels)
    }

    static func make(luminance: [UInt8]) -> UInt64? {
        guard luminance.count == side * side else { return nil }
        var sum = 0
        var squares = 0
        for byte in luminance {
            let value = Int(byte)
            sum += value
            squares += value * value
        }
        let mean = Double(sum) / Double(luminance.count)
        let variance = Double(squares) / Double(luminance.count) - mean * mean
        // A black frame or a nearly solid card is not useful visual evidence.
        guard variance >= 36 else { return nil }

        var horizontal = [Double](repeating: 0, count: side * frequencies)
        for y in 0..<side {
            for u in 0..<frequencies {
                var coefficient = 0.0
                for x in 0..<side {
                    coefficient += (Double(luminance[y * side + x]) - mean) * basis[u][x]
                }
                horizontal[y * frequencies + u] = coefficient
            }
        }
        var coefficients: [Double] = []
        coefficients.reserveCapacity(frequencies * frequencies - 1)
        for v in 0..<frequencies {
            for u in 0..<frequencies where u != 0 || v != 0 {
                var coefficient = 0.0
                for y in 0..<side {
                    coefficient += horizontal[y * frequencies + u] * basis[v][y]
                }
                coefficients.append(coefficient)
            }
        }
        let median = coefficients.sorted()[coefficients.count / 2]
        let peak = coefficients.map { abs($0) }.max() ?? 0
        guard peak >= 64 else { return nil }
        let deadband = peak * 0.001
        return coefficients.enumerated().reduce(into: UInt64(0)) {
            if $1.element > median + deadband { $0 |= UInt64(1) << $1.offset }
        }
    }
}

actor VideoPosterFingerprints {
    static let shared = VideoPosterFingerprints()

    private struct Entry: Codable {
        let fingerprint: UInt64?
        let observedAt: Date
    }

    private let cacheURL: URL
    private var entries: [String: Entry]?
    private var flushTask: Task<Void, Never>?
    private static let entryLimit = 8_000

    init(cacheURL: URL? = nil) {
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.cacheURL = cacheURL ?? cacheRoot.appendingPathComponent("XMediaSaver-video-posters-v1.json")
    }

    // This can safely be called only after ordinary thumbnail loading produces
    // an image. The scanning API below never calls any thumbnail loader.
    func remember(
        thumbnail: CGImage, media: BookmarkedMedia, isLocal: Bool
    ) {
        guard media.type == .video else { return }
        let identity = isLocal
            ? Self.localIdentity(for: media)
            : Self.posterIdentity(media.previewImageURL).map { "poster:" + $0 }
        guard let identity else { return }
        let key = Self.cacheKey(identity)
        loadIfNeeded()
        guard entries?[key] == nil else { return }
        entries?[key] = Entry(
            fingerprint: VideoPerceptualFingerprint.make(from: thumbnail),
            observedAt: Date()
        )
        if let entries, entries.count > Self.entryLimit {
            self.entries = Dictionary(uniqueKeysWithValues: entries
                .sorted { $0.value.observedAt > $1.value.observedAt }
                .prefix(Self.entryLimit - 500)
                .map { ($0.key, $0.value) })
        }
        scheduleFlush()
    }

    /// Only reads the compact on-device fingerprint cache and the supplied
    /// index snapshot. Does not read video files or load thumbnails.
    func descriptors(for media: [BookmarkedMedia]) async -> [VideoSimilarityDescriptor] {
        let localKeys = await MainActor.run { LocalMediaAvailability.shared.keys }
        loadIfNeeded()
        return Self.descriptors(for: media, localKeys: localKeys, fingerprints: entries ?? [:])
    }

    private static func descriptors(
        for media: [BookmarkedMedia], localKeys: Set<String>, fingerprints: [String: Entry]
    ) -> [VideoSimilarityDescriptor] {
        var byKey: [String: VideoSimilarityDescriptor] = [:]
        for item in media where item.type == .video {
            if Task.isCancelled { return [] }
            let previous = byKey[item.mediaKey]
            let identity = posterIdentity(item.previewImageURL)
            let thumbnail = identity.flatMap { fingerprints[cacheKey("poster:" + $0)]?.fingerprint }
                ?? (localKeys.contains(item.mediaKey)
                    ? localIdentity(for: item).flatMap { fingerprints[cacheKey($0)]?.fingerprint }
                    : nil)
            let hasDimensions = (item.width ?? 0) > 0 && (item.height ?? 0) > 0
            byKey[item.mediaKey] = VideoSimilarityDescriptor(
                id: item.mediaKey,
                width: previous?.width ?? (hasDimensions ? item.width : nil),
                height: previous?.height ?? (hasDimensions ? item.height : nil),
                durationMilliseconds: previous?.durationMilliseconds
                    ?? ((item.durationMilliseconds ?? 0) > 0 ? item.durationMilliseconds : nil),
                posterIdentity: previous?.posterIdentity ?? identity,
                posterFingerprint: previous?.posterFingerprint ?? thumbnail
            )
        }
        return byKey.values.sorted { $0.id < $1.id }
    }

    static func posterIdentity(_ url: URL?) -> String? {
        guard let url,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", let host = parts.host?.lowercased()
        else { return nil }
        parts.host = host
        parts.scheme = "https"
        parts.fragment = nil
        if host == "pbs.twimg.com" {
            // X display-size/format parameters do not identify a new poster.
            let query = parts.queryItems?.filter { !["name", "format"].contains($0.name) } ?? []
            parts.queryItems = query.isEmpty ? nil : query
        }
        return parts.string
    }

    private static func localIdentity(for media: BookmarkedMedia) -> String? {
        // Keep a locally generated thumbnail separate from an X poster. Tie
        // it to both the media key and its known source variant.
        guard let url = media.downloadURL else { return nil }
        return "local:" + media.mediaKey + "\n" + url.absoluteString
    }

    private static func cacheKey(_ identity: String) -> String {
        Data(SHA256.hash(data: Data(identity.utf8))).base64EncodedString()
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
        guard let entries, let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}
