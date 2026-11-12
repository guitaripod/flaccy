import Foundation

/// What the Add Flaccy Server sheet needs from the app around it: ask a server who it is, and enroll with it.
public protocol ServerSetupGateway: Sendable {
    func hello(baseURL: URL) async throws -> ServerHello
    /// Asks the server at `baseURL` who it is, trusting its key by `pin` when the link carried one.
    func hello(baseURL: URL, pin: String?) async throws -> ServerHello
    func connect(link: FlaccyServerLink, deviceName: String) async throws -> ServerSetupConnection
}

extension ServerSetupGateway {
    public func hello(baseURL: URL, pin: String?) async throws -> ServerHello {
        try await hello(baseURL: baseURL)
    }
}

/// A server this device has enrolled with: the address that answered and the pin its key is trusted by.
public struct ServerSetupConnection: Sendable, Equatable {
    public var serverName: String
    public var baseURL: URL
    public var pin: String?

    public init(serverName: String, baseURL: URL, pin: String? = nil) {
        self.serverName = serverName
        self.baseURL = baseURL
        self.pin = pin
    }
}

public enum ServerSetupResult: Sendable, Equatable {
    case connected(ServerSetupConnection)
    case failed(ServerSetupFailure)
}

/// The steps behind the Connect button of docs/server/UX.md section 3: probe `GET /hello` first, so a server that is not a
/// Flaccy Server, is too old or too new, or cannot be reached never costs the person their one-time code, then enroll.
public struct ServerSetupFlow: Sendable {

    private let gateway: any ServerSetupGateway

    public init(gateway: any ServerSetupGateway) {
        self.gateway = gateway
    }

    /// Runs the probe and the enrollment. `serverNamed` is called once the server has said its own name. A scanned link's
    /// `linkPin` trusts the server's key and its `alternateURL` is tried when the address cannot be reached.
    public func connect(
        address: ServerAddressInput, typedCode: String, linkName: String?, linkPin: String? = nil, alternateURL: URL? = nil,
        deviceName: String, serverNamed: @Sendable (String) -> Void
    ) async -> ServerSetupResult {
        let reached: (url: URL, hello: ServerHello)
        do {
            reached = try await reach([address.baseURL] + (alternateURL.map { [$0] } ?? []), pin: linkPin)
        } catch {
            return .failed(ServerSetupFailure(error: error, server: linkName ?? address.displayName))
        }
        let name = linkName ?? reached.hello.server.name
        serverNamed(name)
        if let failure = Self.incompatibility(of: reached.hello, server: name) { return .failed(failure) }
        let code = EnrollmentCode.normalized(typedCode)
        guard !code.isEmpty else { return .failed(.codeRefused(server: name)) }
        do {
            let link = FlaccyServerLink(baseURL: reached.url, enrollmentCode: code, name: name, pin: linkPin)
            return .connected(try await gateway.connect(link: link, deviceName: deviceName))
        } catch {
            return .failed(ServerSetupFailure(error: error, server: name))
        }
    }

    /// The first address that answers `hello`; only an unreachable one moves on to the next.
    private func reach(_ candidates: [URL], pin: String?) async throws -> (url: URL, hello: ServerHello) {
        for (index, url) in candidates.enumerated() {
            do {
                return (url, try await gateway.hello(baseURL: url, pin: pin))
            } catch let failure as ServerSyncError where failure.isUnreachable && index < candidates.count - 1 {
                continue
            }
        }
        throw ServerSyncError.offline("no address")
    }

    /// The failure row for a server that speaks another protocol or lacks sync, or nil when it can be enrolled with.
    public static func incompatibility(of hello: ServerHello, server: String) -> ServerSetupFailure? {
        guard hello.protocols.contains(ServerProtocol.version) else {
            return (hello.protocols.max() ?? 0) > ServerProtocol.version ? .appTooOld(server: server) : .serverTooOld
        }
        return hello.features.contains("sync") ? nil : .serverTooOld
    }
}

enum ServerProtocol {
    static let version = 1
}
