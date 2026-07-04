import AuthenticationServices
import CryptoKit
import Foundation
import Security

nonisolated enum ChartPeriod: String, CaseIterable, Sendable {
    case week = "7day"
    case month = "1month"
    case threeMonths = "3month"
    case sixMonths = "6month"
    case year = "12month"
    case allTime = "overall"

    var displayName: String {
        switch self {
        case .week: "7 Days"
        case .month: "1 Month"
        case .threeMonths: "3 Months"
        case .sixMonths: "6 Months"
        case .year: "1 Year"
        case .allTime: "All Time"
        }
    }

    var shortName: String {
        switch self {
        case .week: "7D"
        case .month: "1M"
        case .threeMonths: "3M"
        case .sixMonths: "6M"
        case .year: "1Y"
        case .allTime: "All"
        }
    }
}

nonisolated struct ChartTrack: Sendable {
    let rank: Int
    let name: String
    let artistName: String
    let playCount: Int
}

nonisolated struct AlbumInfo: Sendable {
    let title: String
    let artist: String
    let imageURL: String?
    let summary: String?
    let musicBrainzID: String?
    var userPlayCount: Int?
}

nonisolated struct LovedTrack: Sendable {
    let name: String
    let artist: String
    let uts: Int
}

nonisolated struct LastFMUserInfo: Sendable {
    let name: String
    let realName: String?
    let playcount: Int
    let artistCount: Int
    let trackCount: Int
    let albumCount: Int
    let registeredUts: Int
    let imageURL: String?
    let country: String?
}

nonisolated struct RecentTrack: Sendable {
    let name: String
    let artist: String
    let album: String
    let uts: Int?
    let nowPlaying: Bool
}

nonisolated struct ChartArtist: Sendable {
    let rank: Int
    let name: String
    let playCount: Int
}

nonisolated struct ChartAlbum: Sendable {
    let rank: Int
    let name: String
    let artistName: String
    let playCount: Int
    let imageURL: String?
}

nonisolated struct LastFMTrackInfo: Sendable {
    let name: String
    let artist: String
    let album: String?
    let duration: Int?
    let playCount: Int?
    let userPlayCount: Int?
    let userLoved: Bool
    let tags: [String]
}

actor RequestThrottle {
    private let minInterval: TimeInterval
    private var nextAvailable: Date = .distantPast

    init(minInterval: TimeInterval) { self.minInterval = minInterval }

    func acquire() async {
        let now = Date()
        let slot = max(now, nextAvailable)
        nextAvailable = slot.addingTimeInterval(minInterval)
        let delay = slot.timeIntervalSince(now)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}

nonisolated struct ArtistInfo: Sendable {
    let name: String
    let bio: String?
    let imageURL: String?
    let musicBrainzID: String?
}

final class LastFMService {

    static let shared = LastFMService()

    static let authDidChange = Notification.Name("LastFMServiceAuthDidChange")

    nonisolated private static let apiKey = Secrets.lastFMApiKey
    nonisolated private static let apiSecret = Secrets.lastFMApiSecret
    nonisolated private static let baseURL = "https://ws.audioscrobbler.com/2.0/"
    private static let sessionKeyKey = "lastfm_session_key"
    private static let usernameKey = "lastfm_username"

    private let urlSession: URLSession
    private var authSession: ASWebAuthenticationSession?
    private var authContextProvider: WebAuthContextProvider?

    var isConfigured: Bool {
        Self.apiKey != "YOUR_LASTFM_API_KEY"
    }

    var isAuthenticated: Bool {
        isConfigured && sessionKey != nil
    }

    private(set) var username: String? {
        get { UserDefaults.standard.string(forKey: Self.usernameKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.usernameKey) }
    }

    private var sessionKey: String? {
        get {
            if let key = KeychainStore.string(for: Self.sessionKeyKey) { return key }
            return migrateLegacySessionKey()
        }
        set { KeychainStore.set(newValue, for: Self.sessionKeyKey) }
    }

    /// Moves a session key persisted by older builds out of UserDefaults
    /// (plaintext plist, included in backups) into the Keychain.
    private func migrateLegacySessionKey() -> String? {
        guard let legacy = UserDefaults.standard.string(forKey: Self.sessionKeyKey) else { return nil }
        KeychainStore.set(legacy, for: Self.sessionKeyKey)
        UserDefaults.standard.removeObject(forKey: Self.sessionKeyKey)
        AppLogger.info("Migrated Last.fm session key from UserDefaults to Keychain", category: .auth)
        return legacy
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
        username = session["name"] as? String
        AppLogger.info("Last.fm authentication successful", category: .auth)
        NotificationCenter.default.post(name: Self.authDidChange, object: nil)
    }

    func logout() {
        sessionKey = nil
        username = nil
        AppLogger.info("Last.fm session cleared", category: .auth)
        NotificationCenter.default.post(name: Self.authDidChange, object: nil)
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
        duration: Int,
        albumArtist: String? = nil,
        trackNumber: Int? = nil
    ) async -> Bool {
        guard let sk = await sessionKey else {
            await AppLogger.debug("Skipping scrobble — not authenticated", category: .sync)
            return false
        }

        var params: [String: String] = [
            "method": "track.scrobble",
            "api_key": Self.apiKey,
            "sk": sk,
            "track": track,
            "artist": artist,
            "album": album,
            "timestamp": String(Int(timestamp.timeIntervalSince1970)),
            "duration": String(duration),
            "chosenByUser": "1",
        ]
        if let albumArtist, !albumArtist.isEmpty { params["albumArtist"] = albumArtist }
        if let trackNumber, trackNumber > 0 { params["trackNumber"] = String(trackNumber) }

        do {
            let data = try await Self.performWithBackoff {
                try await self.performSignedRequest(params: params, httpMethod: "POST")
            }
            switch Self.parseScrobbleResponse(data: data, expectedCount: 1) {
            case .retryableError(let code, let message):
                await AppLogger.warning("Scrobble deferred (error \(code): \(message)): \(track) - \(artist)", category: .sync)
                return false
            case .acceptedCount(let accepted):
                if accepted > 0 {
                    await AppLogger.info("Scrobbled: \(track) - \(artist)", category: .sync)
                    return true
                }
                await AppLogger.warning("Scrobble rejected: \(track) - \(artist)", category: .sync)
                return false
            case .entries(let statuses):
                guard let status = statuses.first else { return false }
                if status.accepted {
                    await AppLogger.info("Scrobbled: \(track) - \(artist)", category: .sync)
                } else if status.ignoredCode == 3 {
                    await AppLogger.warning("Scrobble rejected as too old (>14 days): \(track) - \(artist)", category: .sync)
                } else {
                    await AppLogger.warning("Scrobble permanently ignored (code \(status.ignoredCode)): \(track) - \(artist)", category: .sync)
                }
                return true
            }
        } catch {
            await AppLogger.error("Scrobble failed: \(error.localizedDescription)", category: .sync)
            return false
        }
    }

    /// Submits pending scrobbles in batches and returns the ids that were
    /// actually accepted. Failed batches are omitted so they stay pending and
    /// are retried later (rather than being marked submitted and lost).
    nonisolated func submitPendingScrobbles(
        scrobbles: [(id: Int64, track: String, artist: String, album: String, timestamp: Date, duration: Int)]
    ) async -> [Int64] {
        guard let sk = await sessionKey else {
            await AppLogger.debug("Skipping batch scrobble — not authenticated", category: .sync)
            return []
        }

        let batches = stride(from: 0, to: scrobbles.count, by: 50).map {
            Array(scrobbles[$0..<min($0 + 50, scrobbles.count)])
        }

        var submittedIds: [Int64] = []
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
                params["chosenByUser[\(i)]"] = "1"
            }

            do {
                let data = try await Self.performWithBackoff {
                    try await self.performSignedRequest(params: params, httpMethod: "POST")
                }
                switch Self.parseScrobbleResponse(data: data, expectedCount: batch.count) {
                case .retryableError(let code, let message):
                    await AppLogger.warning("Batch scrobble deferred (error \(code): \(message)), \(batch.count) kept pending", category: .sync)
                case .acceptedCount(let accepted):
                    if accepted > 0 {
                        submittedIds.append(contentsOf: batch.map(\.id))
                        await AppLogger.info("Batch scrobbled \(batch.count) tracks (accepted \(accepted))", category: .sync)
                    } else {
                        await AppLogger.warning("Batch scrobble accepted 0 of \(batch.count), kept pending", category: .sync)
                    }
                case .entries(let statuses):
                    var acceptedCount = 0
                    for (entry, status) in zip(batch, statuses) {
                        submittedIds.append(entry.id)
                        if status.accepted {
                            acceptedCount += 1
                        } else {
                            await AppLogger.warning("Scrobble permanently ignored (code \(status.ignoredCode)): \(entry.track) - \(entry.artist)", category: .sync)
                        }
                    }
                    await AppLogger.info("Batch scrobbled \(acceptedCount)/\(batch.count) tracks accepted", category: .sync)
                }
            } catch {
                await AppLogger.error("Batch scrobble failed (kept pending): \(error.localizedDescription)", category: .sync)
            }
        }
        return submittedIds
    }

    nonisolated func fetchAlbumInfo(artist: String, album: String) async -> AlbumInfo? {
        var params: [String: String] = [
            "method": "album.getInfo",
            "api_key": Self.apiKey,
            "artist": artist,
            "album": album,
            "autocorrect": "1",
        ]
        if let user = await username { params["username"] = user }

        do {
            let data = try await throttledGET(params: params)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let albumDict = json["album"] as? [String: Any]
            else { return nil }

            let title = albumDict["name"] as? String ?? album
            let artistName = albumDict["artist"] as? String ?? artist
            let imageURL = Self.extractLargestImage(from: albumDict["image"])
            let wiki = albumDict["wiki"] as? [String: Any]
            let summary = wiki?["summary"] as? String
            let mbid = albumDict["mbid"] as? String
            let userPlayCount = Self.intValue(albumDict["userplaycount"])

            return AlbumInfo(
                title: title,
                artist: artistName,
                imageURL: imageURL,
                summary: summary,
                musicBrainzID: mbid,
                userPlayCount: userPlayCount
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

    nonisolated func fetchTopTracks(period: ChartPeriod, limit: Int = 50) async -> [ChartTrack] {
        guard let user = await username else {
            await AppLogger.debug("Skipping chart fetch — no username", category: .sync)
            return []
        }

        let params: [String: String] = [
            "method": "user.getTopTracks",
            "api_key": Self.apiKey,
            "user": user,
            "period": period.rawValue,
            "limit": String(limit),
        ]

        do {
            let data = try await performUnsignedGET(params: params)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let topTracks = json["toptracks"] as? [String: Any],
                  let trackArray = topTracks["track"] as? [[String: Any]]
            else { return [] }

            return trackArray.compactMap { entry in
                guard let name = entry["name"] as? String,
                      let artist = entry["artist"] as? [String: Any],
                      let artistName = artist["name"] as? String
                else { return nil }

                let playCount = Int(entry["playcount"] as? String ?? "0") ?? 0
                let attr = entry["@attr"] as? [String: Any]
                let rank = Int(attr?["rank"] as? String ?? "0") ?? 0

                return ChartTrack(rank: rank, name: name, artistName: artistName, playCount: playCount)
            }
        } catch {
            await AppLogger.error("Chart fetch failed: \(error.localizedDescription)", category: .sync)
            return []
        }
    }

    nonisolated func loveTrack(artist: String, track: String) async -> Bool {
        await setLove(method: "track.love", artist: artist, track: track)
    }

    nonisolated func unloveTrack(artist: String, track: String) async -> Bool {
        await setLove(method: "track.unlove", artist: artist, track: track)
    }

    nonisolated private func setLove(method: String, artist: String, track: String) async -> Bool {
        guard let sk = await sessionKey else {
            await AppLogger.debug("Skipping \(method) — not authenticated", category: .sync)
            return false
        }
        let params: [String: String] = [
            "method": method,
            "api_key": Self.apiKey,
            "sk": sk,
            "artist": artist,
            "track": track,
        ]
        do {
            _ = try await performSignedRequest(params: params, httpMethod: "POST")
            return true
        } catch {
            await AppLogger.error("\(method) failed: \(error.localizedDescription)", category: .sync)
            return false
        }
    }

    nonisolated func fetchLovedTracks(page: Int = 1, limit: Int = 200) async -> (tracks: [LovedTrack], totalPages: Int) {
        guard let user = await username else { return ([], 0) }
        let params: [String: String] = [
            "method": "user.getLovedTracks",
            "api_key": Self.apiKey,
            "user": user,
            "limit": String(min(limit, 1000)),
            "page": String(page),
        ]
        do {
            let data = try await throttledGET(params: params)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let loved = json["lovedtracks"] as? [String: Any]
            else { return ([], 0) }

            let attr = loved["@attr"] as? [String: Any]
            let totalPages = Self.intValue(attr?["totalPages"]) ?? 1
            let tracks = Self.asArray(loved["track"]).compactMap { entry -> LovedTrack? in
                guard let name = entry["name"] as? String,
                      let artistName = (entry["artist"] as? [String: Any])?["name"] as? String
                else { return nil }
                let uts = Self.intValue((entry["date"] as? [String: Any])?["uts"]) ?? 0
                return LovedTrack(name: name, artist: artistName, uts: uts)
            }
            return (tracks, totalPages)
        } catch {
            await AppLogger.error("Fetch loved tracks failed: \(error.localizedDescription)", category: .sync)
            return ([], 0)
        }
    }

    nonisolated func fetchUserInfo() async -> LastFMUserInfo? {
        guard let user = await username else { return nil }
        let params: [String: String] = [
            "method": "user.getInfo",
            "api_key": Self.apiKey,
            "user": user,
        ]
        do {
            let data = try await throttledGET(params: params)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dict = json["user"] as? [String: Any]
            else { return nil }
            return LastFMUserInfo(
                name: dict["name"] as? String ?? user,
                realName: (dict["realname"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                playcount: Self.intValue(dict["playcount"]) ?? 0,
                artistCount: Self.intValue(dict["artist_count"]) ?? 0,
                trackCount: Self.intValue(dict["track_count"]) ?? 0,
                albumCount: Self.intValue(dict["album_count"]) ?? 0,
                registeredUts: Self.intValue((dict["registered"] as? [String: Any])?["unixtime"]) ?? 0,
                imageURL: Self.extractLargestImage(from: dict["image"]),
                country: (dict["country"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            )
        } catch {
            await AppLogger.error("Fetch user info failed: \(error.localizedDescription)", category: .sync)
            return nil
        }
    }

    nonisolated func fetchRecentTracks(page: Int = 1, limit: Int = 200, from: Int? = nil, to: Int? = nil) async -> (tracks: [RecentTrack], total: Int, totalPages: Int) {
        guard let user = await username else { return ([], 0, 0) }
        var params: [String: String] = [
            "method": "user.getRecentTracks",
            "api_key": Self.apiKey,
            "user": user,
            "limit": String(min(limit, 200)),
            "page": String(page),
            "extended": "1",
        ]
        if let from { params["from"] = String(from) }
        if let to { params["to"] = String(to) }
        do {
            let data = try await throttledGET(params: params)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let recent = json["recenttracks"] as? [String: Any]
            else { return ([], 0, 0) }

            let attr = recent["@attr"] as? [String: Any]
            let total = Self.intValue(attr?["total"]) ?? 0
            let totalPages = Self.intValue(attr?["totalPages"]) ?? 1
            let tracks = Self.asArray(recent["track"]).compactMap { entry -> RecentTrack? in
                guard let name = entry["name"] as? String else { return nil }
                let artistName: String
                if let obj = entry["artist"] as? [String: Any] {
                    artistName = obj["name"] as? String ?? obj["#text"] as? String ?? ""
                } else {
                    artistName = entry["artist"] as? String ?? ""
                }
                let album = (entry["album"] as? [String: Any])?["#text"] as? String ?? ""
                let entryAttr = entry["@attr"] as? [String: Any]
                let nowPlaying = (entryAttr?["nowplaying"] as? String) == "true"
                let uts = Self.intValue((entry["date"] as? [String: Any])?["uts"])
                return RecentTrack(name: name, artist: artistName, album: album, uts: uts, nowPlaying: nowPlaying)
            }
            return (tracks.filter { !$0.nowPlaying }, total, totalPages)
        } catch {
            await AppLogger.error("Fetch recent tracks failed: \(error.localizedDescription)", category: .sync)
            return ([], 0, 0)
        }
    }

    nonisolated func scrobbleCount(from: Int, to: Int) async -> Int {
        guard let user = await username else { return 0 }
        let params: [String: String] = [
            "method": "user.getRecentTracks",
            "api_key": Self.apiKey,
            "user": user,
            "limit": "1",
            "from": String(from),
            "to": String(to),
        ]
        do {
            let data = try await throttledGET(params: params)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let recent = json["recenttracks"] as? [String: Any]
            else { return 0 }
            return Self.intValue((recent["@attr"] as? [String: Any])?["total"]) ?? 0
        } catch {
            await AppLogger.error("Scrobble count failed: \(error.localizedDescription)", category: .sync)
            return 0
        }
    }

    nonisolated func fetchTopArtists(period: ChartPeriod, limit: Int = 50) async -> [ChartArtist] {
        guard let user = await username else { return [] }
        let params: [String: String] = [
            "method": "user.getTopArtists",
            "api_key": Self.apiKey,
            "user": user,
            "period": period.rawValue,
            "limit": String(limit),
        ]
        do {
            let data = try await throttledGET(params: params)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let top = json["topartists"] as? [String: Any]
            else { return [] }
            return Self.asArray(top["artist"]).compactMap { entry in
                guard let name = entry["name"] as? String else { return nil }
                let rank = Self.intValue((entry["@attr"] as? [String: Any])?["rank"]) ?? 0
                return ChartArtist(rank: rank, name: name, playCount: Self.intValue(entry["playcount"]) ?? 0)
            }
        } catch {
            await AppLogger.error("Fetch top artists failed: \(error.localizedDescription)", category: .sync)
            return []
        }
    }

    nonisolated func fetchTopAlbums(period: ChartPeriod, limit: Int = 50) async -> [ChartAlbum] {
        guard let user = await username else { return [] }
        let params: [String: String] = [
            "method": "user.getTopAlbums",
            "api_key": Self.apiKey,
            "user": user,
            "period": period.rawValue,
            "limit": String(limit),
        ]
        do {
            let data = try await throttledGET(params: params)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let top = json["topalbums"] as? [String: Any]
            else { return [] }
            return Self.asArray(top["album"]).compactMap { entry -> ChartAlbum? in
                guard let name = entry["name"] as? String else { return nil }
                let artistName = (entry["artist"] as? [String: Any])?["name"] as? String ?? ""
                let rank = Self.intValue((entry["@attr"] as? [String: Any])?["rank"]) ?? 0
                return ChartAlbum(
                    rank: rank,
                    name: name,
                    artistName: artistName,
                    playCount: Self.intValue(entry["playcount"]) ?? 0,
                    imageURL: Self.extractLargestImage(from: entry["image"])
                )
            }
        } catch {
            await AppLogger.error("Fetch top albums failed: \(error.localizedDescription)", category: .sync)
            return []
        }
    }

    nonisolated func fetchWeeklyChartList() async -> [(fromUts: Int, toUts: Int)] {
        guard let user = await username else { return [] }
        let params: [String: String] = [
            "method": "user.getWeeklyChartList",
            "api_key": Self.apiKey,
            "user": user,
        ]
        do {
            let data = try await throttledGET(params: params)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["weeklychartlist"] as? [String: Any]
            else { return [] }
            return Self.asArray(list["chart"]).compactMap { entry in
                guard let from = Self.intValue(entry["from"]), let to = Self.intValue(entry["to"]) else { return nil }
                return (fromUts: from, toUts: to)
            }
        } catch {
            await AppLogger.error("Fetch weekly chart list failed: \(error.localizedDescription)", category: .sync)
            return []
        }
    }

    nonisolated func fetchWeeklyArtistChart(from: Int, to: Int) async -> [ChartArtist] {
        guard let user = await username else { return [] }
        let params: [String: String] = [
            "method": "user.getWeeklyArtistChart",
            "api_key": Self.apiKey,
            "user": user,
            "from": String(from),
            "to": String(to),
        ]
        do {
            let data = try await throttledGET(params: params)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let chart = json["weeklyartistchart"] as? [String: Any]
            else { return [] }
            return Self.asArray(chart["artist"]).compactMap { entry in
                guard let name = entry["name"] as? String else { return nil }
                let rank = Self.intValue((entry["@attr"] as? [String: Any])?["rank"]) ?? 0
                return ChartArtist(rank: rank, name: name, playCount: Self.intValue(entry["playcount"]) ?? 0)
            }
        } catch {
            await AppLogger.error("Fetch weekly artist chart failed: \(error.localizedDescription)", category: .sync)
            return []
        }
    }

    nonisolated func fetchWeeklyTrackChart(from: Int, to: Int) async -> [ChartTrack] {
        guard let user = await username else { return [] }
        let params: [String: String] = [
            "method": "user.getWeeklyTrackChart",
            "api_key": Self.apiKey,
            "user": user,
            "from": String(from),
            "to": String(to),
        ]
        do {
            let data = try await throttledGET(params: params)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let chart = json["weeklytrackchart"] as? [String: Any]
            else { return [] }
            return Self.asArray(chart["track"]).compactMap { entry in
                guard let name = entry["name"] as? String else { return nil }
                let artistName = (entry["artist"] as? [String: Any])?["#text"] as? String
                    ?? (entry["artist"] as? [String: Any])?["name"] as? String ?? ""
                let rank = Self.intValue((entry["@attr"] as? [String: Any])?["rank"]) ?? 0
                return ChartTrack(rank: rank, name: name, artistName: artistName, playCount: Self.intValue(entry["playcount"]) ?? 0)
            }
        } catch {
            await AppLogger.error("Fetch weekly track chart failed: \(error.localizedDescription)", category: .sync)
            return []
        }
    }

    nonisolated func fetchWeeklyAlbumChart(from: Int, to: Int) async -> [ChartAlbum] {
        guard let user = await username else { return [] }
        let params: [String: String] = [
            "method": "user.getWeeklyAlbumChart",
            "api_key": Self.apiKey,
            "user": user,
            "from": String(from),
            "to": String(to),
        ]
        do {
            let data = try await throttledGET(params: params)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let chart = json["weeklyalbumchart"] as? [String: Any]
            else { return [] }
            return Self.asArray(chart["album"]).compactMap { entry -> ChartAlbum? in
                guard let name = entry["name"] as? String else { return nil }
                let artistName = (entry["artist"] as? [String: Any])?["#text"] as? String
                    ?? (entry["artist"] as? [String: Any])?["name"] as? String ?? ""
                let rank = Self.intValue((entry["@attr"] as? [String: Any])?["rank"]) ?? 0
                return ChartAlbum(rank: rank, name: name, artistName: artistName, playCount: Self.intValue(entry["playcount"]) ?? 0, imageURL: nil)
            }
        } catch {
            await AppLogger.error("Fetch weekly album chart failed: \(error.localizedDescription)", category: .sync)
            return []
        }
    }

    nonisolated func fetchSimilarArtists(artist: String, limit: Int = 30) async -> [(name: String, match: Double)] {
        let params: [String: String] = [
            "method": "artist.getSimilar",
            "api_key": Self.apiKey,
            "artist": artist,
            "limit": String(limit),
            "autocorrect": "1",
        ]
        do {
            let data = try await throttledGET(params: params)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let similar = json["similarartists"] as? [String: Any]
            else { return [] }
            return Self.asArray(similar["artist"]).compactMap { entry in
                guard let name = entry["name"] as? String else { return nil }
                let match = Double(entry["match"] as? String ?? "0") ?? 0
                return (name: name, match: match)
            }
        } catch {
            await AppLogger.error("Fetch similar artists failed: \(error.localizedDescription)", category: .content)
            return []
        }
    }

    nonisolated func fetchTrackInfo(artist: String, track: String) async -> LastFMTrackInfo? {
        var params: [String: String] = [
            "method": "track.getInfo",
            "api_key": Self.apiKey,
            "artist": artist,
            "track": track,
            "autocorrect": "1",
        ]
        if let user = await username { params["username"] = user }
        do {
            let data = try await throttledGET(params: params)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dict = json["track"] as? [String: Any]
            else { return nil }
            let artistName = (dict["artist"] as? [String: Any])?["name"] as? String ?? artist
            let album = (dict["album"] as? [String: Any])?["title"] as? String
            let tags = Self.asArray((dict["toptags"] as? [String: Any])?["tag"]).compactMap { $0["name"] as? String }
            let userLovedRaw = dict["userloved"]
            let userLoved = (Self.intValue(userLovedRaw) ?? 0) == 1
            return LastFMTrackInfo(
                name: dict["name"] as? String ?? track,
                artist: artistName,
                album: album,
                duration: Self.intValue(dict["duration"]),
                playCount: Self.intValue(dict["playcount"]),
                userPlayCount: Self.intValue(dict["userplaycount"]),
                userLoved: userLoved,
                tags: tags
            )
        } catch {
            await AppLogger.error("Fetch track info failed: \(error.localizedDescription)", category: .content)
            return nil
        }
    }

    nonisolated func fetchArtistTopTracks(artist: String, limit: Int = 50) async -> [(name: String, playCount: Int, rank: Int)] {
        let params: [String: String] = [
            "method": "artist.getTopTracks",
            "api_key": Self.apiKey,
            "artist": artist,
            "limit": String(limit),
            "autocorrect": "1",
        ]
        do {
            let data = try await throttledGET(params: params)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let top = json["toptracks"] as? [String: Any]
            else { return [] }
            return Self.asArray(top["track"]).compactMap { entry in
                guard let name = entry["name"] as? String else { return nil }
                let rank = Self.intValue((entry["@attr"] as? [String: Any])?["rank"]) ?? 0
                return (name: name, playCount: Self.intValue(entry["playcount"]) ?? 0, rank: rank)
            }
        } catch {
            await AppLogger.error("Fetch artist top tracks failed: \(error.localizedDescription)", category: .content)
            return []
        }
    }

    nonisolated func fetchArtistTopAlbums(artist: String, limit: Int = 50) async -> [ChartAlbum] {
        let params: [String: String] = [
            "method": "artist.getTopAlbums",
            "api_key": Self.apiKey,
            "artist": artist,
            "limit": String(limit),
            "autocorrect": "1",
        ]
        do {
            let data = try await throttledGET(params: params)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let top = json["topalbums"] as? [String: Any]
            else { return [] }
            return Self.asArray(top["album"]).compactMap { entry -> ChartAlbum? in
                guard let name = entry["name"] as? String, name != "(null)" else { return nil }
                let artistName = (entry["artist"] as? [String: Any])?["name"] as? String ?? artist
                return ChartAlbum(
                    rank: 0,
                    name: name,
                    artistName: artistName,
                    playCount: Self.intValue(entry["playcount"]) ?? 0,
                    imageURL: Self.extractLargestImage(from: entry["image"])
                )
            }
        } catch {
            await AppLogger.error("Fetch artist top albums failed: \(error.localizedDescription)", category: .content)
            return []
        }
    }

    nonisolated func fetchArtistTopTags(artist: String) async -> [String] {
        let params: [String: String] = [
            "method": "artist.getTopTags",
            "api_key": Self.apiKey,
            "artist": artist,
            "autocorrect": "1",
        ]
        do {
            let data = try await throttledGET(params: params)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let top = json["toptags"] as? [String: Any]
            else { return [] }
            return Self.asArray(top["tag"]).compactMap { $0["name"] as? String }
        } catch {
            await AppLogger.error("Fetch artist top tags failed: \(error.localizedDescription)", category: .content)
            return []
        }
    }

    nonisolated private static let readThrottle = RequestThrottle(minInterval: 0.25)

    nonisolated private func throttledGET(params: [String: String]) async throws -> Data {
        await Self.readThrottle.acquire()
        return try await performUnsignedGET(params: params)
    }

    /// Retries an operation whose response body carries Last.fm error 29 (rate
    /// limit) with exponential backoff, up to `maxRetries` extra attempts.
    nonisolated private static func performWithBackoff(
        maxRetries: Int = 3,
        _ operation: () async throws -> Data
    ) async throws -> Data {
        var attempt = 0
        while true {
            let data = try await operation()
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               intValue(json["error"]) == 29, attempt < maxRetries {
                let delay = pow(2.0, Double(attempt))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                attempt += 1
                continue
            }
            return data
        }
    }

    nonisolated private static func asArray(_ value: Any?) -> [[String: Any]] {
        if let array = value as? [[String: Any]] { return array }
        if let single = value as? [String: Any] { return [single] }
        return []
    }

    nonisolated private struct ScrobbleEntryStatus {
        let accepted: Bool
        let ignoredCode: Int
    }

    nonisolated private enum ScrobbleResponse {
        case entries([ScrobbleEntryStatus])
        case acceptedCount(Int)
        case retryableError(code: Int, message: String)
    }

    /// Parses a track.scrobble response body. Returns per-entry accepted/ignored
    /// statuses when the response matches the submitted count, a retryable API
    /// error (codes 11/16/29) when the whole request should be retried later,
    /// or falls back to the top-level accepted count for malformed responses.
    nonisolated private static func parseScrobbleResponse(data: Data, expectedCount: Int) -> ScrobbleResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .acceptedCount(0)
        }

        if let errorCode = intValue(json["error"]) {
            let message = json["message"] as? String ?? "unknown"
            if [11, 16, 29].contains(errorCode) {
                return .retryableError(code: errorCode, message: message)
            }
            return .acceptedCount(0)
        }

        guard let scrobbles = json["scrobbles"] as? [String: Any] else {
            return .acceptedCount(0)
        }

        let attr = scrobbles["@attr"] as? [String: Any]
        let acceptedCount = intValue(attr?["accepted"]) ?? 0

        let rawEntries: [[String: Any]]
        if let array = scrobbles["scrobble"] as? [[String: Any]] {
            rawEntries = array
        } else if let single = scrobbles["scrobble"] as? [String: Any] {
            rawEntries = [single]
        } else {
            rawEntries = []
        }

        guard rawEntries.count == expectedCount else {
            return .acceptedCount(acceptedCount)
        }

        let statuses = rawEntries.map { entry -> ScrobbleEntryStatus in
            let ignored = entry["ignoredMessage"] as? [String: Any]
            let code = intValue((ignored?["@attr"] as? [String: Any])?["code"])
                ?? intValue(ignored?["code"])
                ?? 0
            return ScrobbleEntryStatus(accepted: code == 0, ignoredCode: code)
        }
        return .entries(statuses)
    }

    nonisolated private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let string = value as? String { return Int(string) }
        return nil
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

private enum KeychainStore {

    nonisolated private static var service: String {
        Bundle.main.bundleIdentifier ?? "flaccy"
    }

    nonisolated static func string(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func set(_ value: String?, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        guard let value else {
            SecItemDelete(query as CFDictionary)
            return
        }

        let data = Data(value.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            let add = query.merging(update) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
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
