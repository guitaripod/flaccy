import FlaccyCore
import Foundation

/// The one gate every request to lrclib passes through, whether a lyrics view
/// or the background lane sends it: a pause between requests, and silence for
/// as long as the server asked for after a 429. lrclib bans by address, so the
/// two must not each keep their own count.
actor LyricsRequestGate {

    static let shared = LyricsRequestGate()

    /// lrclib asks identified clients to stay under about 90 requests a minute
    /// and library scans to leave 200 to 500 ms between requests.
    private static let gap: TimeInterval = 0.45

    private var gate = RequestGate(gap: gap)

    /// Waits for the next slot. False means the server asked for a quiet longer
    /// than `patience` still has to run, so nothing should be sent.
    func waitTurn(patience: TimeInterval) async -> Bool {
        switch gate.claim(now: Date(), patience: patience) {
        case .cooling:
            return false
        case .after(let wait):
            guard wait > 0 else { return true }
            do {
                try await Task.sleep(for: .seconds(wait))
                return true
            } catch {
                return false
            }
        }
    }

    func throttled(retryAfter: TimeInterval) {
        gate.throttled(now: Date(), retryAfter: retryAfter, jitter: .random(in: 0..<1))
    }

    func cooldownLeft() -> TimeInterval {
        gate.cooldownLeft(now: Date())
    }
}
