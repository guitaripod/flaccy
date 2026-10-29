import Foundation

/// The address field of the Add Flaccy Server sheet: what the person typed, where it points and what to call it in a sentence.
public struct ServerAddressInput: Sendable, Equatable {

    public let baseURL: URL

    /// What the Add sheet calls the server before it has told its own name: `arch` for `arch.tail1234.ts.net`, the whole
    /// address for an IP.
    public let displayName: String

    public init?(_ typed: String) {
        guard let url = FlaccyServerLink.baseURL(from: typed), let host = url.host(percentEncoded: false) else { return nil }
        baseURL = url
        displayName = Self.displayName(forHost: host)
    }

    public init(link: FlaccyServerLink) {
        baseURL = link.baseURL
        displayName = link.name ?? Self.displayName(forHost: link.baseURL.host(percentEncoded: false) ?? link.baseURL.absoluteString)
    }

    static func displayName(forHost host: String) -> String {
        let isAddress = host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
        guard !isAddress, let first = host.split(separator: ".").first else { return host }
        return String(first)
    }
}
