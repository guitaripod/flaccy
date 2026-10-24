import Foundation
import MidgarCore
import MusicKit

/// Whether Flaccy may ask Apple Music for artwork it could not find anywhere
/// else. Off unless the user says otherwise, and never turned on implicitly:
/// a background enrichment pass must never be the thing that raises the
/// system's Apple Music permission alert.
nonisolated enum AppleMusicArtworkSetting {
    static let key = "useAppleMusicArtwork"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: key) }

    static func set(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key)
    }
}

nonisolated struct MusicKitSongMatch: Sendable {
    let title: String
    let artist: String
    let albumTitle: String
    let appleMusicURL: URL
}

nonisolated struct MusicKitAlbumMatch: Sendable {
    let title: String
    let artist: String
    let artworkURL: URL?
    let appleMusicURL: URL
}

/// How one Apple Music catalog search ended: a match, a catalog with nothing
/// that fits, a search that never completed, or no permission to search.
nonisolated enum MusicKitLookup<Match: Sendable>: Sendable {
    case found(Match)
    case notFound
    case failed
    case denied

    var match: Match? {
        if case .found(let match) = self { return match }
        return nil
    }

    /// The sentence that says why a search for `title` produced no match, or
    /// nil when it produced one.
    func missMessage(title: String) -> String? {
        switch self {
        case .found:
            nil
        case .notFound:
            String(localized: "\u{201C}\(title)\u{201D} isn't in the Apple Music catalog.")
        case .failed:
            String(localized: "Couldn't reach Apple Music. Check your connection and try again.")
        case .denied:
            String(localized: "Allow Apple Music access for Flaccy to look up \u{201C}\(title)\u{201D}.")
        }
    }
}

final class MusicKitService {

    static let shared = MusicKitService()

    /// `NSCache` does its own locking, so the song cache is safe to use from the nonisolated lookups.
    private nonisolated(unsafe) let songCache = NSCache<NSString, CachedSongMatch>()

    /// The album counterpart of `songCache`, safe for the same reason.
    private nonisolated(unsafe) let albumCache = NSCache<NSString, CachedAlbumMatch>()

    private init() {
        songCache.countLimit = 200
        albumCache.countLimit = 100
    }

    var isAuthorized: Bool {
        MusicAuthorization.currentStatus == .authorized
    }

    nonisolated func requestAuthorizationIfNeeded() async -> Bool {
        let status = await MusicAuthorization.request()
        if status != .authorized {
            MidgarLog.notice("MusicKit authorization denied: \(status)", category: .content)
        }
        return status == .authorized
    }

    nonisolated func findSong(title: String, artist: String) async -> MusicKitSongMatch? {
        await lookupSong(title: title, artist: artist).match
    }

    nonisolated func lookupSong(title: String, artist: String) async -> MusicKitLookup<MusicKitSongMatch> {
        let cacheKey = "\(artist.lowercased())|\(title.lowercased())" as NSString
        if let cached = songCache.object(forKey: cacheKey) {
            return .found(cached.match)
        }

        guard await requestAuthorizationIfNeeded() else { return .denied }

        do {
            var request = MusicCatalogSearchRequest(term: "\(artist) \(title)", types: [Song.self])
            request.limit = 10
            let response = try await request.response()

            MidgarLog.info("MusicKit: \(response.songs.count) results for '\(artist) \(title)'", category: .content)

            let match = response.songs.first { song in
                song.title.localizedCaseInsensitiveContains(title)
                    && song.artistName.localizedCaseInsensitiveContains(artist)
            } ?? response.songs.first

            guard let song = match, let url = song.url else {
                MidgarLog.debug("MusicKit: no song match for \(artist) - \(title)", category: .content)
                return .notFound
            }

            let result = MusicKitSongMatch(
                title: song.title,
                artist: song.artistName,
                albumTitle: song.albumTitle ?? "",
                appleMusicURL: url
            )
            songCache.setObject(CachedSongMatch(match: result), forKey: cacheKey)
            return .found(result)
        } catch {
            MidgarLog.error("MusicKit song search failed: \(error.localizedDescription)", category: .content)
            return .failed
        }
    }

    nonisolated func findAlbum(title: String, artist: String) async -> MusicKitAlbumMatch? {
        await lookupAlbum(title: title, artist: artist).match
    }

    nonisolated func lookupAlbum(title: String, artist: String) async -> MusicKitLookup<MusicKitAlbumMatch> {
        let cacheKey = "\(artist.lowercased())|\(title.lowercased())" as NSString
        if let cached = albumCache.object(forKey: cacheKey) {
            return .found(cached.match)
        }

        guard await requestAuthorizationIfNeeded() else { return .denied }

        do {
            var request = MusicCatalogSearchRequest(term: "\(artist) \(title)", types: [MusicKit.Album.self])
            request.limit = 10
            let response = try await request.response()

            let match = response.albums.first { album in
                album.title.localizedCaseInsensitiveContains(title)
                    && album.artistName.localizedCaseInsensitiveContains(artist)
            } ?? response.albums.first

            guard let album = match, let url = album.url else {
                MidgarLog.debug("MusicKit: no album match for \(artist) - \(title)", category: .content)
                return .notFound
            }

            let artworkURL = album.artwork?.url(width: 1600, height: 1600)

            let result = MusicKitAlbumMatch(
                title: album.title,
                artist: album.artistName,
                artworkURL: artworkURL,
                appleMusicURL: url
            )
            albumCache.setObject(CachedAlbumMatch(match: result), forKey: cacheKey)
            return .found(result)
        } catch {
            MidgarLog.error("MusicKit album search failed: \(error.localizedDescription)", category: .content)
            return .failed
        }
    }

    /// Searches the Apple Music catalog for the artist and downloads their
    /// editorial artwork; returns nil when no confident match or artwork exists.
    nonisolated func fetchArtistImage(artist: String) async -> Data? {
        guard !artist.isEmpty, await requestAuthorizationIfNeeded() else { return nil }

        do {
            var request = MusicCatalogSearchRequest(term: artist, types: [MusicKit.Artist.self])
            request.limit = 5
            let response = try await request.response()

            let match = response.artists.first { $0.name.localizedCaseInsensitiveCompare(artist) == .orderedSame }
                ?? response.artists.first { $0.name.localizedCaseInsensitiveContains(artist) }

            guard let artworkURL = match?.artwork?.url(width: 1024, height: 1024) else {
                MidgarLog.debug("MusicKit: no artist artwork for \(artist)", category: .content)
                return nil
            }

            let (data, response2) = try await RemoteImageClient().data(from: artworkURL)
            guard let http = response2 as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data
        } catch {
            MidgarLog.error("MusicKit artist image fetch failed: \(error.localizedDescription)", category: .content)
            return nil
        }
    }

    /// The enrichment job's only door into Apple Music. It answers nil unless
    /// the user opted in *and* authorization has already been granted, so a
    /// background loop can never reach `MusicAuthorization.request()` and put a
    /// permission alert in front of somebody who was just browsing.
    nonisolated func artworkForEnrichment(title: String, artist: String) async -> Data? {
        guard AppleMusicArtworkSetting.isEnabled, await Self.isAlreadyAuthorized() else { return nil }
        return await fetchAlbumArtwork(title: title, artist: artist)
    }

    /// Turns the Apple Music artwork source on, asking for permission the one
    /// time the toggle is flipped. Returns whether it is now usable.
    nonisolated func enableArtworkSource() async -> Bool {
        let granted = await requestAuthorizationIfNeeded()
        AppleMusicArtworkSetting.set(granted)
        return granted
    }

    nonisolated static func isAlreadyAuthorized() async -> Bool {
        await MainActor.run { MusicAuthorization.currentStatus == .authorized }
    }

    nonisolated func fetchAlbumArtwork(title: String, artist: String) async -> Data? {
        guard let album = await findAlbum(title: title, artist: artist),
              let artworkURL = album.artworkURL else { return nil }

        do {
            let (data, response) = try await RemoteImageClient().data(from: artworkURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data
        } catch {
            MidgarLog.error("MusicKit artwork download failed: \(error.localizedDescription)", category: .content)
            return nil
        }
    }
}

private nonisolated final class CachedSongMatch: NSObject {
    let match: MusicKitSongMatch
    init(match: MusicKitSongMatch) { self.match = match }
}

private nonisolated final class CachedAlbumMatch: NSObject {
    let match: MusicKitAlbumMatch
    init(match: MusicKitAlbumMatch) { self.match = match }
}
