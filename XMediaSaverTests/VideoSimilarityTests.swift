import CoreGraphics
import XCTest
@testable import XMediaSaver

final class VideoSimilarityTests: XCTestCase {
    func testActiveDimensionsMustAllMatchAndInactiveMissingFieldsAreAllowed() throws {
        let first = video("a", poster: "shared")
        let exact = video("b", poster: "shared")
        let differentSize = video("c", width: 1280, height: 720, poster: "shared")
        let differentPoster = video("d", poster: "other")
        let noSize = video("e", width: nil, height: nil, poster: "shared")
        let all = [first, exact, differentSize, differentPoster, noSize]

        var criteria = VideoSimilarityPreset.parameters.criteria
        criteria.poster = .sameURL
        XCTAssertEqual(try VideoSimilarityMatcher.scan(all, criteria: criteria).matches.count, 1)
        criteria.size = .exactAspect
        XCTAssertEqual(try VideoSimilarityMatcher.scan(all, criteria: criteria).matches.count, 3)
        criteria.size = .any
        XCTAssertEqual(try VideoSimilarityMatcher.scan(all, criteria: criteria).matches.count, 6)
    }

    func testPresetIsAnEditableCopyAndLooseThresholdsIncludeStrictMatches() throws {
        var criteria = VideoSimilarityPreset.qualityVersions.criteria
        XCTAssertEqual(criteria.size, .exactAspect)
        XCTAssertEqual(criteria.duration, .close)
        let base = video("base", width: 100, height: 100, duration: 10_000)
        let same = video("same", width: 100, height: 100, duration: 10_000)
        let near = video("near", width: 99, height: 100, duration: 10_200)
        let outside = video("outside", width: 99, height: 100, duration: 10_201)
        let wrongRatio = video("ratio", width: 98, height: 100, duration: 10_000)

        XCTAssertEqual(try VideoSimilarityMatcher.scan([base, near], criteria: criteria).matches.count, 0)
        criteria.size = .nearAspect
        XCTAssertEqual(try VideoSimilarityMatcher.scan([base, same, near], criteria: criteria).matches.count, 3)
        XCTAssertEqual(try VideoSimilarityMatcher.scan([base, outside], criteria: criteria).matches.count, 0)
        XCTAssertEqual(try VideoSimilarityMatcher.scan([base, wrongRatio], criteria: criteria).matches.count, 0)
        criteria.duration = .relaxed
        XCTAssertEqual(try VideoSimilarityMatcher.scan([base, outside], criteria: criteria).matches.count, 1)
        XCTAssertEqual(VideoSimilarityPreset.qualityVersions.criteria.size, .exactAspect)
    }

    func testPosterOnlyPresetCanFindPreviewWithoutTreatingUnseenPostersAsMatching() throws {
        let candidates = [
            video("full", duration: 15_000, poster: "x"),
            video("preview", duration: 5_000, poster: "x"),
            video("missingPixels", duration: 5_000, poster: "y"),
            video("missingLength", duration: nil, poster: "x")
        ]
        let result = try VideoSimilarityMatcher.scan(candidates, criteria: VideoSimilarityPreset.previewVersions.criteria)
        XCTAssertEqual(result.matches.count, 3)
        XCTAssertEqual(result.matches.filter(\.possiblePreview).count, 1)
        XCTAssertTrue(result.matches.allSatisfy { $0.evidence.contains(.samePosterURL) })
        XCTAssertFalse(result.matches.contains {
            [$0.first.id, $0.second.id].contains("missingPixels")
        })
    }

    func testPosterDistanceDoesNotMergeTransitivePairs() throws {
        let a = video("a", hash: 0x3)
        let b = video("b", hash: 0xFF)
        let c = video("c", hash: 0x3FFF)
        let result = try VideoSimilarityMatcher.scan([a, b, c], criteria: VideoSimilarityPreset.previewVersions.criteria)
        XCTAssertEqual(Set(result.matches.map { [$0.first.id, $0.second.id] }), Set([["a", "b"], ["b", "c"]]))
        XCTAssertTrue(result.matches.allSatisfy { $0.evidence.contains(.similarPoster) })
    }

    func testResultCapKeepsStrongestPairsAndAllAnyDoesNotEnumerate() throws {
        let media = [video("a"), video("b"), video("c", poster: "known"), video("d", poster: "known")]
        let limited = try VideoSimilarityMatcher.scan(media, criteria: VideoSimilarityPreset.parameters.criteria, limit: 1)
        XCTAssertTrue(limited.truncated)
        XCTAssertEqual(limited.matches.first?.first.id, "c")
        XCTAssertEqual(limited.matches.first?.second.id, "d")
        let empty = try VideoSimilarityMatcher.scan(media, criteria: .init(size: .any, duration: .any, poster: .any))
        XCTAssertTrue(empty.matches.isEmpty)
        XCTAssertFalse(empty.truncated)
    }

    func testPosterIdentityIgnoresKnownXRenderParametersOnly() {
        let sized = URL(string: "https://pbs.twimg.com/a?name=large&format=jpg")
        let small = URL(string: "https://pbs.twimg.com/a?format=png&name=small")
        XCTAssertEqual(VideoPosterFingerprints.posterIdentity(sized), VideoPosterFingerprints.posterIdentity(small))
        XCTAssertNotEqual(
            VideoPosterFingerprints.posterIdentity(URL(string: "https://pbs.twimg.com/a?ref=1")),
            VideoPosterFingerprints.posterIdentity(URL(string: "https://pbs.twimg.com/a?ref=2"))
        )
        XCTAssertNil(VideoPosterFingerprints.posterIdentity(URL(string: "file:///tmp/test.jpg")))
    }

    func testDescriptorSnapshotUsesKnownMetadataWithoutResolvingMediaURLs() async throws {
        let first = BookmarkedMedia(
            mediaKey: "a", type: .video, url: nil,
            previewImageURL: URL(string: "https://pbs.twimg.com/a?name=large"), variants: [],
            width: nil, height: nil, durationMilliseconds: 42_000
        )
        let second = BookmarkedMedia(
            mediaKey: "a", type: .video, url: nil, previewImageURL: nil, variants: [],
            width: 1920, height: 1080, durationMilliseconds: nil
        )
        let gif = BookmarkedMedia(
            mediaKey: "gif", type: .animatedGIF, url: nil, previewImageURL: nil, variants: [],
            width: 1920, height: 1080, durationMilliseconds: nil
        )
        let nonexistentCache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = VideoPosterFingerprints(cacheURL: nonexistentCache)
        let descriptors = await store.descriptors(for: [first, second, gif])
        let descriptor = try XCTUnwrap(descriptors.first)
        XCTAssertEqual(descriptors.count, 1)
        XCTAssertEqual(descriptor.width, 1920)
        XCTAssertEqual(descriptor.height, 1080)
        XCTAssertEqual(descriptor.durationMilliseconds, 42_000)
        XCTAssertEqual(descriptor.posterIdentity, "https://pbs.twimg.com/a")
        XCTAssertNil(descriptor.posterFingerprint)
        XCTAssertFalse(FileManager.default.fileExists(atPath: nonexistentCache.path))
    }

    func testFingerprintDiscardsLowInformationAndIgnoresUniformBrightnessChange() throws {
        XCTAssertNil(VideoPerceptualFingerprint.make(luminance: [UInt8](repeating: 5, count: 1024)))
        let pattern = patternedLuminance()
        let first = try XCTUnwrap(VideoPerceptualFingerprint.make(luminance: pattern))
        let second = try XCTUnwrap(VideoPerceptualFingerprint.make(luminance: pattern.map { $0 + 14 }))
        XCTAssertEqual(first, second)
    }

    func testQuickScanSeesFingerprintFromNormallyLoadedPosterOnlyAfterItIsRecorded() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = VideoPosterFingerprints(cacheURL: cache)
        let media = BookmarkedMedia(
            mediaKey: "a", type: .video, url: nil,
            previewImageURL: URL(string: "https://pbs.twimg.com/image?name=large"), variants: [],
            width: 1920, height: 1080, durationMilliseconds: 15_000
        )
        let imageData = Data(patternedLuminance())
        let provider = try XCTUnwrap(CGDataProvider(data: imageData as CFData))
        let image = try XCTUnwrap(CGImage(
            width: 32, height: 32, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let before = await store.descriptors(for: [media])
        XCTAssertNil(before.first?.posterFingerprint)
        await store.remember(thumbnail: image, media: media, isLocal: false)
        let after = await store.descriptors(for: [media])
        XCTAssertNotNil(after.first?.posterFingerprint)
    }

    func testVerificationUsesFourRequestsAtMostAndAlignsPreviewWithStartOfFullClip() throws {
        let preview = VideoSimilarityFrameVerifier.sampleTimes(firstDuration: 10, secondDuration: 50, preview: true)
        XCTAssertEqual(preview.count, 2)
        let last = try XCTUnwrap(preview.last)
        XCTAssertEqual(last.first, 6.5, accuracy: 0.0001)
        XCTAssertEqual(last.second, 6.5, accuracy: 0.0001)
        let version = VideoSimilarityFrameVerifier.sampleTimes(firstDuration: 10, secondDuration: 50, preview: false)
        XCTAssertEqual(try XCTUnwrap(version.last).second, 32.5, accuracy: 0.0001)
    }

    func testVerificationDoesNotCountLowInformationOrANearlyRepeatedFrameTwice() {
        let sample = VideoSimilarityFrameVerifier.Sample(fingerprint: 0xFF, seconds: 2)
        let nearlySame = VideoSimilarityFrameVerifier.Sample(fingerprint: 0xFE, seconds: 4)
        let distinct = VideoSimilarityFrameVerifier.Sample(fingerprint: 0xFF00, seconds: 4)
        let repeated = VideoSimilarityFrameVerifier.evaluate([(sample, sample), (nearlySame, distinct)])
        XCTAssertEqual(repeated.comparedFrames, 1)
        XCTAssertEqual(repeated.matchedFrames, 1)
        let usable = VideoSimilarityFrameVerifier.evaluate([(sample, nil), (distinct, distinct)])
        XCTAssertEqual(usable.comparedFrames, 1)
        let aligned = VideoSimilarityFrameVerifier.evaluate([(sample, sample), (distinct, distinct)])
        XCTAssertEqual(aligned.matchedFrames, 2)
    }

    func testManualVerificationRejectsRemoteURLs() async throws {
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/test.mp4"))
        do {
            _ = try await VideoSimilarityFrameVerifier.verify(first: remote, second: remote, preview: false)
            XCTFail("Remote inputs should never reach AVFoundation")
        } catch VideoSimilarityFrameVerifier.VerificationError.localVideoRequired {
            // Rejected before constructing an asset.
        }
    }

    func testManualVerificationUsesCenterOnlyToCorroborateCloseWholeFrames() {
        let first = VideoSimilarityFrameVerifier.Sample(fingerprint: 0, seconds: 2, centeredFingerprint: 0xFF00)
        let close = VideoSimilarityFrameVerifier.Sample(fingerprint: 0xFF, seconds: 2, centeredFingerprint: 0xFF00)
        let far = VideoSimilarityFrameVerifier.Sample(fingerprint: 0xFFFF, seconds: 2, centeredFingerprint: 0xFF00)
        XCTAssertEqual(VideoSimilarityFrameVerifier.evaluate([(first, close)]).matchedFrames, 1)
        XCTAssertEqual(VideoSimilarityFrameVerifier.evaluate([(first, far)]).matchedFrames, 0)
    }

    private func video(
        _ id: String,
        width: Int? = 1920, height: Int? = 1080, duration: Int? = 10_000,
        poster: String? = nil, hash: UInt64? = nil
    ) -> VideoSimilarityDescriptor {
        .init(id: id, width: width, height: height, durationMilliseconds: duration,
              posterIdentity: poster, posterFingerprint: hash)
    }

    private func patternedLuminance() -> [UInt8] {
        (0..<1024).map { index in
            let x = index % 32
            let y = index / 32
            return UInt8(20 + x * 2 + y * 3 + x * y / 16)
        }
    }
}
