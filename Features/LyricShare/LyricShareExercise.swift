import MidgarCore
#if DEBUG
import AVFoundation
import CoreGraphics
import FlaccyCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders and exports lyric clips through the real renderer and encoder and
/// logs PASS/FAIL per expectation: the audio of a FLAC is read for the chosen
/// lines, every template draws its frames, and the exported MP4 has a video
/// track of the format's size and an audio track as long as the clip. Pass
/// the song with `--lyric-share-audio <path>` (a 20 s tone if absent) and
/// launch with `--exercise-lyric-share`; the frames land in the app's
/// tmp/lyric-share-exercise folder, named in the log.
@MainActor
enum LyricShareExercise {

    static let launchArgument = "--exercise-lyric-share"

    static let fixture = """
        [00:01.00]<00:01.00>Neon <00:01.40>rivers <00:01.90>running <00:02.60>through <00:03.00>the <00:03.20>night
        [00:04.00]<00:04.00>We <00:04.30>were <00:04.60>the <00:04.80>signal <00:05.60>in <00:05.80>the <00:06.00>static<00:07.20>
        [00:07.40]Hold on, hold on to the sound
        [00:10.20]<00:10.20>Every <00:10.70>heartbeat <00:11.60>turning <00:12.30>up <00:12.70>the <00:13.00>volume<00:14.40>
        [00:15.00](hold on)
        """

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }
        Task { await run() }
    }

    private static func run() async {
        try? await Task.sleep(for: .seconds(2))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("lyric-share-exercise", isDirectory: true)
        try? FileManager.default.removeItem(at: output)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        MidgarLog.info("LyricShareExercise output: \(output.path)", category: .content)
        let source = argument(after: "--lyric-share-audio").map(URL.init(fileURLWithPath:)) ?? writeTone(in: output)
        guard let source else {
            report("a source song exists", false)
            return
        }
        let document = LyricsParser.parseLRC(fixture)
        report("the fixture has word timing", document.hasWordSync)
        guard let selection = LyricShareClip.defaultSelection(in: document, at: 1.2) else {
            report("a default selection exists", false)
            return
        }
        let window = LyricShareClip.window(for: selection, in: document, offset: 0, trackDuration: 20)
        let artwork = makeArtwork()
        let samples = artwork.map(LyricShareArtwork.samples) ?? []
        let started = Date()
        let audio: LyricShareClipAudio
        do {
            audio = try await Task.detached { try LyricShareAudio.load(url: source, window: window) }.value
        } catch {
            report("the audio is read (\(error))", false)
            return
        }
        report("the audio is read at an AAC rate (\(audio.sampleRate))", audio.sampleRate == 44_100 || audio.sampleRate == 48_000)
        report("the audio is as long as the clip (\(audio.duration) vs \(window.duration))", abs(audio.duration - window.duration) < 0.05)
        let analysis = LyricShareSpectrum.analyze(
            mono: audio.mono, sampleRate: audio.sampleRate, frames: LyricShareClip.frameCount(window), fps: LyricShareClip.fps)
        report("the visualizer moves", (analysis.levels.max() ?? 0) > 0.3)

        func scene(_ style: LyricShareStyle) -> LyricShareScene {
            LyricShareScene(
                document: document, selection: selection, plainLines: nil, window: window, style: style,
                palette: LyricSharePalette.make(theme: style.theme, samples: samples),
                title: "Parallax Hours", artist: "The Midnight Signal", artwork: artwork, analysis: analysis)
        }

        let probes = [12, 75, 130, 200]
        for template in LyricShareTemplate.allCases {
            for (format, theme) in [(LyricShareFormat.story, LyricShareTheme.artwork), (.square, .vivid), (.wide, .dark), (.portrait, .light)] {
                let style = LyricShareStyle(template: template, format: format, theme: theme)
                let renderer = LyricShareRenderer(scene: scene(style), scale: format == .story ? 0.5 : 0.4)
                var drawn = 0
                for frame in probes where frame < scene(style).frameCount {
                    if let image = renderer.image(frame: frame) {
                        save(image, to: output.appendingPathComponent("\(template.rawValue)-\(format.rawValue)-\(frame).png"))
                        drawn += 1
                    }
                }
                if let still = renderer.image(frame: nil) {
                    save(still, to: output.appendingPathComponent("\(template.rawValue)-\(format.rawValue)-still.png"))
                    drawn += 1
                }
                report("\(template.rawValue) \(format.rawValue) draws its frames", drawn == probes.count + 1)
            }
        }

        let video = output.appendingPathComponent("spotlight-story.mp4")
        let exportScene = scene(LyricShareStyle())
        let encodeStart = Date()
        do {
            try await Task.detached {
                try LyricShareExporter.exportVideo(scene: exportScene, audio: audio, to: video, isCancelled: { false }, progress: { _ in })
            }.value
        } catch {
            report("the video is written (\(error))", false)
            return
        }
        let seconds = Date().timeIntervalSince(encodeStart)
        MidgarLog.info("LyricShareExercise encoded \(exportScene.frameCount) frames in \(String(format: "%.1f", seconds)) s", category: .content)
        let asset = AVURLAsset(url: video)
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let size = try? await videoTracks.first?.load(.naturalSize)
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        report("the MP4 has one video and one audio track", videoTracks.count == 1 && audioTracks.count == 1)
        report("the video is 1080×1920 (\(String(describing: size)))", size == CGSize(width: 1080, height: 1920))
        report("the MP4 is as long as the clip (\(duration) vs \(window.duration))", abs(duration - window.duration) < 0.1)
        let cancelled = output.appendingPathComponent("cancelled.mp4")
        let cancelOutcome: Bool = await Task.detached {
            do {
                try LyricShareExporter.exportVideo(scene: exportScene, audio: audio, to: cancelled, isCancelled: { true }, progress: { _ in })
                return false
            } catch let failure as LyricShareExportFailure {
                return failure == .cancelled
            } catch {
                return false
            }
        }.value
        report("a cancelled export stops with .cancelled", cancelOutcome)
        let image = output.appendingPathComponent("card.png")
        do {
            try LyricShareExporter.exportImage(scene: exportScene, to: image)
            report("the still card is written", FileManager.default.fileExists(atPath: image.path))
        } catch {
            report("the still card is written (\(error))", false)
        }
        MidgarLog.info("LyricShareExercise finished in \(String(format: "%.1f", Date().timeIntervalSince(started))) s", category: .content)
    }

    private static func argument(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// Twenty seconds of a chord over a kick on every beat, at 48 kHz.
    private static func writeTone(in directory: URL) -> URL? {
        let rate = 48_000.0
        let frames = AVAudioFrameCount(rate * 20)
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
            let hat = beat > 0.25 && beat < 0.27 ? Double.random(in: -0.2...0.2) : 0
            channels[0][index] = Float(kick + chord + hat)
            channels[1][index] = Float(kick + chord * 0.8 + hat)
        }
        let url = directory.appendingPathComponent("tone.caf")
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            return url
        } catch {
            return nil
        }
    }

    private static func makeArtwork() -> CGImage? {
        guard let context = LyricShareRenderer.makeContext(width: 600, height: 600) else { return nil }
        let colors = [
            CGColor(srgbRed: 0.95, green: 0.35, blue: 0.45, alpha: 1),
            CGColor(srgbRed: 0.2, green: 0.1, blue: 0.5, alpha: 1),
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 600, y: 600), options: [])
        }
        context.setFillColor(CGColor(srgbRed: 1, green: 0.85, blue: 0.3, alpha: 1))
        context.fillEllipse(in: CGRect(x: 180, y: 180, width: 240, height: 240))
        return context.makeImage()
    }

    private static func save(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private static func report(_ expectation: String, _ passed: Bool) {
        MidgarLog.info("LyricShareExercise \(passed ? "PASS" : "FAIL"): \(expectation)", category: .content)
    }
}
#endif
