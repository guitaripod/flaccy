import MidgarCore
#if DEBUG
import AppKit
import AVFoundation
import FlaccyCore

extension DebugDrive {

    /// Starts the hero track, opens the lyric share window for it, waits for
    /// the clip's audio and captures the window as it opens, mid-preview in
    /// the Verse template, and as a square poster.
    static func driveLyricShare(window: NSWindow?) async {
        startHeroPlayback()
        guard let session = shotSession() else {
            MidgarLog.error("DebugDrive: lyric share has no lyrics for the playing track", category: .general)
            return
        }
        session.style = LyricShareStyle()
        let controller = LyricShareWindowController.present(session, from: window)
        try? await Task.sleep(for: .seconds(4))
        MidgarLog.info(
            "DebugDrive: lyric share audio loaded=\(session.audio != nil) failure=\(String(describing: session.audioFailure))",
            category: .general)
        captureLyricShare(controller, parent: window, name: "flaccy-shot-lyric-share")

        session.style.template = .verse
        controller.content.togglePreview()
        try? await Task.sleep(for: .seconds(1.5))
        captureLyricShare(controller, parent: window, name: "flaccy-shot-lyric-share-verse-playing")
        controller.content.togglePreview()

        session.style.template = .poster
        session.style.format = .square
        session.style.theme = .vivid
        try? await Task.sleep(for: .seconds(1))
        captureLyricShare(controller, parent: window, name: "flaccy-shot-lyric-share-poster-square")
        controller.dismiss()
    }

    /// The session for the playing track, reading its audio from a generated
    /// tone: the seeded library's files are not real audio.
    private static func shotSession() -> LyricShareSession? {
        guard let track = AudioPlayer.shared.currentTrack,
              let lyrics = LyricsService.shared.cachedLyrics(track: track.title, artist: track.artist),
              let tone = writeShotTone(seconds: track.duration)
        else { return nil }
        return LyricShareSession(
            title: track.title, artist: track.artist, fileURL: tone, trackDuration: track.duration, lyrics: lyrics,
            artwork: track.artwork ?? AlbumArtworkCache.shared.artwork(forAlbum: track.albumTitle, artist: track.artist),
            playbackTime: AudioPlayer.shared.currentTime)
    }

    /// A chord over a kick on every beat, long enough to cover the track.
    private static func writeShotTone(seconds: TimeInterval) -> URL? {
        let rate = 48_000.0
        let frames = AVAudioFrameCount(rate * max(seconds, 90))
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            let time = Double(index) / rate
            let beat = time.truncatingRemainder(dividingBy: 0.5)
            let kick = exp(-beat * 18) * sin(2 * .pi * 55 * beat) * 0.6
            let chord = (sin(2 * .pi * 220 * time) + sin(2 * .pi * 277.2 * time) + sin(2 * .pi * 329.6 * time)) * 0.08
            channels[0][index] = Float(kick + chord)
            channels[1][index] = Float(kick + chord * 0.8)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lyric-share-shot-tone.caf")
        do {
            try? FileManager.default.removeItem(at: url)
            try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
            return url
        } catch {
            MidgarLog.error("DebugDrive: shot tone failed: \(error.localizedDescription)", category: .general)
            return nil
        }
    }

    private static func captureLyricShare(_ controller: LyricShareWindowController, parent: NSWindow?, name: String) {
        if parent?.sheets.isEmpty == false {
            captureSheet(of: parent, name: name)
        } else {
            capture(window: controller.window, name: name)
        }
    }
}
#endif
