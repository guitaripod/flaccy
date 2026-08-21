import XCTest
@testable import FlaccyCore

final class EnrichmentJobTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func albumRecord(
        version: Int = 1,
        status: EnrichmentStatus = .pending,
        fields: EnrichmentFields = [],
        attempts: Int = 0,
        nextEligibleAt: Date? = nil
    ) -> EnrichmentRecord {
        EnrichmentRecord(
            scope: .album,
            key: EnrichmentKey.album(title: "Kind of Blue", artist: "Miles Davis"),
            version: version,
            status: status,
            fields: fields,
            attempts: attempts,
            lastAttemptAt: nil,
            nextEligibleAt: nextEligibleAt,
            lastFailure: nil
        )
    }

    func testNilRecordIsDue() {
        XCTAssertTrue(EnrichmentPolicy.isDue(nil, scope: .album, now: now))
        XCTAssertTrue(EnrichmentPolicy.isDue(nil, scope: .artist, now: now))
        XCTAssertTrue(EnrichmentPolicy.isDue(nil, scope: .aiBatch, now: now))
    }

    func testSatisfiedRecordIsNeverDue() {
        let record = albumRecord(status: .satisfied, fields: [.cover, .year])
        for offset in [0.0, 86_400.0, 365 * 86_400.0] {
            XCTAssertFalse(
                EnrichmentPolicy.isDue(record, scope: .album, now: now.addingTimeInterval(offset)),
                "due at +\(offset)"
            )
        }
    }

    func testExhaustedRecordIsNeverDueAtTheCurrentVersion() {
        let record = albumRecord(
            version: EnrichmentScope.album.currentVersion,
            status: .exhausted,
            attempts: 4
        )
        XCTAssertFalse(EnrichmentPolicy.isDue(record, scope: .album, now: now))
        XCTAssertFalse(
            EnrichmentPolicy.isDue(record, scope: .album, now: now.addingTimeInterval(365 * 86_400))
        )
    }

    func testVersionBumpRevivesExhaustedAndPartial() {
        let exhausted = albumRecord(version: 0, status: .exhausted, attempts: 4)
        let partial = albumRecord(
            version: 0,
            status: .partial,
            fields: [.cover],
            attempts: 1,
            nextEligibleAt: now.addingTimeInterval(86_400)
        )
        XCTAssertTrue(EnrichmentPolicy.isDue(exhausted, scope: .album, now: now))
        XCTAssertTrue(EnrichmentPolicy.isDue(partial, scope: .album, now: now))
    }

    func testVersionBumpDoesNotReviveASatisfiedRecord() {
        let record = albumRecord(version: 0, status: .satisfied, fields: [.cover, .year])
        XCTAssertFalse(EnrichmentPolicy.isDue(record, scope: .album, now: now))
    }

    func testWideningRequiredFieldsRevivesASatisfiedRecord() {
        let record = albumRecord(status: .satisfied, fields: [.cover])
        XCTAssertTrue(EnrichmentPolicy.isDue(record, scope: .album, now: now))
    }

    func testPartialIsNotDueBeforeNextEligibleAt() {
        let record = albumRecord(
            status: .partial,
            fields: [.cover],
            attempts: 1,
            nextEligibleAt: now.addingTimeInterval(86_400)
        )
        XCTAssertFalse(EnrichmentPolicy.isDue(record, scope: .album, now: now))
        XCTAssertTrue(
            EnrichmentPolicy.isDue(record, scope: .album, now: now.addingTimeInterval(86_400))
        )
    }

    func testTransportFailureLeavesAttemptsAndScheduleUntouched() {
        let stamped = now.addingTimeInterval(-3_600)
        var record = albumRecord(status: .partial, attempts: 2, nextEligibleAt: nil)
        record.lastAttemptAt = stamped

        EnrichmentPolicy.apply(to: &record, scope: .album, resolved: [], failure: .transport, now: now)

        XCTAssertEqual(record.attempts, 2)
        XCTAssertEqual(record.lastAttemptAt, stamped)
        XCTAssertNil(record.nextEligibleAt)
        XCTAssertEqual(record.status, .pending)
        XCTAssertEqual(record.lastFailure, .transport)
    }

    func testUnauthorizedLeavesTheRecordPendingAndUnstamped() {
        var record = EnrichmentRecord(scope: .aiBatch, key: EnrichmentKey.aiBatch(directory: "Music/Jazz"))

        EnrichmentPolicy.apply(to: &record, scope: .aiBatch, resolved: [], failure: .unauthorized, now: now)

        XCTAssertEqual(record.attempts, 0)
        XCTAssertNil(record.lastAttemptAt)
        XCTAssertNil(record.nextEligibleAt)
        XCTAssertEqual(record.status, .pending)
        XCTAssertTrue(EnrichmentPolicy.isDue(record, scope: .aiBatch, now: now))
    }

    func testRateLimitedDefersFifteenMinutesWithoutBurningAnAttempt() {
        var record = albumRecord(attempts: 1)

        EnrichmentPolicy.apply(to: &record, scope: .album, resolved: [], failure: .rateLimited, now: now)

        XCTAssertEqual(record.attempts, 1)
        XCTAssertEqual(record.status, .partial)
        XCTAssertEqual(record.nextEligibleAt, now.addingTimeInterval(15 * 60))
        XCTAssertFalse(EnrichmentPolicy.isDue(record, scope: .album, now: now))
        XCTAssertTrue(
            EnrichmentPolicy.isDue(record, scope: .album, now: now.addingTimeInterval(15 * 60))
        )
    }

    func testNotFoundBacksOffOneDaySevenDaysThirtyDaysThenExhausts() {
        var record = albumRecord(version: 0)
        let ladder: [TimeInterval] = [86_400, 7 * 86_400, 30 * 86_400]

        for (index, delay) in ladder.enumerated() {
            let attemptAt = now.addingTimeInterval(Double(index))
            EnrichmentPolicy.apply(
                to: &record, scope: .album, resolved: [], failure: .notFound, now: attemptAt
            )
            XCTAssertEqual(record.attempts, index + 1)
            XCTAssertEqual(record.status, .partial)
            XCTAssertEqual(record.nextEligibleAt, attemptAt.addingTimeInterval(delay))
        }

        let finalAttemptAt = now.addingTimeInterval(3)
        EnrichmentPolicy.apply(
            to: &record, scope: .album, resolved: [], failure: .notFound, now: finalAttemptAt
        )
        XCTAssertEqual(record.attempts, 4)
        XCTAssertEqual(record.attempts, EnrichmentScope.album.maxAttempts)
        XCTAssertEqual(record.status, .exhausted)
        XCTAssertNil(record.nextEligibleAt)
        XCTAssertFalse(
            EnrichmentPolicy.isDue(record, scope: .album, now: finalAttemptAt.addingTimeInterval(365 * 86_400))
        )
    }

    func testCoverAndYearSatisfyAnAlbumWithoutGenre() {
        var record = albumRecord(version: 0)

        EnrichmentPolicy.apply(
            to: &record, scope: .album, resolved: [.cover, .year], failure: nil, now: now
        )

        XCTAssertEqual(record.status, .satisfied)
        XCTAssertFalse(record.fields.contains(.genre))
        XCTAssertNil(record.nextEligibleAt)
        XCTAssertFalse(EnrichmentPolicy.isDue(record, scope: .album, now: now))
    }

    func testPartialResolutionIsPersistedSoARetryOnlyChasesWhatIsMissing() {
        var record = albumRecord(version: 0)

        EnrichmentPolicy.apply(to: &record, scope: .album, resolved: [.cover], failure: .notFound, now: now)
        XCTAssertEqual(record.fields, [.cover])
        XCTAssertEqual(record.status, .partial)

        let later = now.addingTimeInterval(86_400)
        EnrichmentPolicy.apply(to: &record, scope: .album, resolved: [.year], failure: nil, now: later)
        XCTAssertTrue(record.fields.contains(.cover))
        XCTAssertTrue(record.fields.contains(.year))
        XCTAssertEqual(record.status, .satisfied)
    }

    func testAlbumKeyIsCaseAndDiacriticNormalized() {
        let composed = EnrichmentKey.album(title: "Homogenic", artist: "Björk")
        let shouted = EnrichmentKey.album(title: "HOMOGENIC", artist: "BJÖRK")
        let decomposed = EnrichmentKey.album(title: " Homogenic ", artist: "Bjo\u{0308}rk")

        XCTAssertEqual(composed.scalarValues, shouted.scalarValues)
        XCTAssertEqual(composed.scalarValues, decomposed.scalarValues)
        XCTAssertEqual(EnrichmentKey.artist(" BJÖRK ").scalarValues, EnrichmentKey.artist("Bjo\u{0308}rk").scalarValues)
    }

    func testAlbumKeyUsesUnitSeparatorSoTitleArtistCannotCollide() {
        let first = EnrichmentKey.album(title: "ab", artist: "c")
        let second = EnrichmentKey.album(title: "a", artist: "bc")

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first, "ab\u{1F}c")
        XCTAssertEqual(second, "a\u{1F}bc")
    }

    func testAiBatchKeyMatchesTheDirectoryGrouping() {
        XCTAssertEqual(EnrichmentKey.aiBatch(directory: ""), "")
        XCTAssertEqual(EnrichmentKey.aiBatch(directory: "Music/Miles Davis/Kind Of Blue"),
                       "music/miles davis/kind of blue")
        XCTAssertEqual(EnrichmentKey.aiBatch(directory: " Music/Jazz "),
                       EnrichmentKey.aiBatch(directory: "music/jazz"))
    }

    /// Every row of the Rust client's composition table, spelled decomposed and
    /// then precomposed, so the two languages provably key the same letters the
    /// same way. `every_composition_row_matches_foundation_nfc` in
    /// `linux/shared/src/enrichment_job.rs` pins the identical corpus.
    func testCompositionCorpusMatchesFoundationNFC() {
        for (mark, bases, composed) in Self.compositionCorpus {
            let decomposed = bases.map { String($0) + mark }.joined()
            let row = "U+\(String(mark.unicodeScalars.first!.value, radix: 16)) row"
            XCTAssertEqual(EnrichmentKey.normalize(decomposed).scalarValues, composed.scalarValues, row)
            XCTAssertEqual(EnrichmentKey.normalize(composed).scalarValues, composed.scalarValues, row)
            XCTAssertEqual(EnrichmentKey.artist(decomposed.uppercased()).scalarValues, composed.scalarValues, row)
        }
    }

    static let compositionCorpus: [(String, String, String)] = [
        ("\u{0300}", "aeinouy", "àèìǹòùỳ"),
        ("\u{0301}", "aceginorsuyz", "áćéǵíńóŕśúýź"),
        ("\u{0302}", "aceghijosuwy", "âĉêĝĥîĵôŝûŵŷ"),
        ("\u{0303}", "aeinou", "ãẽĩñõũ"),
        ("\u{0304}", "aeiou", "āēīōū"),
        ("\u{0306}", "aegiou", "ăĕğĭŏŭ"),
        ("\u{0307}", "cegz", "ċėġż"),
        ("\u{0308}", "aeiouy", "äëïöüÿ"),
        ("\u{0309}", "aeiouy", "ảẻỉỏủỷ"),
        ("\u{030a}", "au", "åů"),
        ("\u{030b}", "ou", "őű"),
        ("\u{030c}", "cdeghlnrstz", "čďěǧȟľňřšťž"),
        ("\u{0323}", "aeiouy", "ạẹịọụỵ"),
        ("\u{0327}", "cgklnrst", "çģķļņŗşţ"),
        ("\u{0328}", "aeiou", "ąęįǫų"),
    ]

    func testRecordRoundTripsThroughCodable() throws {
        let record = EnrichmentRecord(
            scope: .artist,
            key: EnrichmentKey.artist("Björk"),
            version: 1,
            status: .partial,
            fields: [.artistBio, .artistImage],
            attempts: 2,
            lastAttemptAt: now,
            nextEligibleAt: now.addingTimeInterval(7 * 86_400),
            lastFailure: .notFound
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(EnrichmentRecord.self, from: data)

        XCTAssertEqual(decoded, record)
    }

    func testJobProgressExposesNoFraction() {
        let children = Mirror(reflecting: EnrichmentJobProgress.idle).children
        let labels = children.compactMap(\.label)

        XCTAssertFalse(labels.isEmpty)
        for label in labels {
            XCTAssertFalse(
                label.lowercased().contains("fraction"),
                "EnrichmentJobProgress must not expose \(label)"
            )
        }
    }
}

#if canImport(SQLite3)
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The half of the key contract SQL owns. `DatabaseManager` registers
/// `EnrichmentKey.normalize` under `EnrichmentKey.sqlFunctionName` on every
/// connection precisely because SQLite's own `lower()` folds ASCII only and its
/// `trim()` strips spaces only — without it the queue, the seeds and the orphan
/// sweep key "Ágætis byrjun" one way while the code that reads and writes the
/// row keys it another, and every sync deletes the state and re-enriches from
/// zero. `sql_normalizer_agrees_with_the_rust_one` is the Rust twin.
final class EnrichmentKeySQLTests: XCTestCase {

    private var handle: OpaquePointer?

    override func setUpWithError() throws {
        try super.setUpWithError()
        var opened: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &opened), SQLITE_OK)
        let database = try XCTUnwrap(opened)
        handle = database
        XCTAssertEqual(Self.registerNormalizer(on: database), SQLITE_OK)
    }

    override func tearDownWithError() throws {
        if let handle { sqlite3_close(handle) }
        handle = nil
        try super.tearDownWithError()
    }

    private static func registerNormalizer(on database: OpaquePointer) -> Int32 {
        sqlite3_create_function_v2(
            database, EnrichmentKey.sqlFunctionName, 1,
            SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil,
            { context, _, values in
                guard let values, let raw = sqlite3_value_text(values[0]) else {
                    sqlite3_result_null(context)
                    return
                }
                sqlite3_result_text(context, EnrichmentKey.normalize(String(cString: raw)), -1, sqliteTransient)
            },
            nil, nil, nil
        )
    }

    private func text(_ sql: String, _ bindings: [String]) throws -> String {
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(try XCTUnwrap(handle), sql, -1, &statement, nil), SQLITE_OK)
        let prepared = try XCTUnwrap(statement)
        defer { sqlite3_finalize(prepared) }
        for (index, binding) in bindings.enumerated() {
            XCTAssertEqual(sqlite3_bind_text(prepared, Int32(index + 1), binding, -1, sqliteTransient), SQLITE_OK)
        }
        XCTAssertEqual(sqlite3_step(prepared), SQLITE_ROW)
        return String(cString: try XCTUnwrap(sqlite3_column_text(prepared, 0)))
    }

    private static let corpus: [(title: String, artist: String)] = [
        ("  Homogenic ", "Bjork"),
        ("Ágætis byrjun", "Sigur Rós"),
        ("Bjo\u{0308}rk Album", " Sigur Ro\u{0301}s \t"),
        ("\tMOTÖRHEAD \t", "ÓLAFUR ARNALDS"),
        ("L\u{030c}ubomír", "Ȟ"),
        ("", "  "),
    ]

    func testSQLFunctionAgreesWithTheNormalizer() throws {
        for (title, artist) in Self.corpus {
            for value in [title, artist] {
                XCTAssertEqual(
                    try text("SELECT flaccy_norm(?1)", [value]).scalarValues,
                    EnrichmentKey.normalize(value).scalarValues,
                    value
                )
            }
        }
    }

    func testSQLAlbumKeyExpressionAgreesWithEnrichmentKey() throws {
        let expression = "SELECT flaccy_norm(?1) || char(31) || flaccy_norm(?2)"
        for (title, artist) in Self.corpus {
            XCTAssertEqual(
                try text(expression, [title, artist]).scalarValues,
                EnrichmentKey.album(title: title, artist: artist).scalarValues,
                "\(title) — \(artist)"
            )
        }
    }

    /// Why the function has to exist at all: the expression it replaced derives
    /// a different key for every one of these, which is what made the sweep
    /// delete their state on each scan.
    func testSQLiteBuiltinsCannotDeriveTheKey() throws {
        let builtin = "SELECT lower(trim(?1)) || char(31) || lower(trim(?2))"
        for (title, artist) in Self.corpus.dropFirst().prefix(4) {
            XCTAssertNotEqual(
                try text(builtin, [title, artist]).scalarValues,
                EnrichmentKey.album(title: title, artist: artist).scalarValues,
                "\(title) — \(artist)"
            )
        }
    }
}
#endif

private extension String {
    /// Swift compares strings by canonical equivalence, so a normalizer that
    /// forgot NFC still tests equal to a precomposed literal — while SQLite,
    /// which matches `enrichmentState.key` as bytes, would see two keys. Every
    /// key assertion compares scalars for that reason.
    var scalarValues: [UInt32] { unicodeScalars.map(\.value) }
}
