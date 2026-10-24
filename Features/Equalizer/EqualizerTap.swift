import AVFoundation
import AudioToolbox
import FlaccyCore
import MediaToolbox
import os

/// The curve the render threads should be running, published by the engine and
/// read by every tap. Immutable once built; a new profile is a new value with a
/// higher `version`.
nonisolated final class EqualizerConfig: @unchecked Sendable {
    let version: UInt64
    let isEngaged: Bool
    let bands: [EqualizerBand]
    let preampDecibels: Double
    let peakGuard: Bool

    init(version: UInt64, isEngaged: Bool, bands: [EqualizerBand], preampDecibels: Double, peakGuard: Bool) {
        self.version = version
        self.isEngaged = isEngaged
        self.bands = bands
        self.preampDecibels = preampDecibels
        self.peakGuard = peakGuard
    }
}

/// Where the engine leaves the current config for the render threads. A render
/// thread only ever tries the lock: if the main thread happens to hold it, that
/// callback keeps the config it already has and picks the new one up on the next.
nonisolated final class EqualizerConfigBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<EqualizerConfig>(
        initialState: EqualizerConfig(version: 0, isEngaged: false, bands: [], preampDecibels: 0, peakGuard: true)
    )

    func write(_ config: EqualizerConfig) {
        lock.withLock { $0 = config }
    }

    func tryRead() -> EqualizerConfig? {
        lock.withLockIfAvailable { $0 }
    }

    func read() -> EqualizerConfig {
        lock.withLock { $0 }
    }

    /// The time of the most recent render callback of any tap. A single aligned
    /// word written by the render thread and read by diagnostics, so a stale
    /// read is harmless.
    let renderTick: UnsafeMutablePointer<UInt64> = {
        let pointer = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        pointer.initialize(to: 0)
        return pointer
    }()
}

/// What the screens read back from the audio thread: how loud the output is,
/// whether the guard is acting, and the latest mono samples for the spectrum.
nonisolated struct EqualizerMeter: Equatable, Sendable {
    var peak: Float
    var guardReduced: Bool
}

/// One tap's state: its kernel, the buffers it needs, and the bookkeeping that
/// tells the engine which tap is the one currently making sound.
nonisolated final class EqualizerTapContext: @unchecked Sendable {
    let box: EqualizerConfigBox
    let startsEngaged: Bool
    private let kernelSlot = OSAllocatedUnfairLock<EqualizerKernel?>(initialState: nil)
    private(set) var lastProcessTick: UInt64 = 0
    private(set) var framesProcessed: UInt64 = 0
    private(set) var sampleRate: Double = 0
    private(set) var channelCount = 0
    private(set) var supportsFormat = false

    private var planes: UnsafeMutablePointer<UnsafeMutablePointer<Float>>?
    private var isInterleaved = false
    private var appliedVersion: UInt64 = 0

    init(box: EqualizerConfigBox, startsEngaged: Bool) {
        self.box = box
        self.startsEngaged = startsEngaged
    }

    deinit {
        planes?.deallocate()
    }

    func prepare(format: AudioStreamBasicDescription) {
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let channels = Int(format.mChannelsPerFrame)
        supportsFormat = format.mFormatID == kAudioFormatLinearPCM && isFloat && format.mBitsPerChannel == 32 && channels >= 1 && channels <= 8
        sampleRate = format.mSampleRate
        channelCount = channels
        isInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        planes?.deallocate()
        planes = nil
        kernelSlot.withLock { $0 = nil }
        appliedVersion = 0
        guard supportsFormat else { return }
        planes = .allocate(capacity: channels)
        let kernel = EqualizerKernel(channelCount: channels, sampleRate: format.mSampleRate)
        applyConfig(box.read(), to: kernel, startsEngaged: startsEngaged)
        kernelSlot.withLock { $0 = kernel }
        EqualizerTapRegistry.shared.register(self)
    }

    func unprepare() {
        EqualizerTapRegistry.shared.unregister(self)
        kernelSlot.withLock { $0 = nil }
        planes?.deallocate()
        planes = nil
    }

    func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int, startOfStream: Bool) {
        guard supportsFormat, frames > 0, let planes, let kernel = kernelSlot.withLockIfAvailable({ $0 }).flatMap({ $0 }) else { return }
        if let config = box.tryRead(), config.version != appliedVersion {
            applyConfig(config, to: kernel)
        }
        if startOfStream { kernel.reset() }

        let list = UnsafeMutableAudioBufferListPointer(bufferList)
        let stride: Int
        if isInterleaved {
            guard list.count >= 1, let data = list[0].mData else { return }
            let base = data.assumingMemoryBound(to: Float.self)
            for channel in 0..<channelCount { planes[channel] = base + channel }
            stride = channelCount
        } else {
            guard list.count >= channelCount else { return }
            for channel in 0..<channelCount {
                guard let data = list[channel].mData else { return }
                planes[channel] = data.assumingMemoryBound(to: Float.self)
            }
            stride = 1
        }
        kernel.process(planes: UnsafePointer(planes), planeStride: stride, frames: frames)
        framesProcessed &+= UInt64(frames)
        let now = mach_absolute_time()
        lastProcessTick = now
        box.renderTick.pointee = now
    }

    func meter() -> EqualizerMeter? {
        kernelSlot.withLock { $0 }.map { EqualizerMeter(peak: $0.blockPeak, guardReduced: $0.guardReduced) }
    }

    func copyAnalysis(into output: UnsafeMutablePointer<Float>, count: Int) -> Bool {
        guard let kernel = kernelSlot.withLock({ $0 }) else { return false }
        kernel.copyAnalysis(into: output, count: count)
        return true
    }

    private func applyConfig(_ config: EqualizerConfig, to kernel: EqualizerKernel, startsEngaged: Bool = false) {
        kernel.configure(
            bands: config.bands,
            preampDecibels: config.preampDecibels,
            isEngaged: config.isEngaged,
            peakGuard: config.peakGuard,
            startsEngaged: startsEngaged
        )
        appliedVersion = config.version
    }
}

/// Every prepared tap, so the screens can find the one that is playing.
nonisolated final class EqualizerTapRegistry: @unchecked Sendable {
    static let shared = EqualizerTapRegistry()

    private let lock = OSAllocatedUnfairLock<[ObjectIdentifier: Weak]>(initialState: [:])

    private struct Weak {
        weak var context: EqualizerTapContext?
    }

    func register(_ context: EqualizerTapContext) {
        lock.withLock { $0[ObjectIdentifier(context)] = Weak(context: context) }
    }

    func unregister(_ context: EqualizerTapContext) {
        lock.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(context)) }
    }

    /// The tap that processed audio most recently, which is the one making sound.
    func playingContext() -> EqualizerTapContext? {
        lock.withLock { contexts in
            contexts.values.compactMap(\.context).max { $0.lastProcessTick < $1.lastProcessTick }
        }
    }

    var preparedCount: Int {
        lock.withLock { $0.values.compactMap(\.context).count }
    }
}

/// The C callbacks MediaToolbox wants, and the one place a tap is created.
nonisolated enum EqualizerTapFactory {

    /// `startsEngaged` is true for a tap on an item that has not begun playing,
    /// so the curve is in force from its first sample; a tap added under a song
    /// already playing fades in instead.
    static func makeTap(box: EqualizerConfigBox, startsEngaged: Bool) -> MTAudioProcessingTap? {
        let context = EqualizerTapContext(box: box, startsEngaged: startsEngaged)
        let retained = Unmanaged.passRetained(context)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retained.toOpaque(),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            retained.release()
            return nil
        }
        return tap
    }

    private static let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
        tapStorageOut.pointee = clientInfo
    }

    private static let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
        Unmanaged<EqualizerTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
    }

    private static let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
        let context = Unmanaged<EqualizerTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        context.prepare(format: format.pointee)
    }

    private static let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { tap in
        let context = Unmanaged<EqualizerTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        context.unprepare()
    }

    private static let tapProcess: MTAudioProcessingTapProcessCallback = { tap, frames, _, bufferList, framesOut, flagsOut in
        let status = MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut)
        guard status == noErr else { return }
        let context = Unmanaged<EqualizerTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        let startOfStream = flagsOut.pointee & MTAudioProcessingTapFlags(kMTAudioProcessingTapFlag_StartOfStream) != 0
        context.process(bufferList, frames: Int(framesOut.pointee), startOfStream: startOfStream)
    }
}
