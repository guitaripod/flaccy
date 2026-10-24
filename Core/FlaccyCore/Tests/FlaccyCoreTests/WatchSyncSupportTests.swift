import XCTest
@testable import FlaccyCore

final class WatchAudioProfileTests: XCTestCase {

    func testBitRates() {
        XCTAssertNil(WatchAudioProfile.original.bitRate)
        XCTAssertEqual(WatchAudioProfile.high.bitRate, 256_000)
        XCTAssertEqual(WatchAudioProfile.balanced.bitRate, 192_000)
        XCTAssertEqual(WatchAudioProfile.compact.bitRate, 128_000)
        XCTAssertEqual(WatchAudioProfile.standard, .high)
    }

    func testRequiresEncoding() {
        XCTAssertFalse(WatchAudioProfile.original.requiresEncoding(for: .lossless))
        XCTAssertFalse(WatchAudioProfile.original.requiresEncoding(for: .unknown))
        for profile in [WatchAudioProfile.high, .balanced, .compact] {
            XCTAssertTrue(profile.requiresEncoding(for: .lossless))
            XCTAssertTrue(profile.requiresEncoding(for: .unknown))
            XCTAssertFalse(profile.requiresEncoding(for: .lossy))
        }
    }

    func testEstimatedBytesForEncodedLossless() {
        let estimate = WatchAudioProfile.high.estimatedBytes(durationSeconds: 200, sourceBytes: 40_000_000, sourceKind: .lossless)
        XCTAssertEqual(estimate, 200 * 32_000 + 40_000)
    }

    func testEstimatedBytesRoundsPayloadUp() {
        let estimate = WatchAudioProfile.compact.estimatedBytes(durationSeconds: 0.1, sourceBytes: 1_000_000, sourceKind: .lossless)
        XCTAssertEqual(estimate, 1_600 + 40_000)
    }

    func testEstimatedBytesNeverExceedsSource() {
        let estimate = WatchAudioProfile.high.estimatedBytes(durationSeconds: 300, sourceBytes: 5_000_000, sourceKind: .lossless)
        XCTAssertEqual(estimate, 5_000_000)
    }

    func testEstimatedBytesIsSourceWhenNotEncoded() {
        XCTAssertEqual(WatchAudioProfile.original.estimatedBytes(durationSeconds: 200, sourceBytes: 123, sourceKind: .lossless), 123)
        XCTAssertEqual(WatchAudioProfile.high.estimatedBytes(durationSeconds: 200, sourceBytes: 123, sourceKind: .lossy), 123)
        XCTAssertEqual(WatchAudioProfile.high.estimatedBytes(durationSeconds: 0, sourceBytes: 123, sourceKind: .lossless), 123)
        XCTAssertEqual(WatchAudioProfile.high.estimatedBytes(durationSeconds: -5, sourceBytes: 123, sourceKind: .lossless), 123)
    }

    func testTranscodesFlag() {
        XCTAssertFalse(WatchAudioProfile.original.transcodes)
        XCTAssertTrue(WatchAudioProfile.compact.transcodes)
    }
}

final class SyncStemTests: XCTestCase {

    func testStripsRecognisedExtension() {
        XCTAssertEqual(SyncStem.of("Artist/Album/01 Song.flac"), "Artist/Album/01 Song")
        XCTAssertEqual(SyncStem.of("Artist/Album/01 Song.m4a"), "Artist/Album/01 Song")
        XCTAssertEqual(SyncStem.of("Artist/Album/01 Song.mp3"), "Artist/Album/01 Song")
    }

    func testUppercaseExtensions() {
        XCTAssertEqual(SyncStem.of("A/B/Song.FLAC"), "A/B/Song")
        XCTAssertEqual(SyncStem.of("A/B/Song.Mp3"), "A/B/Song")
    }

    func testFlacAndItsEncodedTwinShareAStem() {
        XCTAssertEqual(SyncStem.of("A/B/Song.flac"), SyncStem.of("A/B/Song.m4a"))
    }

    func testNoExtension() {
        XCTAssertEqual(SyncStem.of("A/B/Song"), "A/B/Song")
    }

    func testUnrecognisedExtensionIsKept() {
        XCTAssertEqual(SyncStem.of("A/B/Song.lrc"), "A/B/Song.lrc")
        XCTAssertEqual(SyncStem.of("A/B/Mr. Brightside"), "A/B/Mr. Brightside")
    }

    func testDottedFolderNamesKeepEverySegment() {
        XCTAssertEqual(SyncStem.of("Vol. 2/Track"), "Vol. 2/Track")
        XCTAssertEqual(SyncStem.of("Vol. 2/Track.flac"), "Vol. 2/Track")
        XCTAssertEqual(SyncStem.of("Artist/Vol.flac/Track"), "Artist/Vol.flac/Track")
    }

    func testDoubleDotsKeepTheRealStem() {
        XCTAssertEqual(SyncStem.of("A/B/Wait... .flac"), "A/B/Wait... ")
        XCTAssertEqual(SyncStem.of("A/B/Song.v2.flac"), "A/B/Song.v2")
    }

    func testNormalisationFormsAreEqual() {
        let nfc = "Bj\u{00F6}rk/Homogenic/01.flac"
        let nfd = "Bjo\u{0308}rk/Homogenic/01.flac"
        XCTAssertNotEqual(Array(nfc.utf8), Array(nfd.utf8))
        XCTAssertEqual(SyncStem.of(nfc), SyncStem.of(nfd))
        XCTAssertEqual(Array(SyncStem.of(nfd).utf8), Array("Bj\u{00F6}rk/Homogenic/01".utf8))
    }

    func testDestinationPath() {
        XCTAssertEqual(SyncStem.destinationPath(forSource: "A/B/Song.flac", encoded: true), "A/B/Song.m4a")
        XCTAssertEqual(SyncStem.destinationPath(forSource: "A/B/Song.flac", encoded: false), "A/B/Song.flac")
        XCTAssertEqual(SyncStem.destinationPath(forSource: "A/B/Song.m4a", encoded: true), "A/B/Song.m4a")
        XCTAssertEqual(SyncStem.destinationPath(forSource: "Vol. 2/Track", encoded: true), "Vol. 2/Track.m4a")
        XCTAssertEqual(
            Array(SyncStem.destinationPath(forSource: "Bjo\u{0308}rk/01.flac", encoded: true).utf8),
            Array("Bj\u{00F6}rk/01.m4a".utf8)
        )
    }

    func testKind() {
        for ext in ["flac", "alac", "wav", "aiff", "aif", "caf", "FLAC"] {
            XCTAssertEqual(SyncStem.kind(ofExtension: ext), .lossless, ext)
        }
        for ext in ["mp3", "aac", "MP3"] {
            XCTAssertEqual(SyncStem.kind(ofExtension: ext), .lossy, ext)
        }
        XCTAssertEqual(SyncStem.kind(ofExtension: "m4a"), .unknown)
        XCTAssertEqual(SyncStem.kind(ofExtension: "ogg"), .unknown)
        XCTAssertEqual(SyncStem.kind(ofExtension: ""), .unknown)
    }
}

final class TransferMetadataTests: XCTestCase {

    func testRoundTripIncludingBytes() throws {
        let original = TransferMetadata(
            relativePath: "A/B/Song.m4a",
            title: "Song",
            artist: "Artist",
            album: "Album",
            trackNumber: 3,
            duration: 201.5,
            bytes: 6_442_450_944
        )
        let parsed = try XCTUnwrap(TransferMetadata(dictionary: original.dictionary))
        XCTAssertEqual(parsed, original)
        XCTAssertEqual(parsed.bytes, 6_442_450_944)
    }

    func testBytesDefaultsToZeroInInitAndWhenAbsent() throws {
        let metadata = TransferMetadata(relativePath: "a", title: "", artist: "", album: "", trackNumber: 0, duration: 0)
        XCTAssertEqual(metadata.bytes, 0)
        var dictionary = metadata.dictionary
        dictionary[SyncKeys.bytes] = nil
        XCTAssertEqual(try XCTUnwrap(TransferMetadata(dictionary: dictionary)).bytes, 0)
    }

    func testBytesAcceptsEveryIntegerRepresentation() throws {
        let base: [String: Any] = [SyncKeys.relativePath: "a"]
        let values: [Any] = [Int64(42), Int(42), NSNumber(value: 42), UInt32(42) as NSNumber]
        for value in values {
            var dictionary = base
            dictionary[SyncKeys.bytes] = value
            XCTAssertEqual(try XCTUnwrap(TransferMetadata(dictionary: dictionary)).bytes, 42)
        }
    }

    func testBytesIgnoresGarbage() throws {
        let dictionary: [String: Any] = [SyncKeys.relativePath: "a", SyncKeys.bytes: "lots"]
        XCTAssertEqual(try XCTUnwrap(TransferMetadata(dictionary: dictionary)).bytes, 0)
    }

    func testRejectsMissingOrEmptyPath() {
        XCTAssertNil(TransferMetadata(dictionary: nil))
        XCTAssertNil(TransferMetadata(dictionary: [:]))
        XCTAssertNil(TransferMetadata(dictionary: [SyncKeys.relativePath: ""]))
    }

    func testPathIsCanonicalised() throws {
        let parsed = try XCTUnwrap(TransferMetadata(dictionary: [SyncKeys.relativePath: "Bjo\u{0308}rk/01.m4a"]))
        XCTAssertEqual(Array(parsed.relativePath.utf8), Array("Bj\u{00F6}rk/01.m4a".utf8))
    }

    func testNewKeysHaveTheAgreedSpelling() {
        XCTAssertEqual(SyncKeys.bytes, "bytes")
        XCTAssertEqual(SyncKeys.usedBytes, "usedBytes")
        XCTAssertEqual(SyncKeys.totalBytes, "totalBytes")
        XCTAssertEqual(SyncKeys.commandRemoved, "removed")
        XCTAssertEqual(SyncKeys.commandPlays, "plays")
        XCTAssertEqual(SyncKeys.plays, "plays")
    }
}

final class WatchPlayTests: XCTestCase {

    private func entry(_ id: String = UUID().uuidString) -> WatchPlayEntry {
        WatchPlayEntry(
            id: id,
            path: "A/B/Song.m4a",
            title: "Song",
            artist: "Artist",
            album: "Album",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000.25),
            durationSeconds: 215
        )
    }

    func testEntryRoundTrip() throws {
        let original = entry("id-1")
        let parsed = try XCTUnwrap(WatchPlayEntry(dictionary: original.dictionary))
        XCTAssertEqual(parsed, original)
    }

    func testEntryDictionaryUsesPlistTypesOnly() {
        let dictionary = entry("id-1").dictionary
        XCTAssertTrue(dictionary["startedAt"] is Double)
        XCTAssertEqual(dictionary["startedAt"] as? Double, 1_700_000_000.25)
        XCTAssertTrue(PropertyListSerialization.propertyList(dictionary, isValidFor: .binary))
    }

    func testEntryRejectsIncompleteDictionaries() {
        let good = entry("id-1").dictionary
        XCTAssertNil(WatchPlayEntry(dictionary: nil))
        for key in ["id", "path", "startedAt"] {
            var broken = good
            broken[key] = nil
            XCTAssertNil(WatchPlayEntry(dictionary: broken), key)
        }
        var emptyID = good
        emptyID["id"] = ""
        XCTAssertNil(WatchPlayEntry(dictionary: emptyID))
    }

    func testEntryToleratesMissingTextAndDuration() throws {
        let parsed = try XCTUnwrap(WatchPlayEntry(dictionary: ["id": "x", "path": "p", "startedAt": 5.0]))
        XCTAssertEqual(parsed.title, "")
        XCTAssertEqual(parsed.durationSeconds, 0)
        XCTAssertEqual(parsed.startedAt, Date(timeIntervalSince1970: 5))
    }

    func testRuleVectors() {
        let vectors: [(played: TimeInterval, duration: TimeInterval, expected: Bool)] = [
            (29, 60, false),
            (30, 60, true),
            (30, 61, false),
            (30.5, 61, true),
            (100, 200, true),
            (99.9, 200, false),
            (239, 600, false),
            (240, 600, true),
            (240, 10_000, true),
            (239.9, 10_000, false),
            (10, 20, false),
            (20, 20, false),
            (500, 20, true),
            (60, 0, false),
            (60, -1, false),
            (0, 100, false),
        ]
        for vector in vectors {
            XCTAssertEqual(
                WatchPlayRule.qualifies(playedSeconds: vector.played, trackDuration: vector.duration),
                vector.expected,
                "\(vector.played)/\(vector.duration)"
            )
        }
    }

    func testLedgerReturnsOnlyUnseenEntries() {
        var ledger = WatchPlayLedger()
        XCTAssertEqual(ledger.accept([entry("a"), entry("b")]).map(\.id), ["a", "b"])
        XCTAssertEqual(ledger.accept([entry("b"), entry("c")]).map(\.id), ["c"])
        XCTAssertEqual(ledger.accept([entry("a"), entry("c")]), [])
        XCTAssertEqual(ledger.seenIDs, ["a", "b", "c"])
    }

    func testLedgerDedupesWithinOneBatch() {
        var ledger = WatchPlayLedger()
        XCTAssertEqual(ledger.accept([entry("a"), entry("a")]).count, 1)
        XCTAssertEqual(ledger.seenIDs, ["a"])
    }

    func testLedgerPersistenceRoundTrip() {
        var ledger = WatchPlayLedger()
        _ = ledger.accept([entry("a"), entry("b")])
        var restored = WatchPlayLedger(seenIDs: ledger.seenIDs)
        XCTAssertEqual(restored, ledger)
        XCTAssertEqual(restored.accept([entry("a"), entry("z")]).map(\.id), ["z"])
    }

    func testLedgerKeepsTheMostRecentTwoThousand() {
        var ledger = WatchPlayLedger()
        _ = ledger.accept((0..<2_005).map { entry("id-\($0)") })
        XCTAssertEqual(ledger.seenIDs.count, 2_000)
        XCTAssertEqual(ledger.seenIDs.first, "id-5")
        XCTAssertEqual(ledger.seenIDs.last, "id-2004")
        XCTAssertEqual(ledger.accept([entry("id-4")]).count, 1)
        XCTAssertEqual(ledger.accept([entry("id-2004")]).count, 0)
        XCTAssertEqual(ledger.seenIDs.count, 2_000)
        XCTAssertEqual(ledger.seenIDs.last, "id-4")
    }

    func testLedgerInitTrimsAndDedupesPersistedIDs() {
        let ledger = WatchPlayLedger(seenIDs: (0..<2_100).map { "id-\($0)" } + ["id-2099"])
        XCTAssertEqual(ledger.seenIDs.count, 2_000)
        XCTAssertEqual(ledger.seenIDs.first, "id-100")
    }
}

final class SyncBatchTests: XCTestCase {

    func testClampsAndDerives() {
        let batch = SyncBatch(total: 10, remaining: 15)
        XCTAssertEqual(batch.remaining, 10)
        XCTAssertEqual(batch.completed, 0)
        XCTAssertEqual(SyncBatch(total: 10, remaining: 4).fraction, 0.6, accuracy: 0.0001)
        XCTAssertFalse(SyncBatch.idle.isActive)
        XCTAssertEqual(SyncBatch.idle.fraction, 0)
    }

    func testWireRoundTrip() throws {
        let batch = SyncBatch(total: 12, remaining: 9, preparing: true)
        let data = try XCTUnwrap(SyncBatchTransfer.encode(batch))
        XCTAssertEqual(SyncBatchTransfer.decode(data), batch)
        XCTAssertNil(SyncBatchTransfer.decode("nope"))
        XCTAssertNil(SyncBatchTransfer.decode(nil))
    }
}
