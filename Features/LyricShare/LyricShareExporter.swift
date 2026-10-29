import AVFoundation
import CoreGraphics
import CoreVideo
import FlaccyCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Why a clip could not be made.
nonisolated enum LyricShareExportFailure: Error, Equatable {
    case cancelled
    case writer(String)
    case image
}

/// Turns a scene and its audio into an H.264 + AAC MP4, or the still card
/// into a PNG. Runs off the main thread; `progress` reports 0 to 1.
nonisolated enum LyricShareExporter {

    static func videoBitRate(_ format: LyricShareFormat) -> Int {
        format.pixelWidth * format.pixelHeight * 5
    }

    static let audioBitRate = 256_000
    static let audioChunk = 4096

    static func exportVideo(
        scene: LyricShareScene, audio: LyricShareClipAudio, to url: URL,
        isCancelled: @Sendable () -> Bool, progress: @Sendable (Double) -> Void
    ) throws {
        try? FileManager.default.removeItem(at: url)
        let renderer = LyricShareRenderer(scene: scene)
        let width = renderer.pixelWidth
        let height = renderer.pixelHeight
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw LyricShareExportFailure.writer(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = true
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitRate(scene.style.format),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: LyricShareClip.fps * 2,
                AVVideoExpectedSourceFrameRateKey: LyricShareClip.fps,
            ],
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ])
        let sound = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: audio.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: audioBitRate,
        ])
        sound.expectsMediaDataInRealTime = false
        guard writer.canAdd(video), writer.canAdd(sound) else { throw LyricShareExportFailure.writer("inputs") }
        writer.add(video)
        writer.add(sound)
        guard writer.startWriting() else {
            throw LyricShareExportFailure.writer(writer.error?.localizedDescription ?? "start")
        }
        writer.startSession(atSourceTime: .zero)
        guard let format = audioFormat(sampleRate: audio.sampleRate) else { throw LyricShareExportFailure.writer("audio format") }

        let frames = scene.frameCount
        let fps = Double(LyricShareClip.fps)
        var frame = 0
        var cursor = 0
        while frame < frames || cursor < audio.frameCount {
            if isCancelled() {
                writer.cancelWriting()
                throw LyricShareExportFailure.cancelled
            }
            if writer.status == .failed {
                throw LyricShareExportFailure.writer(writer.error?.localizedDescription ?? "write")
            }
            let videoTime = Double(frame) / fps
            let audioTime = Double(cursor) / audio.sampleRate
            let audioDone = cursor >= audio.frameCount
            if frame < frames, video.isReadyForMoreMediaData, audioDone || videoTime <= audioTime + 0.5 {
                guard let pool = adaptor.pixelBufferPool else { throw LyricShareExportFailure.writer("pool") }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { throw LyricShareExportFailure.writer("pixel buffer") }
                draw(frame: frame, with: renderer, into: buffer)
                if !adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(LyricShareClip.fps))) {
                    throw LyricShareExportFailure.writer(writer.error?.localizedDescription ?? "video")
                }
                frame += 1
                progress(Double(frame) / Double(frames))
            } else if !audioDone, sound.isReadyForMoreMediaData {
                let count = min(audioChunk, audio.frameCount - cursor)
                guard let sample = audioSample(audio, from: cursor, count: count, format: format) else {
                    throw LyricShareExportFailure.writer("audio buffer")
                }
                if !sound.append(sample) {
                    throw LyricShareExportFailure.writer(writer.error?.localizedDescription ?? "audio")
                }
                cursor += count
                if cursor >= audio.frameCount {
                    sound.markAsFinished()
                }
            } else {
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        video.markAsFinished()
        if cursor < audio.frameCount || audio.frameCount == 0 {
            sound.markAsFinished()
        }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw LyricShareExportFailure.writer(writer.error?.localizedDescription ?? "finish")
        }
    }

    static func exportImage(scene: LyricShareScene, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard let image = LyricShareRenderer(scene: scene).image(frame: nil),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw LyricShareExportFailure.image }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw LyricShareExportFailure.image }
    }

    private static func draw(frame: Int, with renderer: LyricShareRenderer, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = LyricShareRenderer.makeContext(
            width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
            data: CVPixelBufferGetBaseAddress(buffer), bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
        else { return }
        renderer.render(frame: frame, into: context)
    }

    private static func audioFormat(sampleRate: Double) -> CMAudioFormatDescription? {
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        return format
    }

    private static func audioSample(_ audio: LyricShareClipAudio, from start: Int, count: Int, format: CMAudioFormatDescription) -> CMSampleBuffer? {
        let bytes = count * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block) == kCMBlockBufferNoErr, let block
        else { return nil }
        let copied = audio.interleaved.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base + start * 8, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var sample: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: count,
            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(audio.sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sample)
        return status == noErr ? sample : nil
    }
}
