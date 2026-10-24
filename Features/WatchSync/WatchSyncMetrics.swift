import Foundation

/// Smoothed throughput and time remaining for a watch sync run, sampled once a
/// second from the bytes the ledger says have moved.
final class WatchSyncMetrics {

    private(set) var speedBytesPerSec: Double = 0
    private(set) var etaSeconds: TimeInterval?
    private var lastSampleBytes: Int64 = 0
    private var lastSampleTime: Date?

    private static let minimumUsableSpeed: Double = 1_024
    private static let smoothing: Double = 0.4

    func start(transferredBytes: Int64, now: Date) {
        lastSampleBytes = transferredBytes
        lastSampleTime = now
    }

    func sample(transferredBytes: Int64, remainingBytes: Int64, now: Date) {
        if let last = lastSampleTime {
            let elapsed = now.timeIntervalSince(last)
            if elapsed > 0 {
                let instant = max(0, Double(transferredBytes - lastSampleBytes) / elapsed)
                speedBytesPerSec = speedBytesPerSec <= 0
                    ? instant
                    : speedBytesPerSec * (1 - Self.smoothing) + instant * Self.smoothing
            }
        }
        lastSampleBytes = transferredBytes
        lastSampleTime = now
        etaSeconds = speedBytesPerSec > Self.minimumUsableSpeed ? Double(remainingBytes) / speedBytesPerSec : nil
    }

    func reset() {
        speedBytesPerSec = 0
        etaSeconds = nil
        lastSampleBytes = 0
        lastSampleTime = nil
    }
}
