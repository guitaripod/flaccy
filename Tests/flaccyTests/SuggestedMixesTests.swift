import FlaccyCore
import FlaccyEngine
import XCTest
@testable import flaccy

/// Home leads with Tonight's Spin and shows Crate Dig's cover, and both are
/// rebuilt every time anything on Home changes: a launch alone rebuilds them
/// several times. They must come out the same on every build of a listening
/// day, whatever order the library arrives in, and move on with the day.
nonisolated final class SuggestedMixesTests: XCTestCase {

    private var directory: URL!
    private var db: DatabaseManager!
    private let evening = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flaccy-mixes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try DatabaseManager(path: directory.appendingPathComponent("library.sqlite").path)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testTonightsSpinAndCrateDigHoldForTheListeningDay() throws {
        let pool = try shelf()
        let first = picks(pool, at: evening)
        for _ in 0..<5 {
            XCTAssertEqual(picks(pool, at: evening), first)
        }
        XCTAssertEqual(picks(Array(pool.reversed()), at: evening), first)
        XCTAssertEqual(picks(pool, at: evening.addingTimeInterval(3 * 3_600)), first)
        let later = (1...7).map { picks(pool, at: evening.addingTimeInterval(Double($0) * 86_400)).spin }
        XCTAssertTrue(later.contains { $0 != first.spin })
    }

    /// Siri and Shortcuts name a mix by the id Home gives it, so a mix Home builds under a new id would be
    /// one the Play a Mix action can never start.
    func testEveryMixHomeBuildsIsOneSiriCanName() throws {
        let built = SuggestedPlaylistService.build(pool: try shelf(), now: evening, database: db)
        XCTAssertFalse(built.isEmpty)
        for mix in built {
            XCTAssertNotNil(FlaccyMix(rawValue: mix.id), "Play a Mix has no case for \(mix.id)")
        }
    }

    private struct Picks: Equatable {
        let spin: String
        let dig: [String]
    }

    private func picks(_ pool: [Track], at now: Date) -> Picks {
        let mixes = SuggestedPlaylistService.build(pool: pool, now: now, database: db)
        let spin = mixes.first { $0.id == "tonights-spin" }
        let dig = mixes.first { $0.id == "crate-dig" }
        XCTAssertNotNil(spin)
        XCTAssertNotNil(dig)
        return Picks(spin: spin?.title ?? "", dig: dig?.tracks.map(\.fileURL.lastPathComponent) ?? [])
    }

    /// Twelve six-song albums whose opener was played half a year ago, so
    /// every album can be tonight's spin and every other song is a deep cut.
    private func shelf() throws -> [Track] {
        var records: [TrackRecord] = []
        for album in 0..<12 {
            for song in 0..<6 {
                records.append(record(album: album, song: song))
            }
            for _ in 0..<6 {
                try db.insertScrobble(ScrobbleRecord(
                    id: nil,
                    trackTitle: "Album \(album) Song 0",
                    artist: "Artist \(album)",
                    albumTitle: "Album \(album)",
                    timestamp: evening.addingTimeInterval(-200 * 86_400),
                    duration: 210,
                    submitted: true
                ))
            }
        }
        return records.map { Track.from(record: $0, artwork: nil) }
    }

    private func record(album: Int, song: Int) -> TrackRecord {
        TrackRecord(
            id: nil,
            fileURL: "Artist \(album)/Album \(album)/\(album)-\(song).flac",
            title: "Album \(album) Song \(song)",
            artist: "Artist \(album)",
            albumTitle: "Album \(album)",
            trackNumber: song + 1,
            duration: 210,
            artworkData: nil,
            lastFMArtworkURL: nil,
            musicBrainzID: nil,
            albumMusicBrainzID: nil,
            dateAdded: Date(timeIntervalSince1970: 1_750_000_000),
            lastPlayed: nil,
            playCount: 0,
            aiAnalyzed: false,
            analysisAttemptedAt: nil,
            codec: "flac",
            bitDepth: 16,
            sampleRate: 44_100,
            channels: 2
        )
    }
}
