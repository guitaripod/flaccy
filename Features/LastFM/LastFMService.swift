import AuthenticationServices
import MidgarCore
import Foundation
import os
import Security

/// The Last.fm client. Its credentials live in the Keychain and `UserDefaults` and everything else is immutable, so the
/// requests run from any actor; only the web sign-in session, which presents UI, is pinned to the main actor.
nonisolated final class LastFMService: @unchecked Sendable {

    static let shared = LastFMService()

    static let authDidChange = Notification.Name("LastFMServiceAuthDidChange")

    static let configuredAPIKey = OSAllocatedUnfairLock(initialState: "")

    /// The Last.fm API key. It is empty until ``configure(apiKey:)`` runs, which leaves the service unconfigured.
    static var apiKey: String {
        configuredAPIKey.withLock { $0 }
    }

    /// Hands the service the API key from the gitignored `Secrets` file. That file's `Secrets` type is main-actor
    /// isolated like the rest of the app, so the key is copied here once at launch, before any request reads it.
    @MainActor
    static func configure(apiKey: String) {
        configuredAPIKey.withLock { $0 = apiKey }
    }

    nonisolated static let baseURL = "https://ws.audioscrobbler.com/2.0/"
    static let sessionKeyKey = "lastfm_session_key"
    static let usernameKey = "lastfm_username"

    let client = LastFMClient()
    /// Touched only by the main-actor sign-in methods below.
    nonisolated(unsafe) var authSession: ASWebAuthenticationSession?
    /// Held with `authSession` and touched only by the same main-actor sign-in methods.
    nonisolated(unsafe) var authContextProvider: WebAuthContextProvider?

    var isConfigured: Bool {
        !Self.apiKey.isEmpty && Self.apiKey != "YOUR_LASTFM_API_KEY"
    }

    var isAuthenticated: Bool {
        isConfigured && sessionKey != nil
    }

    private(set) var username: String? {
        get { UserDefaults.standard.string(forKey: Self.usernameKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.usernameKey) }
    }

    var sessionKey: String? {
        get {
            if let key = KeychainStore.string(for: Self.sessionKeyKey) { return key }
            return migrateLegacySessionKey()
        }
        set { KeychainStore.set(newValue, for: Self.sessionKeyKey) }
    }

    /// Moves a session key persisted by older builds out of UserDefaults
    /// (plaintext plist, included in backups) into the Keychain.
    func migrateLegacySessionKey() -> String? {
        guard let legacy = UserDefaults.standard.string(forKey: Self.sessionKeyKey) else { return nil }
        KeychainStore.set(legacy, for: Self.sessionKeyKey)
        UserDefaults.standard.removeObject(forKey: Self.sessionKeyKey)
        MidgarLog.info("Migrated Last.fm session key from UserDefaults to Keychain", category: .auth)
        return legacy
    }

    @MainActor
    func authenticate(from anchor: ASPresentationAnchor) async throws {
        guard isConfigured else { throw LastFMError.apiKeyNotConfigured }
        discardAuthSession()
        let authURL = URL(string: "https://www.last.fm/api/auth/?api_key=\(Self.apiKey)&cb=flaccy://auth")!

        var started: ASWebAuthenticationSession?
        let callbackURL: URL
        do {
            callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let session = ASWebAuthenticationSession(
                    url: authURL,
                    callbackURLScheme: "flaccy",
                    completionHandler: Self.completionHandler(resuming: continuation)
                )
                let contextProvider = WebAuthContextProvider(anchor: anchor)
                session.presentationContextProvider = contextProvider
                session.prefersEphemeralWebBrowserSession = false

                started = session
                self.authContextProvider = contextProvider
                self.authSession = session
                guard session.start() else {
                    self.releaseAuthSession(session)
                    MidgarLog.error("Last.fm sign-in could not be presented", category: .auth)
                    continuation.resume(throwing: LastFMError.authenticationUnavailable)
                    return
                }
                MidgarLog.info("Last.fm sign-in presented", category: .auth)
            }
        } catch {
            releaseAuthSession(started)
            throw error
        }
        releaseAuthSession(started)

        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value
        else { throw LastFMError.invalidCallbackURL }

        let params: [String: String] = [
            "method": "auth.getSession",
            "api_key": Self.apiKey,
            "token": token,
        ]
        let data = try await performSignedRequest(params: params, httpMethod: "GET")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = json["session"] as? [String: Any],
              let key = session["key"] as? String
        else { throw LastFMError.authenticationFailed }

        sessionKey = key
        username = session["name"] as? String
        MidgarLog.info("Last.fm authentication successful", category: .auth)
        NotificationCenter.default.post(name: Self.authDidChange, object: nil)
    }

    /// The completion handler of the web sign-in. Apple calls it on its own XPC queue, so it is built outside the
    /// main-actor `authenticate` and must not inherit that isolation.
    private nonisolated static func completionHandler(
        resuming continuation: CheckedContinuation<URL, Error>
    ) -> ASWebAuthenticationSession.CompletionHandler {
        { url, error in
            if let error { continuation.resume(throwing: error) }
            else if let url { continuation.resume(returning: url) }
            else { continuation.resume(throwing: LastFMError.authenticationFailed) }
        }
    }

    /// Cancels and forgets any sign-in session left over from an earlier
    /// attempt. A live `ASWebAuthenticationSession` the user walked away from
    /// keeps the system's authentication agent busy, and every later `start()`
    /// is queued behind it and silently never presents — the button looks dead.
    /// Clearing the stale session first is what makes a retry work.
    @MainActor
    func discardAuthSession() {
        authSession?.cancel()
        authSession = nil
        authContextProvider = nil
    }

    /// Forgets `session` only if it is still the current one, so a finished
    /// attempt cannot tear down the newer attempt that superseded it.
    @MainActor
    func releaseAuthSession(_ session: ASWebAuthenticationSession?) {
        guard let session, authSession === session else { return }
        authSession = nil
        authContextProvider = nil
    }

    func logout() {
        sessionKey = nil
        username = nil
        MidgarLog.info("Last.fm session cleared", category: .auth)
        NotificationCenter.default.post(name: Self.authDidChange, object: nil)
    }

}
