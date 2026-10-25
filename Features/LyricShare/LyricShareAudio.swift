import AVFoundation
import FlaccyCore
import Foundation

/// Why a clip's audio could not be read.
nonisolated enum LyricShareAudioFailure: Error, Equatable {
    case unreadable(String)
    case outOfRange
    case notDownloaded
}

/// A clip's stretch of the song, faded in and out and ready to encode:
/// interleaved stereo floats at an AAC-friendly rate, and a mono mix of the
/// same for the visualizer.
nonisolated struct LyricShareClipAudio: Sendable {
    var interleaved: [Float]
    var mono: [Float]
    var sampleRate: Double

    var frameCount: Int {
        interleaved.count / 2
    }

    var duration: Double {
        Double(frameCount) / sampleRate
    }
}

nonisolated enum LyricShareAudio {

    /// AAC's own rates: the CD family stays at 44.1 kHz, everything else
    /// goes to 48 kHz.
    static func targetRate(for sourceRate: Double) -> Double {
        let ratio = sourceRate / 44_100
        return abs(ratio - ratio.rounded()) < 1e-6 ? 44_100 : 48_000
    }

    /// Reads the window's stretch of the file, mixes it to stereo at the
    /// target rate and applies the clip's fades.
    static func load(url: URL, window: LyricShareWindow) throws -> LyricShareClipAudio {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw LyricShareAudioFailure.unreadable(error.localizedDescription)
        }
        let source = file.processingFormat
        let rate = source.sampleRate
        let startFrame = AVAudioFramePosition((window.audioStart * rate).rounded(.down))
        guard startFrame >= 0, startFrame < file.length else { throw LyricShareAudioFailure.outOfRange }
        let wanted = AVAudioFrameCount(min((window.duration * rate).rounded(.up), Double(file.length - startFrame)))
        guard wanted > 0, let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: wanted) else {
            throw LyricShareAudioFailure.outOfRange
        }
        do {
            file.framePosition = startFrame
            try file.read(into: input, frameCount: wanted)
        } catch {
            throw LyricShareAudioFailure.unreadable(error.localizedDescription)
        }
        let target = targetRate(for: rate)
        let channels: AVAudioChannelCount = source.channelCount >= 2 ? 2 : 1
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target, channels: channels, interleaved: false),
              let converter = AVAudioConverter(from: source, to: format)
        else { throw LyricShareAudioFailure.unreadable("conversion") }
        converter.downmix = source.channelCount > 2
        let capacity = AVAudioFrameCount((Double(input.frameLength) * target / rate).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw LyricShareAudioFailure.unreadable("conversion")
        }
        nonisolated(unsafe) var supplied = false
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, state in
            if supplied {
                state.pointee = .endOfStream
                return nil
            }
            supplied = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, let data = output.floatChannelData else {
            throw LyricShareAudioFailure.unreadable(failure?.localizedDescription ?? "conversion")
        }
        let frames = Int(output.frameLength)
        let left = data[0]
        let right = channels == 2 ? data[1] : data[0]
        var interleaved = [Float](repeating: 0, count: frames * 2)
        var mono = [Float](repeating: 0, count: frames)
        let duration = Double(frames) / target
        for index in 0..<frames {
            let gain = Float(LyricShareClip.gain(at: Double(index) / target, duration: duration))
            let l = left[index] * gain
            let r = right[index] * gain
            interleaved[index * 2] = l
            interleaved[index * 2 + 1] = r
            mono[index] = (left[index] + right[index]) * 0.5
        }
        return LyricShareClipAudio(interleaved: interleaved, mono: mono, sampleRate: target)
    }

    /// The clip as a CAF file the preview player can loop.
    static func writePreview(_ audio: LyricShareClipAudio, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: audio.sampleRate, channels: 2, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.frameCount)),
              let channels = buffer.floatChannelData
        else { throw LyricShareAudioFailure.unreadable("preview") }
        buffer.frameLength = AVAudioFrameCount(audio.frameCount)
        for index in 0..<audio.frameCount {
            channels[0][index] = audio.interleaved[index * 2]
            channels[1][index] = audio.interleaved[index * 2 + 1]
        }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
