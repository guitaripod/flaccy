import MidgarCore
#if DEBUG && os(iOS)
import AVFoundation
import FlaccyCore
import Foundation

/// Drives the real sync engine against a paired watch simulator and logs
/// PASS/FAIL per expectation: the album arrives, the watch holds fewer bytes
/// than the originals, a second request while everything is delivered sends
/// nothing, removal empties the watch, and the original quality ships files
/// untouched. Launch the phone with `--exercise-watch-sync --seed-screenshots`
/// after installing the app (and so its watch app) on a paired pair of
/// simulators; read the app log afterwards.
@MainActor
enum WatchSyncExercise {

    static let launchArgument = "--exercise-watch-sync"
    static let backgroundTaskArgument = "--exercise-watch-bgtask"

    static func runIfRequested() {
        if CommandLine.arguments.contains(backgroundTaskArgument) {
            Task { await runBackgroundTask() }
        }
        guard CommandLine.arguments.contains(launchArgument) else { return }
        Task { await run() }
    }

    /// Starts the continued processing task the sync uses, reports twenty
    /// units of progress over twenty seconds and finishes, so a real device can
    /// show whether the system accepts the identifiers and runs the handler.
    private static func runBackgroundTask() async {
        try? await Task.sleep(for: .seconds(3))
        let task = WatchSyncBackgroundTask.shared
        task.begin(total: 20)
        for completed in 1...20 {
            try? await Task.sleep(for: .seconds(1))
            task.update(completed: completed, total: 20)
        }
        task.finish()
        MidgarLog.info("WatchSyncExercise finished background task run", category: .connectivity)
    }

    private static func run() async {
        let service = WatchSyncService.shared
        #if targetEnvironment(simulator)
        WatchSyncService.simulatesDelivery = true
        #endif
        let ready = await waitUntil(seconds: 120) {
            service.isActivated && service.isWatchAppInstalled && !Library.shared.allTracks.isEmpty
        }
        report("watch app installed, session active, library loaded", ready)
        guard ready, let album = await fixtureAlbum() else {
            report("the fixture album is in the library", false)
            return
        }
        report("the fixture album is in the library", true)
        let sourceBytes = service.sourceBytes(in: album)
        await deliver(album, through: service, expectingSmallerThan: sourceBytes)
        await removeAndVerify(album, through: service)
        await deliverOriginals(album, through: service)
        service.setProfile(.standard)
        removeFixture()
        await Library.shared.reload()
        MidgarLog.info("WatchSyncExercise finished", category: .connectivity)
    }

    private static let artistFolder = "Watch Exercise Artist"
    private static let albumFolder = "Watch Exercise Album"

    private static var fixtureDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(artistFolder, isDirectory: true)
    }

    /// Writes three 20 second 44.1 kHz stereo WAV files of tones and noise (a
    /// source AAC cannot shrink to nothing) and returns the album they form.
    private static func fixtureAlbum() async -> Album? {
        let directory = fixtureDirectory.appendingPathComponent(albumFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, name) in ["Tone A", "Tone B", "Tone C"].enumerated() {
            let url = directory.appendingPathComponent(String(format: "%02d %@.wav", index + 1, name))
            if !FileManager.default.fileExists(atPath: url.path) { writeTone(to: url, baseFrequency: 220 * Double(index + 1)) }
        }
        await Library.shared.reload()
        return Library.shared.albums.first { $0.title == albumFolder && $0.tracks.count == 3 }
    }

    private static func writeTone(to url: URL, baseFrequency: Double) {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44_100)
        else { return }
        for second in 0..<20 {
            fillToneSecond(buffer, second: second, baseFrequency: baseFrequency)
            try? file.write(from: buffer)
        }
    }

    private static func fillToneSecond(_ buffer: AVAudioPCMBuffer, second: Int, baseFrequency: Double) {
        let frames = Int(buffer.frameCapacity)
        buffer.frameLength = AVAudioFrameCount(frames)
        guard let channels = buffer.floatChannelData else { return }
        for frame in 0..<frames {
            let time = Double(second * frames + frame) / 44_100
            let tone = sin(2 * .pi * baseFrequency * time) * 0.3 + sin(2 * .pi * baseFrequency * 1.5 * time) * 0.2
            let noise = Double.random(in: -0.15...0.15)
            channels[0][frame] = Float(tone + noise)
            channels[1][frame] = Float(tone - noise)
        }
    }

    private static func removeFixture() {
        try? FileManager.default.removeItem(at: fixtureDirectory)
    }

    private static func deliver(_ album: Album, through service: WatchSyncService, expectingSmallerThan sourceBytes: Int64) async {
        service.setProfile(.high)
        let started = Date()
        service.sync(tracks: album.tracks)
        let delivered = await waitUntil(seconds: 300) { service.syncedCount(in: album) == album.tracks.count }
        report("album delivered in \(Int(Date().timeIntervalSince(started))) s", delivered)
        let used = service.watchUsedBytes
        report("watch holds fewer bytes than the originals (\(used) < \(sourceBytes))", used > 0 && used < sourceBytes)
        let idle = await waitUntil(seconds: 30) { !service.isSyncing }
        report("engine goes idle after delivery", idle)
        let sentBefore = service.sessionTotalBytesPending
        service.sync(tracks: album.tracks)
        try? await Task.sleep(for: .seconds(3))
        report("re-requesting delivered music sends nothing", !service.isSyncing && sentBefore == 0)
    }

    private static func removeAndVerify(_ album: Album, through service: WatchSyncService) async {
        service.remove(tracks: album.tracks)
        let emptied = await waitUntil(seconds: 120) { service.syncedCount(in: album) == 0 }
        report("album removed from the watch", emptied)
    }

    private static func deliverOriginals(_ album: Album, through service: WatchSyncService) async {
        service.setProfile(.original)
        service.sync(tracks: album.tracks)
        let delivered = await waitUntil(seconds: 300) { service.syncedCount(in: album) == album.tracks.count }
        report("original quality delivered", delivered)
        let sourceBytes = service.sourceBytes(in: album)
        let used = service.watchUsedBytes
        report("original quality ships the files untouched (\(used) vs \(sourceBytes))", used >= sourceBytes)
        service.remove(tracks: album.tracks)
        _ = await waitUntil(seconds: 120) { service.syncedCount(in: album) == 0 }
    }

    private static func waitUntil(seconds: Int, _ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<(seconds * 2) {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return condition()
    }

    private static func report(_ expectation: String, _ passed: Bool) {
        MidgarLog.info("WatchSyncExercise \(passed ? "PASS" : "FAIL"): \(expectation)", category: .connectivity)
    }
}
#endif
