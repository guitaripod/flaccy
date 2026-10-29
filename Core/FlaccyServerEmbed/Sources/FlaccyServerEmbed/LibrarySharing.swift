import Foundation

/// "Share this Mac's library": keeps the in-process server running while the switch is on, picks its port, holds the music
/// folder open for it, brings it back after sleep or a crash, enrolls this Mac as a device of its own server, and tells the
/// screens what is going on. Every call into the server happens off the main actor, because stopping can take ten seconds.
@MainActor
public final class LibrarySharing {

    public static let didChange = Notification.Name("FlaccyLibrarySharingDidChange")
    public static let defaultPort: UInt16 = 4545
    public static let firewallHintDelay: TimeInterval = 60
    public static let firewallHintExpiry: TimeInterval = 600

    public enum State: Equatable, Sendable {
        case off
        case starting
        case sharing(Sharing)
        case failed(Failure)
    }

    public struct Sharing: Equatable, Sendable {
        public let name: String
        public let songCount: Int?
        public let deviceCount: Int
        public let addresses: ServerAddresses

        public var reachesTailnet: Bool { !addresses.tailnetHosts.isEmpty }
    }

    public enum Failure: Equatable, Sendable {
        case folderOffline
        case server(String)
    }

    public struct Paths: Sendable {
        public var data: URL
        public var logs: URL

        public init(data: URL = FlaccyServerHost.defaultDataDirectory, logs: URL = FlaccyServerHost.defaultLogDirectory) {
            self.data = data
            self.logs = logs
        }
    }

    enum Keys {
        static let enabled = "flaccy.mac.shareLibrary"
        static let port = "flaccy.mac.shareLibrary.port"
        static let introduced = "flaccy.mac.shareLibrary.introduced"
    }

    private struct EnrollmentAttempt {
        let at: Date
        let devicesBefore: Int
    }

    private static let startTimeout: Duration = .seconds(20)
    private static let restartLimit = 3
    private static let selfEnrollLimit = 3

    public private(set) var state: State = .off {
        didSet { if state != oldValue { NotificationCenter.default.post(name: Self.didChange, object: self) } }
    }

    private let host: any ServerHosting
    private let folder: any SharedFolderAccess
    private let enroller: any ThisMacEnrolling
    private let defaults: UserDefaults
    private let paths: Paths
    private let machineName: @Sendable () -> String
    private let isPortFree: @Sendable (UInt16) -> Bool
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async -> Void
    private let pollInterval: Duration?
    private var held: SharedFolder?
    private var tail: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var attempt: EnrollmentAttempt?
    private var restarts = 0
    private var selfEnrollFailures = 0

    public init(
        host: any ServerHosting,
        folder: any SharedFolderAccess,
        enroller: any ThisMacEnrolling,
        defaults: UserDefaults = .standard,
        paths: Paths = Paths(),
        machineName: @escaping @Sendable () -> String,
        isPortFree: @escaping @Sendable (UInt16) -> Bool,
        pollInterval: Duration? = .seconds(5),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.host = host
        self.folder = folder
        self.enroller = enroller
        self.defaults = defaults
        self.paths = paths
        self.machineName = machineName
        self.isPortFree = isPortFree
        self.pollInterval = pollInterval
        self.now = now
        self.sleep = sleep
    }

    public var isEnabled: Bool {
        defaults.bool(forKey: Keys.enabled)
    }

    public var hasBeenIntroduced: Bool {
        get { defaults.bool(forKey: Keys.introduced) }
        set { defaults.set(newValue, forKey: Keys.introduced) }
    }

    public func launch() {
        guard isEnabled else { return }
        enqueue { await $0.startServer() }
    }

    public func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.enabled)
        enqueue {
            if enabled {
                await $0.startServer()
            } else {
                await $0.stopServer()
            }
        }
    }

    /// After sleep, or after the person asks again: checks the server and starts it again if it is gone.
    public func wake() {
        enqueue { await $0.checkOnServer(startingIfDown: true) }
    }

    public func refresh() {
        enqueue { await $0.checkOnServer(startingIfDown: false) }
    }

    /// The music folder changed under the server: it restarts on the new one.
    public func libraryFolderChanged() {
        guard isEnabled else { return }
        enqueue {
            await $0.stopServer()
            await $0.startServer()
        }
    }

    /// Stops the server for good measure when the app quits. The switch stays as the person left it, so the next launch
    /// starts the server again.
    public func shutDown() async {
        await enqueue { await $0.stopServer() }.value
    }

    /// Makes a ten-minute code for another device and remembers when, so a server nobody can reach shows the firewall hint.
    public func makeEnrollment() async throws -> ServerEnrollment {
        let host = host
        let enrollment = try await Task.detached { try host.enroll(user: nil) }.value
        if case .sharing(let sharing) = state { attempt = EnrollmentAttempt(at: now(), devicesBefore: sharing.deviceCount) }
        return enrollment
    }

    /// True when the server is listening, a code was made a minute ago (and not more than ten minutes, the life of a code), and no
    /// device has joined since: the usual sign that the macOS firewall is waiting for the person to allow incoming connections.
    public func firewallHintIsDue() -> Bool {
        guard case .sharing(let sharing) = state, let attempt else { return false }
        let waited = now().timeIntervalSince(attempt.at)
        return (Self.firewallHintDelay..<Self.firewallHintExpiry).contains(waited) && sharing.deviceCount <= attempt.devicesBefore
    }

    @discardableResult
    private func enqueue(_ work: @escaping @MainActor (LibrarySharing) async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task { @MainActor [self] in
            await previous?.value
            await work(self)
        }
        tail = task
        return task
    }

    private func startServer() async {
        if case .sharing = state { return }
        guard let shared = folder.open() else {
            state = .failed(.folderOffline)
            return
        }
        held = shared
        state = .starting
        var lastMessage = "The library server did not start. Try turning sharing off and on."
        attempts: for port in candidatePorts() {
            switch await run(on: port, folder: shared.url) {
            case .success(let status):
                adopt(status)
                restarts = 0
                selfEnrollFailures = 0
                startMonitoring()
                await enrollThisMacIfNeeded()
                return
            case .failure(let failure):
                lastMessage = failure.message
                if failure.isFinal { break attempts }
            }
        }
        held?.release()
        held = nil
        state = .failed(.server(lastMessage))
    }

    private struct StartFailure: Error {
        let message: String
        let isFinal: Bool
    }

    private func run(on port: UInt16, folder: URL) async -> Result<ServerHostStatus, StartFailure> {
        let host = host
        let name = machineName()
        let data = paths.data
        let logs = paths.logs
        do {
            _ = try await Task.detached {
                try host.start(musicFolder: folder, name: name, dataDirectory: data, logDirectory: logs, port: port)
            }.value
        } catch {
            return .failure(StartFailure(message: error.localizedDescription, isFinal: true))
        }
        let deadline = ContinuousClock.now.advanced(by: Self.startTimeout)
        while ContinuousClock.now < deadline {
            guard let status = try? await Task.detached(operation: { try host.status() }).value else {
                return .failure(StartFailure(message: "The library server stopped answering.", isFinal: true))
            }
            switch status.state {
            case .running:
                return .success(status)
            case .error:
                await stopHost()
                return .failure(StartFailure(message: status.lastError ?? "The library server could not start.", isFinal: false))
            case .starting, .stopped:
                await sleep(.milliseconds(100))
            }
        }
        await stopHost()
        return .failure(StartFailure(message: "The library server took too long to start. Try again.", isFinal: false))
    }

    private func candidatePorts() -> [UInt16] {
        let remembered = UInt16(exactly: defaults.integer(forKey: Keys.port)).flatMap { $0 == 0 ? nil : $0 }
        var ports: [UInt16] = []
        for port in [remembered, Self.defaultPort, Self.defaultPort + 1, Self.defaultPort + 2].compactMap({ $0 }) where !ports.contains(port) {
            if isPortFree(port) { ports.append(port) }
        }
        return ports + [0]
    }

    private func stopHost() async {
        let host = host
        try? await Task.detached { try host.stop() }.value
    }

    private func stopServer() async {
        monitor?.cancel()
        monitor = nil
        if state != .off { await stopHost() }
        held?.release()
        held = nil
        attempt = nil
        state = .off
    }

    private func startMonitoring() {
        monitor?.cancel()
        guard let interval = pollInterval else { return }
        let sleep = sleep
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await sleep(interval)
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }

    private func checkOnServer(startingIfDown: Bool) async {
        guard isEnabled else { return }
        guard case .sharing = state else {
            if startingIfDown, state != .starting { await startServer() }
            return
        }
        let host = host
        let status = try? await Task.detached { try host.status() }.value
        if let status, status.state == .running {
            restarts = 0
            adopt(status)
            await enrollThisMacIfNeeded()
            return
        }
        guard restarts < Self.restartLimit else {
            await stopServer()
            state = .failed(.server(status?.lastError ?? "The library server stopped. Turn sharing off and on to start it again."))
            return
        }
        restarts += 1
        await stopServer()
        await startServer()
    }

    private func adopt(_ status: ServerHostStatus) {
        guard let addresses = ServerAddresses(status.addresses) else { return }
        let devices = status.deviceCount ?? 0
        defaults.set(Int(addresses.port), forKey: Keys.port)
        if let attempt, devices > attempt.devicesBefore { self.attempt = nil }
        state = .sharing(Sharing(name: machineName(), songCount: status.songCount, deviceCount: devices, addresses: addresses))
    }

    private func enrollThisMacIfNeeded() async {
        guard case .sharing(let sharing) = state, let server = sharing.addresses.loopbackURL,
              selfEnrollFailures < Self.selfEnrollLimit, enroller.needsEnrolling(with: server)
        else { return }
        let host = host
        do {
            let enrollment = try await Task.detached { try host.enroll(user: nil) }.value
            try await enroller.enroll(with: server, code: enrollment.code, serverName: sharing.name)
            selfEnrollFailures = 0
        } catch {
            selfEnrollFailures += 1
        }
    }
}
