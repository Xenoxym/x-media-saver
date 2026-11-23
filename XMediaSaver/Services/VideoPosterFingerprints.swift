import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

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
    private var previewDirectory: URL {
        cacheURL.deletingPathExtension().appendingPathExtension("covers")
    }
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
        if let recorded = entries?[key] {
            if recorded.fingerprint != nil { savePreviewIfNeeded(thumbnail, key: key) }
            return
        }
        entries?[key] = Entry(
            fingerprint: VideoPerceptualFingerprint.make(from: thumbnail),
            observedAt: Date()
        )
        if entries?[key]?.fingerprint != nil { savePreviewIfNeeded(thumbnail, key: key) }
        if let entries, entries.count > Self.entryLimit {
            let kept = Dictionary(uniqueKeysWithValues: entries
                .sorted { $0.value.observedAt > $1.value.observedAt }
                .prefix(Self.entryLimit - 500)
                .map { ($0.key, $0.value) })
            for key in entries.keys where kept[key] == nil {
                try? FileManager.default.removeItem(at: previewURL(for: key))
            }
            self.entries = kept
        }
        scheduleFlush()
    }

    func previewData(for media: BookmarkedMedia) -> Data? {
        let remote = Self.posterIdentity(media.previewImageURL).map { "poster:" + $0 }
        for identity in [remote, Self.localIdentity(for: media)].compactMap({ $0 }) {
            if let data = try? Data(contentsOf: previewURL(for: Self.cacheKey(identity))) { return data }
        }
        return nil
    }

    /// User-initiated cover backfill only. The normal quick scan never
    /// invokes this, and the URLs here are image posters, never MP4 assets.
    func fillMissingPosters(for media: [BookmarkedMedia]) async throws {
        loadIfNeeded()
        var seen = Set<String>()
        var pending: [(BookmarkedMedia, URL)] = []
        for item in media where item.type == .video {
            try Task.checkCancellation()
            guard let url = LocalMediaThumbnailLoader.previewURL(item.previewImageURL, name: "small"),
                  url.scheme == "https", url.host?.lowercased() == "pbs.twimg.com",
                  let identity = Self.posterIdentity(item.previewImageURL), seen.insert(identity).inserted
            else { continue }
            let key = Self.cacheKey("poster:" + identity)
            if let entry = entries?[key],
               entry.fingerprint == nil || FileManager.default.fileExists(atPath: previewURL(for: key).path) {
                continue
            }
            pending.append((item, url))
            if pending.count >= 160 { break }
        }
        for start in stride(from: 0, to: pending.count, by: 4) {
            try Task.checkCancellation()
            let end = min(start + 4, pending.count)
            await withTaskGroup(of: (BookmarkedMedia, CGImage?).self) { group in
                for (item, url) in pending[start..<end] {
                    group.addTask { (item, await Self.fetchPoster(url)) }
                }
                for await (item, cover) in group {
                    guard !Task.isCancelled, let cover else { continue }
                    remember(thumbnail: cover, media: item, isLocal: false)
                }
            }
        }
        try Task.checkCancellation()
    }

    private static func fetchPoster(_ url: URL) async -> CGImage? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await posterSession.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              http.url?.host?.lowercased() == "pbs.twimg.com",
              data.count <= 4 * 1_048_576,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 160
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static let posterSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private func previewURL(for key: String) -> URL {
        previewDirectory.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".jpg")
    }

    private func savePreviewIfNeeded(_ image: CGImage, key: String) {
        let output = previewURL(for: key)
        guard !FileManager.default.fileExists(atPath: output.path) else { return }
        let scale = min(1, 128 / CGFloat(max(image.width, image.height)))
        let width = max(Int(CGFloat(image.width) * scale), 1)
        let height = max(Int(CGFloat(image.height) * scale), 1)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        let bytes = NSMutableData()
        guard let small = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        // A compact disk cache lets results retain their covers after a restart.
        CGImageDestinationAddImage(destination, small, [
            kCGImageDestinationLossyCompressionQuality: 0.58
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination), bytes.length <= 8192 else { return }
        try? FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
        try? (bytes as Data).write(to: output, options: .atomic)
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
