import Foundation

/// The whole phone-side record of what is on the watch and what is on its way.
///
/// The watch's heartbeat is the only authority on what it holds: `ingest`
/// overrides every transitional guess the phone has made. All time arrives as
/// a parameter, so every transition is deterministic.
public struct WatchSyncLedger: Sendable, Equatable {

    public struct Policy: Sendable, Equatable {
        public var maxInFlightCount: Int
        public var maxInFlightBytes: Int64
        public var backoffBase: TimeInterval
        public var backoffFactor: Double
        public var backoffCap: TimeInterval
        public var maxAttempts: Int
        public var ackGrace: TimeInterval

        public init(
            maxInFlightCount: Int = 4,
            maxInFlightBytes: Int64 = 150 * 1_024 * 1_024,
            backoffBase: TimeInterval = 20,
            backoffFactor: Double = 3,
            backoffCap: TimeInterval = 900,
            maxAttempts: Int = 8,
            ackGrace: TimeInterval = 120
        ) {
            self.maxInFlightCount = maxInFlightCount
            self.maxInFlightBytes = maxInFlightBytes
            self.backoffBase = backoffBase
            self.backoffFactor = backoffFactor
            self.backoffCap = backoffCap
            self.maxAttempts = maxAttempts
            self.ackGrace = ackGrace
        }

        public static let standard = Policy()
    }

    public enum Phase: Sendable, Equatable {
        case queued
        case preparing
        case sending(fraction: Double)
        case awaitingAck(since: Date)
        case onWatch
        case waiting(until: Date, attempts: Int)
        case diskFull
        case stuck(attempts: Int)
    }

    public enum Failure: Sendable, Equatable {
        case transient
        case diskFull
    }

    private struct Entry: Sendable, Equatable {
        var phase: Phase
        var bytes: Int64
        var sequence: Int
        var attempts: Int
        var isRequested: Bool
    }

    public let policy: Policy
    public private(set) var watchFreeBytes: Int64 = 0
    public private(set) var watchIsFull: Bool = false
    private var entries: [String: Entry] = [:]
    private var nextSequence = 0

    public init(requested: Set<String> = [], policy: Policy = .standard) {
        self.policy = policy
        for stem in requested.sorted() {
            insert(stem: stem, bytes: 0, phase: .queued, isRequested: true)
        }
    }

    /// The stems the person asked for and has not withdrawn; this is what to persist.
    public var requested: Set<String> {
        Set(entries.compactMap { $0.value.isRequested ? $0.key : nil })
    }

    public func phase(of stem: String) -> Phase? {
        entries[stem]?.phase
    }

    public func isOnWatch(_ stem: String) -> Bool {
        entries[stem]?.phase == .onWatch
    }

    public var syncedCount: Int { count { $0 == .onWatch } }
    public var inFlightCount: Int { count(\.isInFlight) }
    public var queuedCount: Int { count(\.isPendingStart) }
    public var awaitingAckCount: Int { count(\.isAwaitingAck) }
    public var stuckCount: Int { count(\.isStuck) }
    public var diskFullCount: Int { count { $0 == .diskFull } }

    public var unconfirmedCount: Int {
        entries.values.filter { $0.isRequested && $0.phase != .onWatch }.count
    }

    public var isBusy: Bool {
        entries.values.contains { $0.phase.isInFlight || $0.phase.isPendingStart || $0.phase.isAwaitingAck }
    }

    /// Progress over `stems`: delivered and acknowledged-pending tracks count
    /// whole, a track on the wire counts what has been sent, the rest nothing.
    public func fraction(of stems: [String]) -> Double {
        guard !stems.isEmpty else { return 0 }
        let total = stems.reduce(0.0) { $0 + progress(of: entries[$1]?.phase) }
        return total / Double(stems.count)
    }

    public mutating func request(_ items: [(stem: String, bytes: Int64)], now: Date) {
        for item in items {
            guard var entry = entries[item.stem] else {
                insert(stem: item.stem, bytes: item.bytes, phase: .queued, isRequested: true)
                continue
            }
            entry.isRequested = true
            entry.bytes = item.bytes
            if entry.phase.isRestartable {
                entry.phase = .queued
                entry.attempts = 0
            }
            entries[item.stem] = entry
        }
    }

    /// Corrects the size of a stem already in the ledger without touching its
    /// phase, attempts or place in line.
    public mutating func updateBytes(stem: String, bytes: Int64) {
        entries[stem]?.bytes = bytes
    }

    public mutating func withdraw(_ stems: [String]) {
        for stem in stems { entries[stem] = nil }
    }

    /// Claims the next stems to hand to the transport, honouring both budgets.
    /// Admission stops at the first stem that does not fit so request order is
    /// never overtaken; a stem larger than the byte budget still goes alone.
    public mutating func nextToStart(now: Date) -> [String] {
        var count = inFlightCount
        var bytes = inFlightBytes
        var started: [String] = []
        for (stem, entry) in startable(now: now) {
            guard count < policy.maxInFlightCount else { break }
            let isOnlyOne = count == 0
            guard isOnlyOne || bytes + entry.bytes <= policy.maxInFlightBytes else { break }
            count += 1
            bytes += entry.bytes
            started.append(stem)
        }
        for stem in started { entries[stem]?.phase = .preparing }
        return started
    }

    /// Puts a stem that was being prepared back in line without counting an
    /// attempt, for work that was interrupted rather than failed.
    public mutating func abandonPreparation(stem: String) {
        guard entries[stem]?.phase == .preparing else { return }
        entries[stem]?.phase = .queued
    }

    public mutating func markSending(stem: String, fraction: Double) {
        guard let phase = entries[stem]?.phase, phase.isInFlight else { return }
        entries[stem]?.phase = .sending(fraction: Self.clamped(fraction))
    }

    public mutating func markHandedOff(stem: String, now: Date) {
        guard let phase = entries[stem]?.phase, phase.isInFlight else { return }
        entries[stem]?.phase = .awaitingAck(since: now)
    }

    public mutating func markFailed(stem: String, failure: Failure, now: Date) {
        guard let entry = entries[stem], entry.phase != .onWatch else { return }
        switch failure {
        case .diskFull:
            entries[stem]?.phase = .diskFull
        case .transient:
            recordTransientFailure(stem: stem, now: now)
        }
    }

    /// Applies the watch heartbeat. Everything the watch confirms becomes
    /// `onWatch` and loses all in-progress state; everything the phone
    /// believed was on the watch but is not confirmed goes back in the queue.
    public mutating func ingest(confirmed: Set<String>, watchFreeBytes: Int64, watchIsFull: Bool, now: Date) {
        self.watchFreeBytes = watchFreeBytes
        self.watchIsFull = watchIsFull
        for stem in confirmed.sorted() { confirm(stem) }
        for stem in entries.keys.sorted() where !confirmed.contains(stem) {
            reconcileUnconfirmed(stem: stem, now: now)
        }
    }

    /// Takes over a transfer the system was still carrying from a previous
    /// launch. Returns whether the stem is wanted: the caller cancels the
    /// transfer otherwise, so nothing the person withdrew can arrive later.
    public mutating func adopt(stem: String, bytes: Int64, fraction: Double) -> Bool {
        guard let entry = entries[stem], entry.isRequested else { return false }
        switch entry.phase {
        case .onWatch:
            return false
        case .preparing, .sending, .awaitingAck:
            return true
        case .queued, .waiting, .diskFull, .stuck:
            entries[stem]?.phase = .sending(fraction: Self.clamped(fraction))
            entries[stem]?.bytes = bytes
            return true
        }
    }

    /// Sends hand-offs the watch never acknowledged back to the queue once the
    /// grace period has run out, without needing a fresh heartbeat to notice.
    public mutating func expireLostAcks(now: Date) {
        for stem in entries.keys.sorted() {
            guard case .awaitingAck(let since)? = entries[stem]?.phase,
                  now >= since.addingTimeInterval(policy.ackGrace)
            else { continue }
            requeueAfterLostAck(stem: stem)
        }
    }

    public mutating func retryStuck(now: Date) {
        for (stem, entry) in entries where entry.phase.isStuck || entry.phase == .diskFull {
            entries[stem]?.phase = .queued
            entries[stem]?.attempts = 0
        }
    }

    public mutating func reset() {
        entries = [:]
        nextSequence = 0
        watchFreeBytes = 0
        watchIsFull = false
    }

    /// The earliest moment the ledger will change by itself: a backoff ending
    /// or an acknowledgement grace period running out.
    public func nextWakeUp(now: Date) -> Date? {
        entries.values.compactMap { entry -> Date? in
            switch entry.phase {
            case .waiting(let until, _): until
            case .awaitingAck(let since): since.addingTimeInterval(policy.ackGrace)
            default: nil
            }
        }.min()
    }

    private var inFlightBytes: Int64 {
        entries.values.reduce(0) { $0 + ($1.phase.isInFlight ? $1.bytes : 0) }
    }

    private func count(_ matches: (Phase) -> Bool) -> Int {
        entries.values.filter { matches($0.phase) }.count
    }

    private func startable(now: Date) -> [(String, Entry)] {
        entries
            .filter { isStartable($0.value.phase, now: now) }
            .sorted { $0.value.sequence < $1.value.sequence }
            .map { ($0.key, $0.value) }
    }

    private func isStartable(_ phase: Phase, now: Date) -> Bool {
        switch phase {
        case .queued: true
        case .waiting(let until, _): until <= now
        default: false
        }
    }

    private mutating func insert(stem: String, bytes: Int64, phase: Phase, isRequested: Bool) {
        entries[stem] = Entry(
            phase: phase,
            bytes: bytes,
            sequence: nextSequence,
            attempts: 0,
            isRequested: isRequested
        )
        nextSequence += 1
    }

    private mutating func confirm(_ stem: String) {
        guard var entry = entries[stem] else {
            insert(stem: stem, bytes: 0, phase: .onWatch, isRequested: false)
            return
        }
        entry.phase = .onWatch
        entry.attempts = 0
        entries[stem] = entry
    }

    private mutating func reconcileUnconfirmed(stem: String, now: Date) {
        guard let entry = entries[stem] else { return }
        switch entry.phase {
        case .onWatch:
            if entry.isRequested {
                entries[stem]?.phase = .queued
                entries[stem]?.attempts = 0
            } else {
                entries[stem] = nil
            }
        case .awaitingAck(let since) where now >= since.addingTimeInterval(policy.ackGrace):
            requeueAfterLostAck(stem: stem)
        case .diskFull where !watchIsFull:
            entries[stem]?.phase = .queued
        default:
            break
        }
    }

    private mutating func requeueAfterLostAck(stem: String) {
        let attempts = (entries[stem]?.attempts ?? 0) + 1
        entries[stem]?.attempts = attempts
        entries[stem]?.phase = attempts >= policy.maxAttempts ? .stuck(attempts: attempts) : .queued
    }

    private mutating func recordTransientFailure(stem: String, now: Date) {
        let attempts = (entries[stem]?.attempts ?? 0) + 1
        entries[stem]?.attempts = attempts
        guard attempts < policy.maxAttempts else {
            entries[stem]?.phase = .stuck(attempts: attempts)
            return
        }
        let retryAt = now.addingTimeInterval(backoffDelay(forAttempt: attempts))
        entries[stem]?.phase = .waiting(until: retryAt, attempts: attempts)
    }

    private func backoffDelay(forAttempt attempt: Int) -> TimeInterval {
        min(policy.backoffCap, policy.backoffBase * pow(policy.backoffFactor, Double(attempt - 1)))
    }

    private func progress(of phase: Phase?) -> Double {
        switch phase {
        case .onWatch, .awaitingAck: 1
        case .sending(let fraction): fraction
        default: 0
        }
    }

    private static func clamped(_ fraction: Double) -> Double {
        guard !fraction.isNaN else { return 0 }
        return min(1, max(0, fraction))
    }
}

extension WatchSyncLedger.Phase {

    fileprivate var isInFlight: Bool {
        switch self {
        case .preparing, .sending: true
        default: false
        }
    }

    fileprivate var isPendingStart: Bool {
        switch self {
        case .queued, .waiting: true
        default: false
        }
    }

    fileprivate var isAwaitingAck: Bool {
        if case .awaitingAck = self { return true }
        return false
    }

    fileprivate var isStuck: Bool {
        if case .stuck = self { return true }
        return false
    }

    /// Phases a fresh request may send back to the queue; a track already on
    /// the wire or acknowledged is left alone so it is never sent twice.
    fileprivate var isRestartable: Bool {
        switch self {
        case .queued, .waiting, .diskFull, .stuck: true
        default: false
        }
    }
}
