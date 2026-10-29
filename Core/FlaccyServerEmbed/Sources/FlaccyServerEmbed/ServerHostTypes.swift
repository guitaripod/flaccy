import Foundation

public struct ServerHostConfig: Codable, Sendable, Equatable {
    public var musicFolder: String
    public var dataDir: String
    public var logDir: String
    public var name: String
    public var port: UInt16
    public var ffmpeg: String?

    public init(
        musicFolder: String,
        dataDir: String,
        logDir: String,
        name: String,
        port: UInt16 = 0,
        ffmpeg: String? = nil
    ) {
        self.musicFolder = musicFolder
        self.dataDir = dataDir
        self.logDir = logDir
        self.name = name
        self.port = port
        self.ffmpeg = ffmpeg
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
}

public struct ServerEnrollment: Codable, Sendable, Equatable {
    public let link: String
    public let code: String
    public let url: String
    public let user: String
    public let expiresAt: String
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
