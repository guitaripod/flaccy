import Foundation

/// What the Add Flaccy Server sheet needs from the app around it: ask a server who it is, and enroll with it.
public protocol ServerSetupGateway: Sendable {
    func hello(baseURL: URL) async throws -> ServerHello
    func connect(link: FlaccyServerLink, deviceName: String) async throws -> ServerSetupConnection
}

/// A server this device has enrolled with.
public struct ServerSetupConnection: Sendable, Equatable {
    public var serverName: String
    public var baseURL: URL

    public init(serverName: String, baseURL: URL) {
        self.serverName = serverName
        self.baseURL = baseURL
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

    /// Runs the probe and the enrollment. `serverNamed` is called once the server has said its own name.
    public func connect(
        address: ServerAddressInput, typedCode: String, linkName: String?, deviceName: String,
        serverNamed: @Sendable (String) -> Void
    ) async -> ServerSetupResult {
        let hello: ServerHello
        do {
            hello = try await gateway.hello(baseURL: address.baseURL)
        } catch {
            return .failed(ServerSetupFailure(error: error, server: linkName ?? address.displayName))
        }
        let name = linkName ?? hello.server.name
        serverNamed(name)
        if let failure = Self.incompatibility(of: hello, server: name) { return .failed(failure) }
        let code = EnrollmentCode.normalized(typedCode)
        guard !code.isEmpty else { return .failed(.codeRefused(server: name)) }
        do {
            let link = FlaccyServerLink(baseURL: address.baseURL, enrollmentCode: code, name: name)
            return .connected(try await gateway.connect(link: link, deviceName: deviceName))
        } catch {
            return .failed(ServerSetupFailure(error: error, server: name))
        }
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
