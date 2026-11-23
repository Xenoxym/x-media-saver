@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

struct VideoFrameVerification: Sendable {
    let matchedFrames: Int
    let comparedFrames: Int
}

enum VideoSimilarityFrameVerifier {
    struct Sample: Sendable {
        let fingerprint: UInt64
        let seconds: Double
        let centeredFingerprint: UInt64?

        init(fingerprint: UInt64, seconds: Double, centeredFingerprint: UInt64? = nil) {
            self.fingerprint = fingerprint
            self.seconds = seconds
            self.centeredFingerprint = centeredFingerprint
        }
    }

    enum VerificationError: Error {
        case localVideoRequired
        case invalidDuration
    }

    private static let localVideoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    static func verify(first: URL, second: URL, preview: Bool) async throws -> VideoFrameVerification {
        guard isLocalVideo(first), isLocalVideo(second) else {
            throw VerificationError.localVideoRequired
        }
        try Task.checkCancellation()

        let firstAsset = localAsset(first)
        let secondAsset = localAsset(second)
        let firstGenerator = frameGenerator(for: firstAsset)
        let secondGenerator = frameGenerator(for: secondAsset)

        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let firstDuration = try await firstAsset.load(.duration).seconds
                try Task.checkCancellation()
                let secondDuration = try await secondAsset.load(.duration).seconds
                try Task.checkCancellation()

                let times = sampleTimes(
                    firstDuration: firstDuration,
                    secondDuration: secondDuration,
                    preview: preview
                )
                guard !times.isEmpty else { throw VerificationError.invalidDuration }

                // Keep the tolerance small enough that the two requests still
                // address different points in short clips.
                let tolerance = CMTime(
                    seconds: min(0.12, min(firstDuration, secondDuration) * 0.1),
                    preferredTimescale: 600
                )
                for generator in [firstGenerator, secondGenerator] {
                    generator.requestedTimeToleranceBefore = tolerance
                    generator.requestedTimeToleranceAfter = tolerance
                }

                var pairs: [(first: Sample?, second: Sample?)] = []
                for time in times {
                    let firstFrame = try await sample(firstGenerator, seconds: time.first)
                    let secondFrame = try await sample(secondGenerator, seconds: time.second)
                    pairs.append((firstFrame, secondFrame))
                }
                try Task.checkCancellation()
                return evaluate(pairs)
            } onCancel: {
                firstGenerator.cancelAllCGImageGeneration()
                secondGenerator.cancelAllCGImageGeneration()
                firstAsset.cancelLoading()
                secondAsset.cancelLoading()
            }
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    static func sampleTimes(
        firstDuration: Double,
        secondDuration: Double,
        preview: Bool
    ) -> [(first: Double, second: Double)] {
        guard firstDuration.isFinite, firstDuration > 0,
              secondDuration.isFinite, secondDuration > 0 else { return [] }

        let sharedDuration = min(firstDuration, secondDuration)
        return [0.25, 0.65].map { fraction in
            // A preview is compared with the beginning of the longer file,
            // not with positions at the same percentage of that longer file.
            if preview {
                let seconds = sharedDuration * fraction
                return (seconds, seconds)
            }
            return (firstDuration * fraction, secondDuration * fraction)
        }
    }

    static func evaluate(_ pairs: [(first: Sample?, second: Sample?)]) -> VideoFrameVerification {
        var previousFirst: Sample?
        var previousSecond: Sample?
        var matchedFrames = 0
        var comparedFrames = 0

        for pair in pairs.prefix(2) {
            guard let first = pair.first, let second = pair.second else { continue }
            guard !isRepeated(first, previous: previousFirst),
                  !isRepeated(second, previous: previousSecond) else { continue }

            previousFirst = first
            previousSecond = second
            comparedFrames += 1
            if framesMatch(first, second) {
                matchedFrames += 1
            }
        }

        return VideoFrameVerification(matchedFrames: matchedFrames, comparedFrames: comparedFrames)
    }

    private static func isLocalVideo(_ url: URL) -> Bool {
        let host = url.host ?? ""
        return url.isFileURL && (host.isEmpty || host == "localhost")
            && localVideoExtensions.contains(url.pathExtension.lowercased())
    }

    private static func localAsset(_ url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue)
        ])
    }

    private static func frameGenerator(for asset: AVAsset) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 128, height: 128)
        return generator
    }

    private static func sample(_ generator: AVAssetImageGenerator, seconds: Double) async throws -> Sample? {
        try Task.checkCancellation()
        let (image, time) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        try Task.checkCancellation()
        guard time.seconds.isFinite,
              let fingerprint = VideoPerceptualFingerprint.make(from: image) else { return nil }
        // A small corner badge can change the whole-frame hash. Compare a
        // center crop as corroboration without issuing another decode request.
        let rect = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        let center = rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.12).integral
        let centered = image.cropping(to: center).flatMap { VideoPerceptualFingerprint.make(from: $0) }
        return Sample(fingerprint: fingerprint, seconds: time.seconds, centeredFingerprint: centered)
    }

    private static func framesMatch(_ a: Sample, _ b: Sample) -> Bool {
        let limit = VideoPerceptualFingerprint.matchingDistance
        let wholeDistance = distance(a.fingerprint, b.fingerprint)
        if wholeDistance <= limit { return true }
        guard wholeDistance <= limit * 2,
              let first = a.centeredFingerprint, let second = b.centeredFingerprint
        else { return false }
        return distance(first, second) <= limit
    }

    private static func isRepeated(_ sample: Sample, previous: Sample?) -> Bool {
        guard let previous else { return false }
        // Both an identical decode timestamp and a nearly unchanged frame
        // are insufficient as a second independent piece of evidence.
        return sample.seconds == previous.seconds
            || distance(sample.fingerprint, previous.fingerprint) <= 2
    }

    private static func distance(_ first: UInt64, _ second: UInt64) -> Int {
        (first ^ second).nonzeroBitCount
    }
}
