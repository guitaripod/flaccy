import Foundation

/// The `flaccy://server?url=<url>&key=<key>&name=<name>` link a Flaccy Server prints as a QR code
/// and as text, which fills the Add Server form with API-key sign-in.
public struct ServerLink: Sendable, Equatable {

    public let address: String
    public let apiKey: String
    public let name: String?

    public init(address: String, apiKey: String, name: String?) {
        self.address = address
        self.apiKey = apiKey
        self.name = name
    }

    /// The link a text holds, or nil when it is not a `flaccy://server` link with an address and a key.
    public init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "flaccy",
              components.host?.lowercased() == "server"
        else { return nil }
        let items = components.queryItems ?? []
        func value(_ key: String) -> String? {
            items.first { $0.name == key }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let address = value("url"), !address.isEmpty, let key = value("key"), !key.isEmpty else { return nil }
        self.address = address
        self.apiKey = key
        self.name = value("name").flatMap { $0.isEmpty ? nil : $0 }
    }

    public init?(url: URL) {
        self.init(text: url.absoluteString)
    }
}

/// The `flaccy://server?url=<url>&enroll=<code>&name=<name>&pin=<pin>&alt=<url>` link `flaccy-server setup`,
/// `flaccy-server enroll` and a Mac sharing its library print as a QR code and as text. A link with `enroll` is a Flaccy
/// Server; a link with `key` stays a `ServerLink`. `pin` is the key every `https` address in the link answers with, and
/// `alt` is the address to try when `url` cannot be reached (docs/server/PROTOCOL.md section 3.4).
public struct FlaccyServerLink: Sendable, Equatable, CustomStringConvertible {

    public static let defaultPort = 4545

    public let baseURL: URL
    public let enrollmentCode: String
    public let name: String?
    public let pin: String?
    public let alternateURL: URL?

    public init(baseURL: URL, enrollmentCode: String, name: String?, pin: String? = nil, alternateURL: URL? = nil) {
        self.baseURL = baseURL
        self.enrollmentCode = enrollmentCode
        self.name = name
        self.pin = pin
        self.alternateURL = alternateURL
    }

    /// The addresses to try, in order: `baseURL`, then the fallback.
    public var candidates: [URL] {
        [baseURL] + (alternateURL.map { [$0] } ?? [])
    }

    /// The link a text holds, or nil when it is not a `flaccy://server` link with an address and an enrollment code.
    public init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "flaccy",
              components.host?.lowercased() == "server"
        else { return nil }
        let items = components.queryItems ?? []
        func value(_ key: String) -> String? {
            items.first { $0.name == key }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let address = value("url"), let baseURL = Self.baseURL(from: address),
              let code = value("enroll"), !code.isEmpty
        else { return nil }
        self.baseURL = baseURL
        self.enrollmentCode = code
        self.name = value("name").flatMap { $0.isEmpty ? nil : $0 }
        self.pin = value("pin").flatMap { $0.isEmpty ? nil : $0 }
        self.alternateURL = value("alt").flatMap(Self.baseURL(from:))
    }

    public init?(url: URL) {
        self.init(text: url.absoluteString)
    }

    /// The base URL for what a person types or a link carries: `arch`, `arch.tail1234.ts.net`, `arch.local`, an IP, with
    /// or without a scheme and a port. A bare host gets port 4545, and `https` on the local network (where a Flaccy Server
    /// answers over TLS) or plain HTTP otherwise; a path and a query are dropped.
    public static func baseURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let typedScheme = trimmed.contains("://")
        guard let probe = URLComponents(string: typedScheme ? trimmed : "http://" + trimmed), let probeHost = probe.host else {
            return nil
        }
        let defaultScheme = LocalNetwork.isLocalHost(probeHost) ? "https" : "http"
        let candidate = typedScheme ? trimmed : "\(defaultScheme)://" + trimmed
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        components.path = ""
        if components.port == nil, scheme == "http" || !typedScheme {
            components.port = defaultPort
        }
        return components.url
    }

    public var description: String {
        "FlaccyServerLink(\(baseURL.absoluteString), code: ***, name: \(name ?? "nil"), pin: \(pin ?? "nil"), alt: \(alternateURL?.absoluteString ?? "nil"))"
    }
}

/// What a `flaccy://server` link turned out to be.
public enum ParsedServerLink: Sendable, Equatable {
    case flaccyServer(FlaccyServerLink)
    case subsonic(ServerLink)

    /// Reads either form; a link with an enrollment code wins over one with a key.
    public init?(text: String) {
        if let link = FlaccyServerLink(text: text) {
            self = .flaccyServer(link)
        } else if let link = ServerLink(text: text) {
            self = .subsonic(link)
        } else {
            return nil
        }
    }

    public init?(url: URL) {
        self.init(text: url.absoluteString)
    }
}
