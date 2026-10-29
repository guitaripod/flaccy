import FlaccyServerEmbedBindings
import Foundation

/// Hosts the Flaccy Server inside this process. One server runs per process; the calls do not block on the network.
/// The caller keeps security-scoped access to the music folder open for as long as the server runs.
public struct FlaccyServerHost: Sendable {
    public init() {}

    public static var version: String {
        embedVersion()
    }

    /// The data folder inside the app's container: the server's databases, covers and backups.
    public static var defaultDataDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "FlaccyServer", directoryHint: .isDirectory)
    }

    /// The log folder inside the app's container, apart from the app's own `flaccy.log`.
    public static var defaultLogDirectory: URL {
        URL.libraryDirectory.appending(path: "Logs/FlaccyServer", directoryHint: .isDirectory)
    }

    /// Starts sharing `musicFolder` under `name`, or answers the status of the server that already runs.
    @discardableResult
    public func start(
        musicFolder: URL,
        name: String,
        dataDirectory: URL = FlaccyServerHost.defaultDataDirectory,
        logDirectory: URL = FlaccyServerHost.defaultLogDirectory,
        port: UInt16 = 0
    ) throws -> ServerHostStatus {
        let config = ServerHostConfig(
            musicFolder: musicFolder.standardizedFileURL.path(percentEncoded: false),
            dataDir: dataDirectory.standardizedFileURL.path(percentEncoded: false),
            logDir: logDirectory.standardizedFileURL.path(percentEncoded: false),
            name: name,
            port: port
        )
        return try decode(try call { try embedStart(configJson: Self.encode(config)) })
    }

    /// Stops the server, letting open requests finish for up to ten seconds. Stopping a stopped server does nothing.
    public func stop() throws {
        try call { try embedStop() }
    }

    public func status() throws -> ServerHostStatus {
        try decode(try call { try embedStatus() })
    }

    /// Makes a ten-minute code that enrolls one device for `user`, the owner when `nil`.
    public func enroll(user: String? = nil) throws -> ServerEnrollment {
        try decode(try call { try embedEnroll(user: user ?? "") })
    }

    private func call<Output>(_ body: () throws -> Output) throws -> Output {
        do {
            return try body()
        } catch let error as EmbedFfiError {
            switch error {
            case .Message(let message):
                throw ServerHostError.server(message)
            }
        }
    }

    private func decode<Value: Decodable>(_ json: String) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: Data(json.utf8))
        } catch {
            throw ServerHostError.malformedResponse("The library server answered something unreadable: \(error). Update Flaccy.")
        }
    }

    private static func encode(_ config: ServerHostConfig) throws -> String {
        let data = try JSONEncoder().encode(config)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ServerHostError.malformedResponse("The server settings could not be written. Update Flaccy.")
        }
        return json
    }
}
