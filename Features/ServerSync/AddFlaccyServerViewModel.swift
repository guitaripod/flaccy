import FlaccyCore
import Foundation

/// What happens once the server has accepted this device, besides the sync the engine starts itself: add the server's music to
/// the library and start looking for what the first sync combined.
@MainActor
protocol ServerSetupFollowUp {
    func finish(_ connection: ServerSetupConnection) async -> Bool
}

/// The Add Flaccy Server sheet on iPhone and Mac: the two fields as the person types them, the state of the connection, and
/// the one thing the sheet does, Connect. A link or a scanned code only fills the fields; nothing connects without a tap.
@MainActor
final class AddFlaccyServerViewModel {

    enum State: Equatable {
        case idle
        case checking(server: String)
        case connected(Connected)
        case failed(FailureCopy)
    }

    struct Connected: Equatable {
        let serverName: String
        let libraryAdded: Bool
    }

    var onChange: (() -> Void)?

    var address = "" {
        didSet {
            guard address != oldValue else { return }
            linkName = nil
            returnToIdleAfterEdit()
        }
    }

    var code = "" {
        didSet {
            guard code != oldValue else { return }
            let grouped = EnrollmentCode.grouped(code)
            if grouped != code { code = grouped }
            returnToIdleAfterEdit()
        }
    }

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onChange?() } }
    }

    private let flow: ServerSetupFlow
    private let followUp: any ServerSetupFollowUp
    private let deviceName: String
    private var linkName: String?

    init(
        gateway: any ServerSetupGateway = FlaccyServerSetupGateway(),
        followUp: any ServerSetupFollowUp = FlaccyServerSetupFollowUp(),
        deviceName: String = ServerSyncService.deviceName
    ) {
        flow = ServerSetupFlow(gateway: gateway)
        self.followUp = followUp
        self.deviceName = deviceName
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    var isChecking: Bool {
        if case .checking = state { return true }
        return false
    }

    var canConnect: Bool {
        !isChecking && ServerAddressInput(address) != nil && !EnrollmentCode.normalized(code).isEmpty
    }

    /// Fills both fields from a `flaccy://server` link. It never connects: the person looks at it and taps.
    func apply(link: FlaccyServerLink) {
        address = link.baseURL.absoluteString
        code = link.enrollmentCode
        linkName = link.name
        state = .idle
    }

    func reset() {
        state = .idle
    }

    /// Probes the address, then enrolls with the code. The outcome is in `state`.
    func connect() async {
        guard canConnect, let input = ServerAddressInput(address) else { return }
        state = .checking(server: linkName ?? input.displayName)
        let result = await flow.connect(
            address: input, typedCode: code, linkName: linkName, deviceName: deviceName,
            serverNamed: { [weak self] name in Task { @MainActor in self?.noteServerName(name) } }
        )
        switch result {
        case .failed(let failure):
            state = .failed(FailureCopy(failure))
        case .connected(let connection):
            let libraryAdded = await followUp.finish(connection)
            state = .connected(Connected(serverName: connection.serverName, libraryAdded: libraryAdded))
        }
    }

    private func noteServerName(_ name: String) {
        if case .checking = state { state = .checking(server: name) }
    }

    private func returnToIdleAfterEdit() {
        if case .failed = state { state = .idle }
        onChange?()
    }
}
