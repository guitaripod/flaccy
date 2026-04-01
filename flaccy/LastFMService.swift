import AuthenticationServices
import CryptoKit
import Foundation

nonisolated struct AlbumInfo: Sendable {
    let title: String
    let artist: String
    let imageURL: String?
    let summary: String?
    let musicBrainzID: String?
}

nonisolated struct ArtistInfo: Sendable {
    let name: String
    let bio: String?
    let imageURL: String?
    let musicBrainzID: String?
}

final class LastFMService {

    static let shared = LastFMService()

    nonisolated private static let apiKey = Secrets.lastFMApiKey
    nonisolated private static let apiSecret = Secrets.lastFMApiSecret
    nonisolated private static let baseURL = "https://ws.audioscrobbler.com/2.0/"
    private static let sessionKeyKey = "lastfm_session_key"

    private let urlSession: URLSession
    private var authSession: ASWebAuthenticationSession?
    private var authContextProvider: WebAuthContextProvider?

    var isConfigured: Bool {
        Self.apiKey != "YOUR_LASTFM_API_KEY"
    }

    var isAuthenticated: Bool {
        isConfigured && sessionKey != nil
    }

    private var sessionKey: String? {
        get { UserDefaults.standard.string(forKey: Self.sessionKeyKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.sessionKeyKey) }
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        urlSession = URLSession(configuration: config)
    }

    func authenticate(from anchor: ASPresentationAnchor) async throws {
        guard isConfigured else { throw LastFMError.apiKeyNotConfigured }
        let authURL = URL(string: "https://www.last.fm/api/auth/?api_key=\(Self.apiKey)&cb=flaccy://auth")!

        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: "flaccy"
            ) { url, error in
                if let error { continuation.resume(throwing: error) }
                else if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: LastFMError.authenticationFailed) }
            }
            let contextProvider = WebAuthContextProvider(anchor: anchor)
            session.presentationContextProvider = contextProvider
            session.prefersEphemeralWebBrowserSession = false

            self.authContextProvider = contextProvider
            self.authSession = session
            session.start()
        }

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
        AppLogger.info("Last.fm authentication successful", category: .auth)
    }

    func logout() {
        sessionKey = nil
        AppLogger.info("Last.fm session cleared", category: .auth)
    }

    nonisolated func updateNowPlaying(track: String, artist: String, album: String, duration: Int) async {
        guard let sk = await sessionKey else {
            await AppLogger.debug("Skipping now playing update — not authenticated", category: .sync)
            return
        }

        let params: [String: String] = [
            "method": "track.updateNowPlaying",
            "api_key": Self.apiKey,
            "sk": sk,
            "track": track,
            "artist": artist,
            "album": album,
            "duration": String(duration),
        ]

        do {
            _ = try await performSignedRequest(params: params, httpMethod: "POST")
            await AppLogger.debug("Now playing updated: \(track) - \(artist)", category: .sync)
        } catch {
            await AppLogger.error("Now playing update failed: \(error.localizedDescription)", category: .sync)
        }
    }

    nonisolated func scrobble(
        track: String,
        artist: String,
        album: String,
        timestamp: Date,
        duration: Int
    ) async -> Bool {
        guard let sk = await sessionKey else {
            await AppLogger.debug("Skipping scrobble — not authenticated", category: .sync)
            return false
        }

        let params: [String: String] = [
            "method": "track.scrobble",
            "api_key": Self.apiKey,
            "sk": sk,
            "track": track,
            "artist": artist,
            "album": album,
            "timestamp": String(Int(timestamp.timeIntervalSince1970)),
            "duration": String(duration),
        ]

        do {
            let data = try await performSignedRequest(params: params, httpMethod: "POST")
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let scrobbles = json?["scrobbles"] as? [String: Any]
            let attr = scrobbles?["@attr"] as? [String: Any]
            let accepted = (attr?["accepted"] as? Int) ?? 0

            if accepted > 0 {
                await AppLogger.info("Scrobbled: \(track) - \(artist)", category: .sync)
                return true
            } else {
                await AppLogger.warning("Scrobble rejected: \(track) - \(artist)", category: .sync)
                return false
            }
        } catch {
            await AppLogger.error("Scrobble failed: \(error.localizedDescription)", category: .sync)
            return false
        }
    }

    nonisolated func submitPendingScrobbles(
        scrobbles: [(track: String, artist: String, album: String, timestamp: Date, duration: Int)]
    ) async {
        guard let sk = await sessionKey else {
            await AppLogger.debug("Skipping batch scrobble — not authenticated", category: .sync)
            return
        }

        let batches = stride(from: 0, to: scrobbles.count, by: 50).map {
            Array(scrobbles[$0..<min($0 + 50, scrobbles.count)])
        }

        for batch in batches {
            var params: [String: String] = [
                "method": "track.scrobble",
                "api_key": Self.apiKey,
                "sk": sk,
            ]

            for (i, entry) in batch.enumerated() {
                params["track[\(i)]"] = entry.track
                params["artist[\(i)]"] = entry.artist
                params["album[\(i)]"] = entry.album
                params["timestamp[\(i)]"] = String(Int(entry.timestamp.timeIntervalSince1970))
                params["duration[\(i)]"] = String(entry.duration)
            }

            do {
                _ = try await performSignedRequest(params: params, httpMethod: "POST")
                await AppLogger.info("Batch scrobbled \(batch.count) tracks", category: .sync)
            } catch {
                await AppLogger.error("Batch scrobble failed: \(error.localizedDescription)", category: .sync)
            }
        }
    }

    nonisolated func fetchAlbumInfo(artist: String, album: String) async -> AlbumInfo? {
        let params: [String: String] = [
            "method": "album.getInfo",
            "api_key": Self.apiKey,
            "artist": artist,
            "album": album,
        ]

        do {
            let data = try await performUnsignedGET(params: params)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let albumDict = json["album"] as? [String: Any]
            else { return nil }

            let title = albumDict["name"] as? String ?? album
            let artistName = albumDict["artist"] as? String ?? artist
            let imageURL = Self.extractLargestImage(from: albumDict["image"])
            let wiki = albumDict["wiki"] as? [String: Any]
            let summary = wiki?["summary"] as? String
            let mbid = albumDict["mbid"] as? String

            return AlbumInfo(
                title: title,
                artist: artistName,
                imageURL: imageURL,
                summary: summary,
                musicBrainzID: mbid
            )
        } catch {
            await AppLogger.error("Fetch album info failed: \(error.localizedDescription)", category: .content)
            return nil
        }
    }

    nonisolated func fetchArtistInfo(artist: String) async -> ArtistInfo? {
        let params: [String: String] = [
            "method": "artist.getInfo",
            "api_key": Self.apiKey,
            "artist": artist,
        ]

        do {
            let data = try await performUnsignedGET(params: params)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let artistDict = json["artist"] as? [String: Any]
            else { return nil }

            let name = artistDict["name"] as? String ?? artist
            let bio = (artistDict["bio"] as? [String: Any])?["summary"] as? String
            let imageURL = Self.extractLargestImage(from: artistDict["image"])
            let mbid = artistDict["mbid"] as? String

            return ArtistInfo(
                name: name,
                bio: bio,
                imageURL: imageURL,
                musicBrainzID: mbid
            )
        } catch {
            await AppLogger.error("Fetch artist info failed: \(error.localizedDescription)", category: .content)
            return nil
        }
    }

    nonisolated private func performSignedRequest(
        params: [String: String],
        httpMethod: String
    ) async throws -> Data {
        var signedParams = params
        signedParams["api_sig"] = Self.generateSignature(params: params)
        signedParams["format"] = "json"

        if httpMethod == "GET" {
            return try await performGET(params: signedParams)
        } else {
            return try await performPOST(params: signedParams)
        }
    }

    nonisolated private func performUnsignedGET(params: [String: String]) async throws -> Data {
        var allParams = params
        allParams["format"] = "json"
        return try await performGET(params: allParams)
    }

    nonisolated private func performGET(params: [String: String]) async throws -> Data {
        var components = URLComponents(string: Self.baseURL)!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let url = components.url else {
            throw LastFMError.invalidURL
        }

        let (data, response) = try await urlSession.data(from: url)
        try validateResponse(response, data: data)
        return data
    }

    nonisolated private func performPOST(params: [String: String]) async throws -> Data {
        guard let url = URL(string: Self.baseURL) else {
            throw LastFMError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = params
            .map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }
            .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await urlSession.data(for: request)
        try validateResponse(response, data: data)
        return data
    }

    nonisolated private func percentEncode(_ string: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    nonisolated private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LastFMError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            let errorMessage: String
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["message"] as? String {
                errorMessage = message
            } else {
                errorMessage = "HTTP \(http.statusCode)"
            }
            throw LastFMError.apiError(errorMessage)
        }
    }

    nonisolated private static func generateSignature(params: [String: String]) -> String {
        let filtered = params.filter { $0.key != "format" }
        let sorted = filtered.sorted { $0.key < $1.key }
        let concatenated = sorted.map { "\($0.key)\($0.value)" }.joined()
        let sigString = concatenated + apiSecret
        let digest = Insecure.MD5.hash(data: Data(sigString.utf8))
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    nonisolated private static func extractLargestImage(from imageArray: Any?) -> String? {
        guard let images = imageArray as? [[String: Any]] else { return nil }

        let sizeOrder = ["mega", "extralarge", "large", "medium", "small"]
        for size in sizeOrder {
            if let match = images.first(where: { ($0["size"] as? String) == size }),
               let url = match["#text"] as? String,
               !url.isEmpty {
                return url
            }
        }
        return nil
    }
}

private final class WebAuthContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    let anchor: ASPresentationAnchor
    init(anchor: ASPresentationAnchor) { self.anchor = anchor }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }
}

enum LastFMError: Error, LocalizedError {
    case invalidCallbackURL
    case authenticationFailed
    case invalidURL
    case invalidResponse
    case apiKeyNotConfigured
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidCallbackURL: "Invalid Last.fm callback URL"
        case .authenticationFailed: "Last.fm authentication failed"
        case .invalidURL: "Invalid Last.fm API URL"
        case .invalidResponse: "Invalid response from Last.fm"
        case .apiKeyNotConfigured: "Last.fm API key not configured"
        case .apiError(let message): "Last.fm API error: \(message)"
        }
    }
}
