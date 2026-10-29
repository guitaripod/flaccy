import Foundation
import Testing

@testable import FlaccyServerEmbed

private final class FakeHost: ServerHosting, @unchecked Sendable {
    private let lock = NSLock()
    private var current = ServerHostState.stopped
    private var devices = 0
    private var songs: Int? = 12
    private var bound: [String] = []
    private var failure: String?
    private(set) var startedPorts: [UInt16] = []
    private(set) var stops = 0
    private(set) var enrollments = 0

    var addressesOnStart = ["127.0.0.1:{port}", "100.127.250.64:{port}"]

    func start(musicFolder: URL, name: String, dataDirectory: URL, logDirectory: URL, port: UInt16) throws -> ServerHostStatus {
        lock.withLock {
            startedPorts.append(port)
            if let failure {
                current = .error
                return snapshot(error: failure)
            }
            current = .running
            bound = addressesOnStart.map { $0.replacingOccurrences(of: "{port}", with: String(port == 0 ? 49152 : port)) }
            return snapshot()
        }
    }

    func stop() throws {
        lock.withLock {
            stops += 1
            current = .stopped
            bound = []
        }
    }

    func status() throws -> ServerHostStatus {
        lock.withLock { snapshot() }
    }

    func enroll(user: String?) throws -> ServerEnrollment {
        lock.withLock { enrollments += 1 }
        return ServerEnrollment(link: "flaccy://server?url=x", code: "ABCDEFGHJKMNPQRS", url: "http://127.0.0.1:4545", user: "owner", expiresAt: "2026-10-29T12:00:00Z")
    }

    func crash() {
        lock.withLock {
            current = .stopped
            bound = []
        }
    }

    func failStarts(with message: String?) {
        lock.withLock { failure = message }
    }

    func addDevice() {
        lock.withLock { devices += 1 }
    }

    func setSongs(_ count: Int?) {
        lock.withLock { songs = count }
    }

    private func snapshot(error: String? = nil) -> ServerHostStatus {
        ServerHostStatus(
            state: current, addresses: bound, urls: [], deviceCount: current == .running ? devices : nil,
            songCount: current == .running ? songs : nil, lastError: error ?? (current == .error ? failure : nil), version: "1.0.0"
        )
    }
}

private final class Folder: SharedFolderAccess, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var opened = 0
    private(set) var released = 0
    var available = true

    func open() -> SharedFolder? {
        lock.withLock {
            guard available else { return nil }
            opened += 1
            return SharedFolder(url: URL(filePath: "/tmp/music", directoryHint: .isDirectory)) { [self] in lock.withLock { released += 1 } }
        }
    }
}

@MainActor
private final class Enroller: ThisMacEnrolling {
    var wanted = true
    var failing = false
    private(set) var enrolled: [(URL, String, String)] = []

    func needsEnrolling(with server: URL) -> Bool {
        wanted
    }

    func enroll(with server: URL, code: String, serverName: String) async throws {
        if failing { throw ServerHostError.server("refused") }
        enrolled.append((server, code, serverName))
        wanted = false
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.withLock { date } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(seconds) }
    }
}

@MainActor
private struct Rig {
    let host = FakeHost()
    let folder = Folder()
    let enroller = Enroller()
    let clock = Clock()
    let defaults: UserDefaults
    let sharing: LibrarySharing

    init(busyPorts: Set<UInt16> = []) {
        let suite = "flaccy-sharing-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let host = host
        let folder = folder
        let enroller = enroller
        let clock = clock
        sharing = LibrarySharing(
            host: host, folder: folder, enroller: enroller, defaults: defaults,
            paths: .init(data: URL(filePath: "/tmp/data"), logs: URL(filePath: "/tmp/logs")),
            machineName: { "arch" }, isPortFree: { !busyPorts.contains($0) }, pollInterval: nil,
            now: { clock.now }, sleep: { _ in await Task.yield() }
        )
    }

    func settle() async {
        try? await Task.sleep(for: .milliseconds(40))
    }
}

@MainActor
extension LibrarySharing {
    fileprivate func waitFor(_ reached: (State) -> Bool) async {
        for _ in 0..<500 where !reached(state) { try? await Task.sleep(for: .milliseconds(10)) }
    }
}

@MainActor
@Suite(.serialized)
struct LibrarySharingTests {

    @Test func turningTheSwitchOnStartsTheServerOnThePreferredPortAndRemembersIt() async {
        let rig = Rig()
        rig.sharing.setEnabled(true)
        await rig.sharing.waitFor { if case .sharing = $0 { true } else { false } }
        guard case .sharing(let sharing) = rig.sharing.state else { Issue.record("not sharing: \(rig.sharing.state)"); return }
        #expect(rig.host.startedPorts == [4545])
        #expect(sharing.songCount == 12)
        #expect(sharing.reachesTailnet)
        #expect(sharing.name == "arch")
        #expect(rig.sharing.isEnabled)
        #expect(rig.defaults.integer(forKey: LibrarySharing.Keys.port) == 4545)
        await rig.sharing.shutDown()
    }

    @Test func aBusyPortFallsBackToTheNextFreeOne() async {
        let rig = Rig(busyPorts: [4545])
        rig.sharing.setEnabled(true)
        await rig.sharing.waitFor { if case .sharing = $0 { true } else { false } }
        #expect(rig.host.startedPorts == [4546])
        await rig.sharing.shutDown()
    }

    @Test func thePortUsedLastTimeComesFirstSoPairedDevicesKeepWorking() async {
        let rig = Rig()
        rig.defaults.set(4549, forKey: LibrarySharing.Keys.port)
        rig.sharing.setEnabled(true)
        await rig.sharing.waitFor { if case .sharing = $0 { true } else { false } }
        #expect(rig.host.startedPorts == [4549])
        await rig.sharing.shutDown()
    }

    @Test func aServerThatFailsToBindTriesTheNextPortAndThenSaysWhy() async {
        let rig = Rig()
        rig.host.failStarts(with: "Port 4545 is in use.")
        rig.sharing.setEnabled(true)
        await rig.sharing.waitFor { if case .failed = $0 { true } else { false } }
        #expect(rig.sharing.state == .failed(.server("Port 4545 is in use.")))
        #expect(rig.host.startedPorts == [4545, 4546, 4547, 0])
        #expect(rig.folder.released == rig.folder.opened)
    }

    @Test func anOfflineFolderIsAFailureTheNextWakeRetries() async {
        let rig = Rig()
        rig.folder.available = false
        rig.sharing.setEnabled(true)
        await rig.sharing.waitFor { $0 == .failed(.folderOffline) }
        #expect(rig.sharing.state == .failed(.folderOffline))
        rig.folder.available = true
        rig.sharing.wake()
        await rig.sharing.waitFor { if case .sharing = $0 { true } else { false } }
        guard case .sharing = rig.sharing.state else { Issue.record("not sharing: \(rig.sharing.state)"); return }
        await rig.sharing.shutDown()
    }

    @Test func aServerThatDiedWhileTheMacSleptStartsAgainOnWake() async {
        let rig = Rig()
        rig.sharing.setEnabled(true)
        await rig.sharing.waitFor { if case .sharing = $0 { true } else { false } }
        rig.host.crash()
        rig.sharing.wake()
        await rig.sharing.waitFor { _ in rig.host.startedPorts.count == 2 }
        await rig.sharing.waitFor { if case .sharing = $0 { true } else { false } }
        guard case .sharing = rig.sharing.state else { Issue.record("not sharing: \(rig.sharing.state)"); return }
        #expect(rig.host.startedPorts == [4545, 4545])
        await rig.sharing.shutDown()
    }

    @Test func quittingStopsTheServerReleasesTheFolderAndKeepsTheSwitchOn() async {
        let rig = Rig()
        rig.sharing.setEnabled(true)
        await rig.sharing.waitFor { if case .sharing = $0 { true } else { false } }
        await rig.sharing.shutDown()
        #expect(rig.sharing.state == .off)
        #expect(rig.host.stops >= 1)
        #expect(rig.folder.released == rig.folder.opened)
        #expect(rig.sharing.isEnabled)
    }

    @Test func turningTheSwitchOffStopsItAndForgetsThePreference() async {
        let rig = Rig()
        rig.sharing.setEnabled(true)
        await rig.sharing.waitFor { if case .sharing = $0 { true } else { false } }
        rig.sharing.setEnabled(false)
        await rig.sharing.waitFor { $0 == .off }
        #expect(rig.sharing.state == .off)
        #expect(!rig.sharing.isEnabled)
    }

    @Test func launchStartsTheServerOnlyWhenTheSwitchIsOn() async {
        let off = Rig()
        off.sharing.launch()
        await off.settle()
        #expect(off.host.startedPorts.isEmpty)
        let on = Rig()
        on.defaults.set(true, forKey: LibrarySharing.Keys.enabled)
        on.sharing.launch()
        await on.sharing.waitFor { if case .sharing = $0 { true } else { false } }
        #expect(on.host.startedPorts == [4545])
        await on.sharing.shutDown()
    }

    @Test func thisMacEnrollsItselfOverLoopbackOnceAndNeverWhenTheEnrollerDeclines() async {
        let rig = Rig()
        rig.sharing.setEnabled(true)
        await rig.sharing.waitFor { if case .sharing = $0 { true } else { false } }
        #expect(rig.enroller.enrolled.count == 1)
        #expect(rig.enroller.enrolled.first?.0.absoluteString == "http://127.0.0.1:4545")
        #expect(rig.enroller.enrolled.first?.1 == "ABCDEFGHJKMNPQRS")
        #expect(rig.enroller.enrolled.first?.2 == "arch")
        rig.sharing.refresh()
        await rig.settle()
        #expect(rig.host.enrollments == 1)
        await rig.sharing.shutDown()

        let declined = Rig()
        declined.enroller.wanted = false
        declined.sharing.setEnabled(true)
        await declined.sharing.waitFor { if case .sharing = $0 { true } else { false } }
        #expect(declined.host.enrollments == 0)
        await declined.sharing.shutDown()
    }

    @Test func aRefusedSelfEnrollmentIsRetriedAFewTimesThenLeftAlone() async {
        let rig = Rig()
        rig.enroller.failing = true
        rig.sharing.setEnabled(true)
        await rig.sharing.waitFor { if case .sharing = $0 { true } else { false } }
        for _ in 0..<6 {
            rig.sharing.refresh()
            await rig.settle()
        }
        #expect(rig.host.enrollments == 3)
        await rig.sharing.shutDown()
    }

    @Test func theFirewallHintAppearsAMinuteAfterACodeWhenNoDeviceJoined() async throws {
        let rig = Rig()
        rig.enroller.wanted = false
        rig.sharing.setEnabled(true)
        await rig.sharing.waitFor { if case .sharing = $0 { true } else { false } }
        #expect(!rig.sharing.firewallHintIsDue())
        _ = try await rig.sharing.makeEnrollment()
        rig.clock.advance(59)
        #expect(!rig.sharing.firewallHintIsDue())
        rig.clock.advance(2)
        #expect(rig.sharing.firewallHintIsDue())
        rig.clock.advance(600)
        #expect(!rig.sharing.firewallHintIsDue())
        rig.clock.advance(-600)
        rig.host.addDevice()
        rig.sharing.refresh()
        await rig.sharing.waitFor { if case .sharing(let sharing) = $0 { sharing.deviceCount == 1 } else { false } }
        #expect(!rig.sharing.firewallHintIsDue())
        await rig.sharing.shutDown()
    }

    @Test func tailnetAddressesAreToldApartFromLoopbackAndOthers() {
        let addresses = ServerAddresses(["127.0.0.1:4545", "100.127.250.64:4545", "[fd7a:115c:a1e0::1]:4545", "192.168.1.5:4545", "100.200.1.1:4545"])
        #expect(addresses?.port == 4545)
        #expect(addresses?.loopbackURL?.absoluteString == "http://127.0.0.1:4545")
        #expect(addresses?.tailnetHosts == ["100.127.250.64", "fd7a:115c:a1e0::1"])
        #expect(ServerAddresses([]) == nil)
    }

    @Test func withoutATailnetAddressTheServerSaysItReachesThisMacOnly() async {
        let rig = Rig()
        rig.host.addressesOnStart = ["127.0.0.1:{port}"]
        rig.sharing.setEnabled(true)
        await rig.sharing.waitFor { if case .sharing = $0 { true } else { false } }
        guard case .sharing(let sharing) = rig.sharing.state else { Issue.record("not sharing"); return }
        #expect(!sharing.reachesTailnet)
        await rig.sharing.shutDown()
    }
}
