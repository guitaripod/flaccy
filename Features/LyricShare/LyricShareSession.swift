import AVFoundation
import CoreGraphics
import FlaccyCore
import Foundation
import os
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// One lyric clip being put together: the song, its lyrics, the chosen lines
/// and look, and the decoded stretch of audio they play over. Shared by the
/// iPhone sheet and the Mac window.
final class LyricShareSession {

    static let styleDefaultsKey = "lyricShare.style"
    /// How long a change of lines waits before the audio is read again, so a
    /// run of taps reads it once.
    static let reloadDelay: Duration = .milliseconds(250)

    let title: String
    let artist: String
    let fileURL: URL
    let trackDuration: Double
    let lyrics: Lyrics
    let artwork: CGImage?
    let plainLines: [String]?
    private let samples: [LyricShareColor]

    var style: LyricShareStyle {
        didSet {
            UserDefaults.standard.set(style.encoded, forKey: Self.styleDefaultsKey)
            onChange?()
        }
    }
    private(set) var selection: LyricShareSelection
    private(set) var plainStart: Double
    private(set) var audio: LyricShareClipAudio?
    private(set) var analysis = LyricShareAnalysis(bands: [], levels: [])
    private(set) var audioFailure: LyricShareAudioFailure?
    private(set) var isLoadingAudio = false
    private(set) var previewURL: URL?
    var onChange: (() -> Void)?
    var onAudioChange: (() -> Void)?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0

    /// Nil when there is nothing to share: no lines, only an instrumental.
    init?(
        title: String, artist: String, fileURL: URL, trackDuration: Double, lyrics: Lyrics,
        artwork: PlatformImage?, playbackTime: Double?, startingAt line: Int? = nil
    ) {
        let document = lyrics.document
        let lyricTime = playbackTime.map { lyrics.songTime(at: $0) }
        if document.hasSynced {
            guard var chosen = LyricShareClip.defaultSelection(in: document, at: lyricTime) else { return nil }
            if let line, LyricShareClip.isSelectable(line, in: document) {
                chosen = LyricShareClip.defaultSelection(in: document, at: document.lines[line].start) ?? chosen
            }
            selection = chosen
            plainLines = nil
            plainStart = 0
        } else if let plain = document.plain {
            let lines = LyricShareClip.plainLines(plain)
            guard let chosen = LyricShareClip.defaultPlainSelection(lines: lines) else { return nil }
            selection = chosen
            plainLines = lines
            plainStart = playbackTime ?? trackDuration * 0.3
        } else {
            return nil
        }
        self.title = title
        self.artist = artist
        self.fileURL = fileURL
        self.trackDuration = trackDuration
        self.lyrics = lyrics
        let image = artwork.flatMap(Self.cgImage)
        self.artwork = image
        samples = image.map(LyricShareArtwork.samples) ?? []
        style = LyricShareStyle(encoded: UserDefaults.standard.string(forKey: Self.styleDefaultsKey) ?? "")
    }

    deinit {
        loadTask?.cancel()
        if let previewURL {
            try? FileManager.default.removeItem(at: previewURL)
        }
    }

    var isTimed: Bool {
        plainLines == nil
    }

    /// The rows the line picker lists: every line of the song for synced
    /// lyrics, interludes shown as a note, or the plain lines.
    var pickerLines: [String] {
        plainLines ?? lyrics.document.lines.map { $0.isInterlude ? "\u{266A}" : $0.text }
    }

    func isPickable(_ index: Int) -> Bool {
        if let plainLines { return plainLines.indices.contains(index) }
        return LyricShareClip.isSelectable(index, in: lyrics.document)
    }

    var window: LyricShareWindow {
        if isTimed {
            return LyricShareClip.window(
                for: selection, in: lyrics.document, offset: lyrics.offsetSeconds, trackDuration: trackDuration)
        }
        return LyricShareClip.plainWindow(start: plainStart, trackDuration: trackDuration)
    }

    func palette(for theme: LyricShareTheme) -> LyricSharePalette {
        LyricSharePalette.make(theme: theme, samples: samples)
    }

    func scene() -> LyricShareScene {
        LyricShareScene(
            document: lyrics.document, selection: selection, plainLines: plainLines, window: window,
            style: style, palette: palette(for: style.theme), title: title, artist: artist,
            artwork: artwork, analysis: analysis)
    }

    func toggle(line index: Int) {
        let next = plainLines.map { LyricShareClip.togglePlain(selection, line: index, count: $0.count) }
            ?? LyricShareClip.toggle(selection, line: index, in: lyrics.document)
        guard next != selection else { return }
        selection = next
        onChange?()
        reloadAudio()
    }

    func setPlainStart(_ start: Double) {
        plainStart = max(0, min(start, max(trackDuration - LyricShareClip.plainDuration, 0)))
        onChange?()
        reloadAudio(after: Self.reloadDelay)
    }

    /// Reads the window's audio again off the main thread: the file itself,
    /// or the cached copy of a song on a server, downloading it whole first
    /// when only part of it has been streamed.
    func reloadAudio(after delay: Duration = .zero) {
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        let window = window
        let url = fileURL
        isLoadingAudio = true
        audioFailure = nil
        onAudioChange?()
        loadTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            let result = await Self.readClip(url: url, window: window)
            guard let self, !Task.isCancelled, generation == self.loadGeneration else { return }
            self.isLoadingAudio = false
            switch result {
            case .success(let loaded):
                if let old = self.previewURL, old != loaded.preview {
                    try? FileManager.default.removeItem(at: old)
                }
                self.audio = loaded.audio
                self.analysis = loaded.analysis
                self.previewURL = loaded.preview
            case .failure(let failure):
                self.audio = nil
                self.analysis = LyricShareAnalysis(bands: [], levels: [])
                self.audioFailure = failure
            }
            self.onAudioChange?()
        }
    }

    private struct LoadedClip: Sendable {
        let audio: LyricShareClipAudio
        let analysis: LyricShareAnalysis
        let preview: URL?
    }

    nonisolated private static func readClip(url: URL, window: LyricShareWindow) async -> Result<LoadedClip, LyricShareAudioFailure> {
        let file: URL
        if let readable = RemoteStreamCache.shared.readableFile(for: url) {
            file = readable
        } else if let song = RemoteTrackPath(assetURL: url) {
            do {
                file = try await RemoteStreamCache.shared.downloadComplete(song)
            } catch {
                return .failure(.notDownloaded)
            }
        } else {
            return .failure(.unreadable(url.lastPathComponent))
        }
        return await Task.detached(priority: .userInitiated) { () -> Result<LoadedClip, LyricShareAudioFailure> in
            do {
                let audio = try LyricShareAudio.load(url: file, window: window)
                let analysis = LyricShareSpectrum.analyze(
                    mono: audio.mono, sampleRate: audio.sampleRate,
                    frames: LyricShareClip.frameCount(window), fps: LyricShareClip.fps)
                let preview = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lyric-preview-\(UUID().uuidString).caf")
                let written = (try? LyricShareAudio.writePreview(audio, to: preview)) != nil
                return .success(LoadedClip(audio: audio, analysis: analysis, preview: written ? preview : nil))
            } catch let failure as LyricShareAudioFailure {
                return .failure(failure)
            } catch {
                return .failure(.unreadable(error.localizedDescription))
            }
        }.value
    }

    /// Makes the video, or the still card when `video` is false, off the
    /// main thread. `cancel` stops a video between frames.
    func export(
        video: Bool, cancel: LyricShareCancelFlag, progress: @escaping @MainActor (Double) -> Void
    ) async -> Result<URL, LyricShareExportFailure> {
        let scene = scene()
        let audio = audio
        let url = exportURL(fileExtension: video ? "mp4" : "png")
        return await Task.detached(priority: .userInitiated) { () -> Result<URL, LyricShareExportFailure> in
            do {
                if video, let audio {
                    try LyricShareExporter.exportVideo(
                        scene: scene, audio: audio, to: url, isCancelled: { cancel.isSet },
                        progress: { value in Task { @MainActor in progress(value) } })
                } else if video {
                    return .failure(.writer("no audio"))
                } else {
                    try LyricShareExporter.exportImage(scene: scene, to: url)
                }
                return .success(url)
            } catch let failure as LyricShareExportFailure {
                return .failure(failure)
            } catch {
                return .failure(.writer(error.localizedDescription))
            }
        }.value
    }

    /// Where the finished video or image is written before it is shared.
    func exportURL(fileExtension: String) -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LyricShare", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(
            LyricShareNaming.fileName(title: title, artist: artist, fileExtension: fileExtension))
    }

    private static func cgImage(_ image: PlatformImage) -> CGImage? {
        #if canImport(UIKit)
        return image.cgImage
        #else
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }
}

extension LyricShareSession {

    /// A session for the song playing now, from the lyrics a view already
    /// holds or the stored ones, opening on `line` when one was picked.
    static func forCurrentTrack(lyrics: Lyrics? = nil, line: Int? = nil) -> LyricShareSession? {
        guard let track = AudioPlayer.shared.currentTrack,
              let lyrics = lyrics ?? LyricsService.shared.cachedLyrics(track: track.title, artist: track.artist)
        else { return nil }
        let artwork = track.artwork ?? AlbumArtworkCache.shared.artwork(forAlbum: track.albumTitle, artist: track.artist)
        let duration = track.duration > 0 ? track.duration : AudioPlayer.shared.duration
        return LyricShareSession(
            title: track.title, artist: track.artist, fileURL: track.fileURL, trackDuration: duration,
            lyrics: lyrics, artwork: artwork, playbackTime: AudioPlayer.shared.currentTime, startingAt: line)
    }
}

/// A stop request a running export checks between frames.
nonisolated final class LyricShareCancelFlag: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)

    var isSet: Bool {
        flag.withLock { $0 }
    }

    func set() {
        flag.withLock { $0 = true }
    }
}

/// Plays the clip's audio on a loop for the preview, pausing the song for as
/// long as it plays and resuming it afterwards.
final class LyricSharePreviewPlayer {

    private var player: AVAudioPlayer?
    private var pausedSong = false

    var isPlaying: Bool {
        player?.isPlaying ?? false
    }

    var currentTime: Double {
        player?.currentTime ?? 0
    }

    func load(_ url: URL?) {
        let wasPlaying = isPlaying
        player?.stop()
        player = url.flatMap { try? AVAudioPlayer(contentsOf: $0) }
        player?.numberOfLoops = -1
        player?.prepareToPlay()
        if wasPlaying {
            player?.play()
        }
    }

    func play() {
        guard let player else { return }
        if AudioPlayer.shared.isPlaying {
            AudioPlayer.shared.togglePlayPause()
            pausedSong = true
        }
        player.play()
    }

    func pause() {
        player?.pause()
    }

    /// Stops the preview and gives the song back if the preview paused it.
    func stop() {
        player?.stop()
        player = nil
        if pausedSong, !AudioPlayer.shared.isPlaying {
            AudioPlayer.shared.togglePlayPause()
        }
        pausedSong = false
    }
}
