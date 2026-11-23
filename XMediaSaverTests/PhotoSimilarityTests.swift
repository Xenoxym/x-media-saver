import XCTest
@testable import XMediaSaver

final class PhotoSimilarityTests: XCTestCase {
    func testStrictStandardAndAdvancedWholeImageThresholds() {
        let first = fingerprint(0)
        let fiveBitsAway = fingerprint(0x1F)
        let eightBitsAway = fingerprint(0xFF)
        XCTAssertNil(PhotoSimilarityMatcher.compare(first, fiveBitsAway, mode: .strict))
        XCTAssertEqual(PhotoSimilarityMatcher.compare(first, fiveBitsAway, mode: .standard), .whole(5))
        XCTAssertNil(PhotoSimilarityMatcher.compare(first, eightBitsAway, mode: .standard))
        XCTAssertEqual(PhotoSimilarityMatcher.compare(first, eightBitsAway, mode: .advanced), .whole(8))
    }

    func testAdvancedFindsCropAndRejectsAnOtherwiseUnrelatedImage() {
        let original = fingerprint(0, center: 0xFFF)
        let cropped = fingerprint(0xFFF, aspect: 1.2)
        let unrelated = fingerprint(0xFFFFFFFF, center: 0xFFF)
        XCTAssertNil(PhotoSimilarityMatcher.compare(original, cropped, mode: .standard))
        XCTAssertEqual(PhotoSimilarityMatcher.compare(original, cropped, mode: .advanced), .cropped(0))
        XCTAssertEqual(PhotoSimilarityMatcher.compare(cropped, original, mode: .advanced), .cropped(0))
        XCTAssertNil(PhotoSimilarityMatcher.compare(original, unrelated, mode: .advanced))
    }

    func testSourceCanMatchWithoutPixelsButDifferentURLsNeedFingerprints() throws {
        let photos = [
            descriptor("a", source: "same"),
            descriptor("b", source: "same"),
            descriptor("c", source: "elsewhere")
        ]
        let result = try PhotoSimilarityMatcher.scan(photos, mode: .strict)
        XCTAssertEqual(result.matches.count, 1)
        XCTAssertEqual(result.matches.first?.evidence, .sameSource)
    }

    func testReverseLookupRanksAndDoesNotReturnUnknownPixels() throws {
        let photos = [
            descriptor("a", hash: fingerprint(0x1F)),
            descriptor("b", hash: fingerprint(0)),
            descriptor("c", source: "unknown-image")
        ]
        let result = try PhotoSimilarityMatcher.scan(photos, mode: .standard, query: fingerprint(0))
        XCTAssertEqual(result.matches.map(\.secondID), ["b", "a"])
        XCTAssertTrue(result.matches.allSatisfy { $0.firstID == nil })
        XCTAssertFalse(result.truncated)
    }

    func testResultCapKeepsClosestPairs() throws {
        let photos = [
            descriptor("a", hash: fingerprint(0x1F)),
            descriptor("b", hash: fingerprint(0)),
            descriptor("c", hash: fingerprint(0))
        ]
        let result = try PhotoSimilarityMatcher.scan(photos, mode: .standard, limit: 1)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.matches.first?.firstID, "b")
        XCTAssertEqual(result.matches.first?.secondID, "c")
        XCTAssertEqual(result.matches.first?.evidence, .whole(0))
    }

    func testUnreadableOrRemoteQueryDoesNotProduceAPhotoFingerprint() throws {
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/one.png"))
        XCTAssertNil(PhotoVisualFingerprint.from(file: remote))
        XCTAssertNil(PhotoVisualFingerprint.from(data: Data()))
    }

    private func fingerprint(_ bits: UInt64, center: UInt64? = nil, aspect: Double = 1) -> PhotoVisualFingerprint {
        .init(whole: bits, center80: center, center64: nil, aspect: aspect)
    }

    private func descriptor(_ id: String, source: String? = nil, hash: PhotoVisualFingerprint? = nil) -> PhotoSimilarityDescriptor {
        .init(id: id, source: source, fingerprint: hash)
    }
}
