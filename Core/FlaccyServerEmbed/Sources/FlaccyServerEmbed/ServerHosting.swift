import Foundation

/// What the sharing controller needs from the in-process server, so a test can stand in for it.
public protocol ServerHosting: Sendable {
    func start(musicFolder: URL, name: String, dataDirectory: URL, logDirectory: URL, port: UInt16) throws -> ServerHostStatus
    func stop() throws
    func status() throws -> ServerHostStatus
    func enroll(user: String?) throws -> ServerEnrollment
}

extension FlaccyServerHost: ServerHosting {}

/// A music folder the app holds open for the server: the security-scoped access stays until `release` runs.
public struct SharedFolder: Sendable {
    public let url: URL
    public let release: @Sendable () -> Void

    public init(url: URL, release: @escaping @Sendable () -> Void) {
        self.url = url
        self.release = release
    }
}

public protocol SharedFolderAccess: Sendable {
    /// Opens the folder to share, or nil while it cannot be reached (an unplugged drive, a bookmark that no longer resolves).
    func open() -> SharedFolder?
}

/// Enrolls this Mac as a device of its own server, so its playlists, loves and plays sync like any other device's.
@MainActor
public protocol ThisMacEnrolling {
    /// False when this Mac already syncs with this server, or syncs with another one that must not be replaced.
    func needsEnrolling(with server: URL) -> Bool
    func enroll(with server: URL, code: String, serverName: String) async throws
}

/// The addresses of a running server, told apart: loopback for this Mac, tailnet for every other device.
public struct ServerAddresses: Equatable, Sendable {
    public let loopbackURL: URL?
    public let tailnetHosts: [String]
    public let port: UInt16

    public init?(_ bound: [String]) {
        var loopback: URL?
        var tailnet: [String] = []
        var port: UInt16?
        for address in bound {
            guard let split = address.lastIndex(of: ":"), let value = UInt16(address[address.index(after: split)...]) else { continue }
            port = port ?? value
            let host = String(address[..<split]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if host == "127.0.0.1" {
                loopback = URL(string: "http://127.0.0.1:\(value)")
            } else if Self.isTailnet(host) {
                tailnet.append(host)
            }
        }
        guard let port else { return nil }
        loopbackURL = loopback
        tailnetHosts = tailnet
        self.port = port
    }

    /// True for 100.64.0.0/10 and fd7a:115c:a1e0::/48, the two ranges Tailscale hands out.
    static func isTailnet(_ host: String) -> Bool {
        if host.lowercased().hasPrefix("fd7a:115c:a1e0:") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }
}
