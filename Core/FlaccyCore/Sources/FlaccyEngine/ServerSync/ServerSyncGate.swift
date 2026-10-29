import Foundation

/// Tells the write paths of a database, without a query, whether a Flaccy Server is configured, and
/// where to announce that a write queued something to send.
///
/// A false flag is the whole cost of the recorder for a person with no server. The flag is a hint:
/// a true flag is confirmed against `sync_meta` inside the transaction that records.
public final class ServerSyncGate: @unchecked Sendable {

    private let lock = NSLock()
    private var configured: Bool
    private var recording: Bool
    private var recordedHandler: (@Sendable () -> Void)?
    private let clock: @Sendable () -> Int64

    init(configured: Bool, recording: Bool, clock: @escaping @Sendable () -> Int64 = ServerSyncGate.systemClock) {
        self.configured = configured
        self.recording = recording
        self.clock = clock
    }

    public static let systemClock: @Sendable () -> Int64 = {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    public var isConfigured: Bool {
        lock.withLock { configured }
    }

    func setConfigured(_ value: Bool) {
        lock.withLock { configured = value }
    }

    /// True once writes are being queued for the server: a server is connected and the account may write to it.
    var isRecording: Bool {
        lock.withLock { recording }
    }

    func setRecording(_ value: Bool) {
        lock.withLock { recording = value }
    }

    var nowMs: Int64 { clock() }

    /// Called after a write that queued mutations has committed. The engine uses it to schedule a push.
    public func onRecorded(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { recordedHandler = handler }
    }

    func announceRecorded() {
        let handler = lock.withLock { recordedHandler }
        handler?()
    }
}
