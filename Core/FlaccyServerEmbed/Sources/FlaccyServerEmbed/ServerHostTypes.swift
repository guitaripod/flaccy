import Foundation

public struct ServerHostConfig: Codable, Sendable, Equatable {
    public var musicFolder: String
    public var dataDir: String
    public var logDir: String
    public var name: String
    public var port: UInt16
    public var ffmpeg: String?
    /// Also share on the local network over TLS, so devices on the same Wi-Fi need no Tailscale.
    public var lan: Bool
    /// The Bonjour name devices on this network use, without `.local`.
    public var lanName: String?

    public init(
        musicFolder: String,
        dataDir: String,
        logDir: String,
        name: String,
        port: UInt16 = 0,
        ffmpeg: String? = nil,
        lan: Bool = false,
        lanName: String? = nil
    ) {
        self.musicFolder = musicFolder
        self.dataDir = dataDir
        self.logDir = logDir
        self.name = name
        self.port = port
        self.ffmpeg = ffmpeg
        self.lan = lan
        self.lanName = lanName
    }
}

public enum ServerHostState: String, Codable, Sendable, Equatable {
    case starting
    case running
    case stopped
    case error
}

public struct ServerHostStatus: Codable, Sendable, Equatable {
    public let state: ServerHostState
    public let addresses: [String]
    public let urls: [String]
    public let deviceCount: Int?
    public let songCount: Int?
    public let lastError: String?
    public let version: String
    /// The `https` address devices on this network use, while the server shares here and has a local address.
    public var localUrl: String? = nil
    /// The pin of the key that address answers with.
    public var pin: String? = nil
}

public struct ServerEnrollment: Codable, Sendable, Equatable {
    public let link: String
    public let code: String
    public let url: String
    public let user: String
    public let expiresAt: String
    /// The address a device tries when `url` cannot be reached.
    public var alternate: String? = nil
    /// The pin of the key the `https` addresses answer with.
    public var pin: String? = nil
}

public enum ServerHostError: Error, Equatable, Sendable {
    case server(String)
    case malformedResponse(String)
}

extension ServerHostError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .server(let message), .malformedResponse(let message):
            return message
        }
    }
}
