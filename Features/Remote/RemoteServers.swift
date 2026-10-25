import FlaccyCore
import FlaccyEngine
import Foundation

/// How the person proves who they are to a server they add.
nonisolated enum RemoteAuthentication: Sendable, Equatable {
    case apiKey(String)
    case password(username: String, password: String)

    var kind: RemoteAuthKind {
        switch self {
        case .apiKey: .apiKey
        case .password: .password
        }
    }

    var username: String {
        switch self {
        case .apiKey: ""
        case .password(let username, _): username
        }
    }

    var secret: String {
        switch self {
        case .apiKey(let key): key
        case .password(_, let password): password
        }
    }

    var credentials: SubsonicCredentials {
        switch self {
        case .apiKey(let key): .apiKey(key)
        case .password(let username, let password): .password(username: username, password: password)
        }
    }
}

/// The music servers the person added: what is known of each in the database, its secret in the
/// Keychain, and the client that talks to it.
actor RemoteServers {

    static let shared = RemoteServers()

    static let didChange = Notification.Name("RemoteServersDidChange")

    private let database: DatabaseManager
    private let credentialStore: RemoteCredentialStore
    private var clients: [String: SubsonicClient] = [:]

    init(database: DatabaseManager = .shared, credentialStore: RemoteCredentialStore = .shared) {
        self.database = database
        self.credentialStore = credentialStore
    }

    func list() throws -> [RemoteServerRecord] {
        try database.fetchRemoteServers()
    }

    func server(id: String) throws -> RemoteServerRecord? {
        try database.fetchRemoteServer(id: id)
    }

    /// The host a person would recognise a server by, for messages.
    func displayHost(for id: String) -> String {
        guard let record = try? database.fetchRemoteServer(id: id), let url = URL(string: record.baseURL) else { return id }
        return url.host ?? record.baseURL
    }

    /// The client for a server, built once from its row and its Keychain secret.
    func client(for id: String) throws -> SubsonicClient {
        if let known = clients[id] { return known }
        guard let record = try database.fetchRemoteServer(id: id), let base = URL(string: record.baseURL) else {
            throw RemoteFailure.songMissing
        }
        guard let secret = credentialStore.secret(for: id) else {
            throw record.auth == .apiKey
                ? RemoteFailure.wrongAPIKey(host: base.host ?? record.baseURL)
                : RemoteFailure.wrongPassword(host: base.host ?? record.baseURL)
        }
        let credentials: SubsonicCredentials = record.auth == .apiKey
            ? .apiKey(secret)
            : .password(username: record.username, password: secret)
        let client = SubsonicClient(serverID: id, base: base, credentials: credentials)
        clients[id] = client
        return client
    }

    /// Adds a server after proving it answers: normalizes the address, pings it, reads its
    /// OpenSubsonic extensions, and only then stores the row and the secret. A server already
    /// added under the same address and user gets the new secret instead of a second copy.
    /// The catalog sync starts on its own; await `RemoteCatalogSync.sync` to wait for it.
    @discardableResult
    func add(address: String, name: String? = nil, authentication: RemoteAuthentication) async throws -> RemoteServerRecord {
        guard let base = ServerAddress.normalize(address) else { throw RemoteFailure.invalidAddress }
        let existing = try list().first { $0.baseURL == base.absoluteString && $0.username == authentication.username }
        let id = existing?.id ?? UUID().uuidString.lowercased()
        let probe = SubsonicClient(serverID: id, base: base, credentials: authentication.credentials)
        let hello = try await probe.ping()
        let extensions = try await probe.extensions()
        try credentialStore.setSecret(authentication.secret, for: id)
        var record = existing ?? RemoteServerRecord(
            id: id,
            name: name ?? probe.host,
            baseURL: base.absoluteString,
            username: authentication.username,
            authKind: authentication.kind,
            addedAt: Date()
        )
        if let name { record.name = name }
        record.authKind = authentication.kind.rawValue
        record.serverType = hello.type
        record.serverVersion = hello.serverVersion
        record.extensionNames = extensions
        try database.saveRemoteServer(record)
        clients[id] = probe
        RemoteLog.info("Added server \(record.name) (\(record.serverType ?? "unknown") \(record.serverVersion ?? ""))")
        await announceChange()
        Task { _ = try? await RemoteCatalogSync.shared.sync(serverID: id) }
        return record
    }

    /// Changes a server's name, address or secret. A new address or secret is checked first.
    @discardableResult
    func update(
        id: String, name: String? = nil, address: String? = nil, authentication: RemoteAuthentication? = nil
    ) async throws -> RemoteServerRecord {
        guard var record = try database.fetchRemoteServer(id: id) else { throw RemoteFailure.songMissing }
        if address != nil || authentication != nil {
            let target = try address.map { text -> URL in
                guard let url = ServerAddress.normalize(text) else { throw RemoteFailure.invalidAddress }
                return url
            } ?? URL(string: record.baseURL)
            guard let base = target else { throw RemoteFailure.invalidAddress }
            let credentials: SubsonicCredentials
            if let authentication {
                credentials = authentication.credentials
            } else if let secret = credentialStore.secret(for: id) {
                credentials = record.auth == .apiKey ? .apiKey(secret) : .password(username: record.username, password: secret)
            } else {
                throw RemoteFailure.wrongPassword(host: base.host ?? record.baseURL)
            }
            let probe = SubsonicClient(serverID: id, base: base, credentials: credentials)
            let hello = try await probe.ping()
            record.extensionNames = try await probe.extensions()
            record.serverType = hello.type
            record.serverVersion = hello.serverVersion
            record.baseURL = base.absoluteString
            if let authentication {
                try credentialStore.setSecret(authentication.secret, for: id)
                record.username = authentication.username
                record.authKind = authentication.kind.rawValue
            }
            clients[id] = probe
        }
        if let name { record.name = name }
        try database.saveRemoteServer(record)
        await announceChange()
        return record
    }

    /// Removes a server and everything that came from it: its songs, the playlist places that
    /// held them, its cached and pinned files and its Keychain secret.
    func remove(id: String) async throws {
        await RemoteCatalogSync.shared.cancel(serverID: id)
        let paths = try database.deleteRemoteServer(id: id)
        await RemoteStreamCache.shared.removeAll(serverID: id)
        credentialStore.removeSecret(for: id)
        clients[id] = nil
        RemoteSongDirectory.shared.invalidate(paths: paths)
        RemoteLog.info("Removed server \(id) with \(paths.count) songs")
        await RemoteCatalogSync.shared.publishRemoval(paths: paths)
        await announceChange()
    }

    private func announceChange() async {
        await MainActor.run {
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }
}
