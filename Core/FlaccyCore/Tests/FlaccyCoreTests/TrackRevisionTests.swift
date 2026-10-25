import XCTest
@testable import FlaccyCore

/// Mirrored by the tests in `linux/shared/src/track_revision.rs`: same inputs,
/// same outcomes, with times in milliseconds there.
final class TrackRevisionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400
    private let original = FileSignature(size: 100, modifiedMilliseconds: 1_000)
    private let edited = FileSignature(size: 200, modifiedMilliseconds: 2_000)

    func testNeedsInspection() {
        let unsigned = StoredVersion(signature: nil, fingerprint: nil, revision: 1, revisedAt: nil)
        let signed = StoredVersion(signature: original, fingerprint: "a", revision: 1, revisedAt: nil)

        XCTAssertTrue(TrackRevision.needsInspection(stored: unsigned, current: original))
        XCTAssertFalse(TrackRevision.needsInspection(stored: signed, current: original))
        XCTAssertTrue(TrackRevision.needsInspection(
            stored: signed, current: FileSignature(size: 101, modifiedMilliseconds: 1_000)
        ))
        XCTAssertTrue(TrackRevision.needsInspection(
            stored: signed, current: FileSignature(size: 100, modifiedMilliseconds: 1_001)
        ))
    }

    func testClassify() {
        let unfingerprinted = StoredVersion(signature: original, fingerprint: nil, revision: 1, revisedAt: nil)
        let fingerprinted = StoredVersion(signature: original, fingerprint: "a", revision: 1, revisedAt: nil)

        XCTAssertEqual(TrackRevision.classify(stored: unfingerprinted, currentFingerprint: "a"), .baseline)
        XCTAssertEqual(TrackRevision.classify(stored: fingerprinted, currentFingerprint: nil), .retagged)
        XCTAssertEqual(TrackRevision.classify(stored: fingerprinted, currentFingerprint: "a"), .retagged)
        XCTAssertEqual(TrackRevision.classify(stored: fingerprinted, currentFingerprint: "b"), .newVersion)
    }

    func testApplyingBaseline() {
        let stored = StoredVersion(signature: nil, fingerprint: nil, revision: 1, revisedAt: nil)

        let result = TrackRevision.applying(.baseline, to: stored, signature: original, fingerprint: "a", now: now)

        XCTAssertEqual(result, StoredVersion(signature: original, fingerprint: "a", revision: 1, revisedAt: nil))
    }

    func testApplyingRetaggedKeepsTheFingerprintWhenTheNewOneIsMissing() {
        let revisedAt = now.addingTimeInterval(-3 * day)
        let stored = StoredVersion(signature: original, fingerprint: "a", revision: 2, revisedAt: revisedAt)

        let result = TrackRevision.applying(.retagged, to: stored, signature: edited, fingerprint: nil, now: now)

        XCTAssertEqual(result, StoredVersion(signature: edited, fingerprint: "a", revision: 2, revisedAt: revisedAt))
    }

    func testApplyingNewVersionAdvancesTheRevisionAndStampsIt() {
        let stored = StoredVersion(
            signature: original, fingerprint: "a", revision: 2, revisedAt: now.addingTimeInterval(-3 * day)
        )

        let result = TrackRevision.applying(.newVersion, to: stored, signature: edited, fingerprint: "b", now: now)

        XCTAssertEqual(result, StoredVersion(signature: edited, fingerprint: "b", revision: 3, revisedAt: now))
    }

    func testApplyingUnchangedLeavesTheStoredVersionIdentical() {
        let stored = StoredVersion(
            signature: original, fingerprint: "a", revision: 2, revisedAt: now.addingTimeInterval(-3 * day)
        )

        XCTAssertEqual(TrackRevision.applying(.unchanged, to: stored, signature: original, fingerprint: "b", now: now), stored)
    }

    func testShowsNewMixWithinFourteenDays() {
        XCTAssertFalse(TrackRevision.showsNewMix(revisedAt: nil, now: now))
        XCTAssertTrue(TrackRevision.showsNewMix(revisedAt: now.addingTimeInterval(-13 * day), now: now))
        XCTAssertFalse(TrackRevision.showsNewMix(revisedAt: now.addingTimeInterval(-14 * day), now: now))
    }

    func testPreviousVersionExpiresAfterThirtyDays() {
        XCTAssertFalse(TrackRevision.previousVersionExpired(movedAt: now.addingTimeInterval(-29 * day), now: now))
        XCTAssertTrue(TrackRevision.previousVersionExpired(movedAt: now.addingTimeInterval(-30 * day), now: now))
    }

    func testFingerprintPrefersTheFLACDigest() {
        XCTAssertEqual(TrackRevision.fingerprint(of: .flacMD5("ab"), sha256Hex: nil), "flac:ab")
        XCTAssertEqual(TrackRevision.fingerprint(of: .ranges([0..<1]), sha256Hex: "cd"), "sha256:cd")
        XCTAssertNil(TrackRevision.fingerprint(of: .ranges([0..<1]), sha256Hex: nil))
    }
}
