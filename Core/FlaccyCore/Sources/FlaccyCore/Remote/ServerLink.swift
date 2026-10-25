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
