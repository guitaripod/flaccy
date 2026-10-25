import MidgarCore
#if DEBUG
import AVFoundation
import FlaccyCore
import Foundation

/// Drives a song through three versions in a throwaway folder of the real
/// library and logs `REEXPORT EXERCISE PASSED` or `REEXPORT EXERCISE FAILED:
/// <step>`: a re-export saved over the same file keeps the track row, its
/// playlist place and its play count and is noticed as revision 2; the same
/// song imported from another folder with Replace becomes revision 3 and leaves
/// its old file in Previous Versions; restoring puts the second version back
/// without a new revision. Launch with `--exercise-reexport`; read the app log.
///
/// `--shot-new-mix` is the picture mode: `seedRevisedSong()` leaves one
/// re-exported song and its companion in the library, for the platform drivers
/// to open on the screens that show the New mix chip.
@MainActor
enum ReexportExercise {

    static let launchArgument = "--exercise-reexport"
    static let shotArgument = "--shot-new-mix"

    private static let folderName = "Reexport Exercise"
    private static let shotLongName = "A Very Long Song Title That Has To Give Way Before The New Mix Chip Does.wav"
    private static var songName: String {
        CommandLine.arguments.contains("--long-title") ? shotLongName : "Rough Mix.wav"
    }
    private static let companionName = "Other Take.wav"
    private static let artist = "Reexport Exercise Artist"
    static let shotAlbumTitle = "Reexport Exercise Album"
    static let shotArtist = artist
    private static let playlistName = "Reexport Exercise Playlist"

    private struct Failure: Error {
        let step: String
    }

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument),
              !CommandLine.arguments.contains(shotArgument) else { return }
        Task { await run() }
    }

    private static func run() async {
        await waitForFirstLoad()
        var playlistID: Int64?
        let revisions = RevisionLog()
        let observer = NotificationCenter.default.addObserver(
            forName: Library.tracksRevised, object: nil, queue: .main
        ) { notification in
            let paths = notification.userInfo?[Library.RevisionKey.paths] as? [String] ?? []
            MainActor.assumeIsolated { revisions.paths.append(contentsOf: paths) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        do {
            try await removeFixtures(playlistID: nil)
            playlistID = try await exerciseVersions(revisions: revisions)
            try await exerciseKeepBoth()
            try await removeFixtures(playlistID: playlistID)
            MidgarLog.info("REEXPORT EXERCISE PASSED", category: .content)
        } catch let failure as Failure {
            try? await removeFixtures(playlistID: playlistID)
            MidgarLog.error("REEXPORT EXERCISE FAILED: \(failure.step)", category: .content)
        } catch {
            try? await removeFixtures(playlistID: playlistID)
            MidgarLog.error("REEXPORT EXERCISE FAILED: \(error.localizedDescription)", category: .content)
        }
    }

    /// Writes a song, lets the library index it, writes it again so the library
    /// notices a second version, and returns the revised song with the
    /// fixtures left in place. Returns nil, after logging why, when the library
    /// did not see the re-export.
    static func seedRevisedSong() async -> Track? {
        await waitForFirstLoad()
        do {
            try await removeFixtures(playlistID: nil)
            try FileManager.default.createDirectory(at: libraryFolder, withIntermediateDirectories: true)
            try writeSong(at: songURL, frequency: 220, seconds: 3)
            try writeSong(at: libraryFolder.appendingPathComponent(companionName), frequency: 330, seconds: 90)
            await Library.shared.reload()
            await Library.shared.settleRevisions()
            try await Task.sleep(for: .milliseconds(1_200))
            try writeSong(at: songURL, frequency: 440, seconds: 90)
            await Library.shared.reload()
            await Library.shared.settleRevisions()
            let track = try require(
                Library.shared.allTracks.first { LibraryPaths.relativePath(of: $0.fileURL) == relativeSongPath },
                "the library holds the re-exported song"
            )
            try check(track.revision == 2 && track.showsNewMix, "the re-exported song is revision 2 and shows New mix")
            MidgarLog.info("NEW MIX SHOT READY: \(track.title)", category: .content)
            return track
        } catch let failure as Failure {
            MidgarLog.error("NEW MIX SHOT FAILED: \(failure.step)", category: .content)
            return nil
        } catch {
            MidgarLog.error("NEW MIX SHOT FAILED: \(error.localizedDescription)", category: .content)
            return nil
        }
    }

    private static var relativeSongPath: String { "\(folderName)/\(songName)" }
    private static var libraryFolder: URL { LibraryPaths.root.appendingPathComponent(folderName, isDirectory: true) }
    private static var songURL: URL { libraryFolder.appendingPathComponent(songName) }
    private static var stagingRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ReexportExerciseStage", isDirectory: true)
    }

    private static func exerciseVersions(revisions: RevisionLog) async throws -> Int64? {
        let database = DatabaseManager.shared
        let library = Library.shared
        try FileManager.default.createDirectory(at: libraryFolder, withIntermediateDirectories: true)
        try writeSong(at: songURL, frequency: 220, seconds: 1)
        try writeSong(at: libraryFolder.appendingPathComponent(companionName), frequency: 330, seconds: 1)
        await library.reload()
        await library.settleRevisions()

        let first = try require(try database.fetchTrack(byRelativePath: relativeSongPath), "the first version is indexed")
        let firstID = try require(first.id, "the first version has a row id")
        try check(first.revision == 1 && first.revisedAt == nil, "a new song starts at revision 1 with no revisedAt")
        let firstFingerprint = try require(first.audioFingerprint, "a new song is stored with its fingerprint")
        try check(first.fileSize != nil && first.fileModifiedMs != nil, "a new song is stored with its signature")
        report("the first version is indexed at revision 1 (\(firstFingerprint.prefix(14)))")

        let playlist = try database.createPlaylist(name: playlistName)
        let playlistID = try require(playlist.id, "the playlist has an id")
        try database.addTracksToPlaylist(
            playlistId: playlistID, trackFileURLs: ["\(folderName)/\(companionName)", relativeSongPath]
        )
        try database.setPlayCount(relativePath: relativeSongPath, count: 7)
        try database.setLoved(fileURL: relativeSongPath, loved: true, pendingOp: nil)
        let positionBefore = try playlistPosition(of: relativeSongPath, in: playlistID)
        try check(positionBefore == 1, "the song sits second in the playlist")

        try await Task.sleep(for: .milliseconds(1_200))
        try writeSong(at: songURL, frequency: 440, seconds: 2)
        await library.reload()
        await library.settleRevisions()

        let second = try require(try database.fetchTrack(byRelativePath: relativeSongPath), "the second version is indexed")
        try check(second.id == firstID, "the re-export keeps the track row id")
        try check(try playlistPosition(of: relativeSongPath, in: playlistID) == positionBefore, "the re-export keeps the playlist position")
        try check(second.playCount == 7 && second.loved, "the re-export keeps the play count and the love")
        try check(second.revision == 2, "the re-export is revision 2 (was \(second.revision))")
        try check(second.audioFingerprint != firstFingerprint, "the re-export changes the fingerprint")
        try check(TrackRevision.showsNewMix(revisedAt: second.revisedAt, now: Date()), "the re-export shows as a new mix")
        try check(abs(second.duration - 2) < 0.2, "the re-export refreshed the duration (\(second.duration))")
        try check(revisions.paths.contains(relativeSongPath), "tracksRevised named the song")
        let secondFingerprint = try require(second.audioFingerprint, "the second version has a fingerprint")
        let modelTrack = try require(
            library.allTracks.first { LibraryPaths.relativePath(of: $0.fileURL) == relativeSongPath },
            "the in-memory model holds the song"
        )
        try check(modelTrack.revision == 2 && modelTrack.revisedAt != nil, "the in-memory model carries the revision")
        report("the re-export is revision 2 on the same row")

        try await importThirdVersion(library: library, database: database)
        let third = try require(try database.fetchTrack(byRelativePath: relativeSongPath), "the third version is indexed")
        try check(third.id == firstID, "the import keeps the track row id")
        try check(third.revision == 3, "the import is revision 3 (was \(third.revision))")
        try check(third.audioFingerprint != secondFingerprint, "the import changes the fingerprint")
        try check(try playlistPosition(of: relativeSongPath, in: playlistID) == positionBefore, "the import keeps the playlist position")
        report("the import is revision 3 with its previous version kept")

        try await restore(library: library, database: database, expectedFingerprint: secondFingerprint)
        return playlistID
    }

    private static func importThirdVersion(library: LibraryProviding, database: DatabaseManager) async throws {
        let stagedFolder = stagingRoot.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.removeItem(at: stagingRoot)
        try FileManager.default.createDirectory(at: stagedFolder, withIntermediateDirectories: true)
        try writeSong(at: stagedFolder.appendingPathComponent(songName), frequency: 880, seconds: 3)
        let prompts = PromptLog()
        let outcome = await library.importFiles(
            from: [stagedFolder],
            progress: { _ in },
            decideReplacements: { prompt in
                prompts.record(prompt)
                return .replace
            }
        )
        await library.settleRevisions()
        try check(prompts.all.count == 1 && prompts.all.first?.titles == ["Rough Mix"], "the import asked once about \"Rough Mix\" (\(prompts.all))")
        try check(outcome.replaced == 1 && outcome.imported == 0 && outcome.failed == 0, "the import replaced one song (\(outcome))")
        let stored = PreviousVersions.storedURL(forRelativePath: relativeSongPath)
        try check(FileManager.default.fileExists(atPath: stored.path), "the replaced file is kept in Previous Versions")
        try check(database.hasPreviousVersion(trackFileURL: relativeSongPath), "the previous version has a row")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: libraryFolder.path)) ?? []
        try check(!leftovers.contains { $0.hasSuffix(".flaccy-part") }, "no staging file is left in the library folder")
        let message = ImportOutcomeCopy.report(outcome).message
        try check(!message.isEmpty && outcome.replaced == 1, "the outcome reads \"\(message)\"")
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    private static func restore(
        library: LibraryProviding, database: DatabaseManager, expectedFingerprint: String
    ) async throws {
        let track = try require(
            library.allTracks.first { LibraryPaths.relativePath(of: $0.fileURL) == relativeSongPath },
            "the song is in the model before restoring"
        )
        try check(PreviousMix.isAvailable(for: track), "Restore Previous Mix is offered")
        let result = await PreviousMix.restore(track)
        if case .failure(let error) = result {
            throw Failure(step: "restoring failed: \(error.localizedDescription)")
        }
        let restored = try require(try database.fetchTrack(byRelativePath: relativeSongPath), "the restored song is indexed")
        try check(restored.audioFingerprint == expectedFingerprint, "the second version's fingerprint is back")
        try check(restored.revision == 3, "restoring keeps revision 3 (was \(restored.revision))")
        try check(restored.revisedAt == nil, "restoring clears revisedAt")
        try check(abs(restored.duration - 2) < 0.2, "restoring refreshed the duration (\(restored.duration))")
        try check(database.hasPreviousVersion(trackFileURL: relativeSongPath), "the swapped-out version is now the previous one")
        await library.reload()
        await library.settleRevisions()
        let afterScan = try require(try database.fetchTrack(byRelativePath: relativeSongPath), "the song survives a rescan")
        try check(afterScan.revision == 3 && afterScan.audioFingerprint == expectedFingerprint, "a rescan does not revise the restored song")
        report("restoring brought the second version back without a new revision")
    }

    private static func exerciseKeepBoth() async throws {
        let library = Library.shared
        let stagedFolder = stagingRoot.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.removeItem(at: stagingRoot)
        try FileManager.default.createDirectory(at: stagedFolder, withIntermediateDirectories: true)
        try writeSong(at: stagedFolder.appendingPathComponent(songName), frequency: 660, seconds: 4)
        let outcome = await library.importFiles(
            from: [stagedFolder], progress: { _ in }, decideReplacements: { _ in .keepBoth }
        )
        await library.settleRevisions()
        let copy = libraryFolder.appendingPathComponent("Rough Mix_1.wav")
        try check(FileManager.default.fileExists(atPath: copy.path), "Keep Both writes Rough Mix_1.wav")
        try check(outcome.imported == 1 && outcome.replaced == 0, "Keep Both counts a copy, not a replacement (\(outcome))")
        let original = try require(try DatabaseManager.shared.fetchTrack(byRelativePath: relativeSongPath), "the original survives Keep Both")
        try check(original.revision == 3, "Keep Both leaves the original at revision 3")
        try? FileManager.default.removeItem(at: stagingRoot)
        report("Keep Both filed the newer version beside the original")
    }

    private static func removeFixtures(playlistID: Int64?) async throws {
        let database = DatabaseManager.shared
        if let playlistID { try database.deletePlaylist(id: playlistID) }
        try? FileManager.default.removeItem(at: libraryFolder)
        try? FileManager.default.removeItem(at: stagingRoot)
        for path in [relativeSongPath, "\(folderName)/Rough Mix_1.wav", "\(folderName)/\(companionName)"] {
            let stored = PreviousVersions.storedURL(forRelativePath: path)
            try? FileManager.default.removeItem(at: stored)
            try? database.deletePreviousVersion(trackFileURL: path)
        }
        await Library.shared.reload()
        await Library.shared.settleRevisions()
    }

    private static func waitForFirstLoad() async {
        try? await Task.sleep(for: .seconds(3))
        for _ in 0..<120 where Library.shared.isLoading {
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private static func playlistPosition(of path: String, in playlistID: Int64) throws -> Int? {
        try DatabaseManager.shared.fetchPlaylistTracks(playlistId: playlistID).first { $0.trackFileURL == path }?.position
    }

    private static func check(_ condition: Bool, _ step: String) throws {
        report(step, passed: condition)
        guard condition else { throw Failure(step: step) }
    }

    private static func require<Value>(_ value: Value?, _ step: String) throws -> Value {
        report(step, passed: value != nil)
        guard let value else { throw Failure(step: step) }
        return value
    }

    private static func report(_ step: String, passed: Bool = true) {
        MidgarLog.info("ReexportExercise \(passed ? "PASS" : "FAIL"): \(step)", category: .content)
    }

    private final class RevisionLog {
        var paths: [String] = []
    }

    private final class PromptLog: @unchecked Sendable {
        private let lock = NSLock()
        private var prompts: [ImportReplacementPrompt] = []

        var all: [ImportReplacementPrompt] {
            lock.lock()
            defer { lock.unlock() }
            return prompts
        }

        func record(_ prompt: ImportReplacementPrompt) {
            lock.lock()
            prompts.append(prompt)
            lock.unlock()
        }
    }

    /// Writes a stereo 16-bit WAV of one tone and appends the RIFF
    /// INFO tags that make the file name its title and artist, so the importer
    /// can tell that two files are the same song.
    private static func writeSong(at url: URL, frequency: Double, seconds: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44_100),
                  let channels = buffer.floatChannelData
            else { throw Failure(step: "a PCM buffer could not be made") }
            for second in 0..<seconds {
                buffer.frameLength = 44_100
                for frame in 0..<44_100 {
                    let time = Double(second * 44_100 + frame) / 44_100
                    let sample = Float(sin(2 * .pi * frequency * time) * 0.3)
                    channels[0][frame] = sample
                    channels[1][frame] = sample
                }
                try file.write(from: buffer)
            }
        }
        let title = (url.deletingPathExtension().lastPathComponent)
        try appendInfoTags(to: url, title: title, artist: artist, album: shotAlbumTitle)
    }

    private static func appendInfoTags(to url: URL, title: String, artist: String, album: String) throws {
        var body = Data("INFO".utf8)
        for (identifier, text) in [("INAM", title), ("IART", artist), ("IPRD", album)] {
            var value = Data(text.utf8)
            value.append(0)
            if value.count % 2 == 1 { value.append(0) }
            body.append(Data(identifier.utf8))
            body.append(littleEndian32(value.count))
            body.append(value)
        }
        var chunk = Data("LIST".utf8)
        chunk.append(littleEndian32(body.count))
        chunk.append(body)
        var data = try Data(contentsOf: url)
        data.append(chunk)
        data.replaceSubrange(4..<8, with: littleEndian32(data.count - 8))
        try data.write(to: url)
    }

    private static func littleEndian32(_ value: Int) -> Data {
        var little = UInt32(value).littleEndian
        return Data(bytes: &little, count: 4)
    }
}
#endif
