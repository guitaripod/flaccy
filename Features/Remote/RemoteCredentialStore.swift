import Foundation
import Security

/// Where a server's secret lives between launches. The Keychain is the only real home for it.
nonisolated protocol RemoteSecretBackend: Sendable {
    func read(account: String) -> String?
    func write(_ secret: String, account: String) -> OSStatus
    func delete(account: String)
}

/// The Keychain item of one server: a generic password under service
/// `cc.midgarcorp.flaccy.remote-server`, account = the server's id, readable after the first
/// unlock so a song can stream from the lock screen. On macOS it is the data protection
/// keychain, so no other app's prompt or access list is involved.
nonisolated struct KeychainRemoteSecrets: RemoteSecretBackend {

    let service: String

    init(service: String = RemoteCredentialStore.service) {
        self.service = service
    }

    func read(account: String) -> String? {
        var query = identity(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ secret: String, account: String) -> OSStatus {
        let query = identity(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(secret.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard updated == errSecItemNotFound else { return updated }
        return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
    }

    func delete(account: String) {
        SecItemDelete(identity(account: account) as CFDictionary)
    }

    private func identity(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }
}

#if DEBUG
/// A stand-in for the Keychain that keeps secrets in the running process only, for a drive of
/// an unsigned Mac build, which the data protection keychain refuses.
nonisolated final class MemoryRemoteSecrets: RemoteSecretBackend, @unchecked Sendable {

    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    func read(account: String) -> String? {
        lock.withLock { secrets[account] }
    }

    func write(_ secret: String, account: String) -> OSStatus {
        lock.withLock { secrets[account] = secret }
        return errSecSuccess
    }

    func delete(account: String) {
        lock.withLock { secrets[account] = nil }
    }
}
#endif

/// Keeps the passwords and API keys of the servers in the Keychain and nowhere else: not in the
/// database, not in defaults, not in a log.
nonisolated final class RemoteCredentialStore: @unchecked Sendable {

    static let service = "cc.midgarcorp.flaccy.remote-server"
    static let shared = RemoteCredentialStore()

    private let lock = NSLock()
    private var backend: any RemoteSecretBackend

    init(backend: any RemoteSecretBackend = KeychainRemoteSecrets()) {
        self.backend = backend
    }

    func secret(for serverID: String) -> String? {
        current.read(account: serverID)
    }

    func setSecret(_ secret: String, for serverID: String) throws {
        guard current.write(secret, account: serverID) == errSecSuccess else { throw RemoteFailure.keychain }
    }

    func removeSecret(for serverID: String) {
        current.delete(account: serverID)
    }

    #if DEBUG
    func useMemoryBackend() {
        lock.withLock { backend = MemoryRemoteSecrets() }
    }
    #endif

    private var current: any RemoteSecretBackend {
        lock.withLock { backend }
    }
}
