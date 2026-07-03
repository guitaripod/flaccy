import MusicKit
import UIKit

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

final class MusicKitService {

    static let shared = MusicKitService()

    private let songCache = NSCache<NSString, CachedSongMatch>()
    private let albumCache = NSCache<NSString, CachedAlbumMatch>()

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
            await AppLogger.warning("MusicKit authorization denied: \(status)", category: .content)
        }
        return status == .authorized
    }

    nonisolated func findSong(title: String, artist: String) async -> MusicKitSongMatch? {
        let cacheKey = "\(artist.lowercased())|\(title.lowercased())" as NSString
        if let cached = songCache.object(forKey: cacheKey) {
            return cached.match
        }

        guard await requestAuthorizationIfNeeded() else { return nil }

        do {
            var request = MusicCatalogSearchRequest(term: "\(artist) \(title)", types: [Song.self])
            request.limit = 10
            let response = try await request.response()

            await AppLogger.info("MusicKit: \(response.songs.count) results for '\(artist) \(title)'", category: .content)

            let match = response.songs.first { song in
                song.title.localizedCaseInsensitiveContains(title)
                    && song.artistName.localizedCaseInsensitiveContains(artist)
            } ?? response.songs.first

            guard let song = match, let url = song.url else {
                await AppLogger.debug("MusicKit: no song match for \(artist) - \(title)", category: .content)
                return nil
            }

            let result = MusicKitSongMatch(
                title: song.title,
                artist: song.artistName,
                albumTitle: song.albumTitle ?? "",
                appleMusicURL: url
            )
            songCache.setObject(CachedSongMatch(match: result), forKey: cacheKey)
            return result
        } catch {
            await AppLogger.error("MusicKit song search failed: \(error.localizedDescription)", category: .content)
            return nil
        }
    }

    nonisolated func findAlbum(title: String, artist: String) async -> MusicKitAlbumMatch? {
        let cacheKey = "\(artist.lowercased())|\(title.lowercased())" as NSString
        if let cached = albumCache.object(forKey: cacheKey) {
            return cached.match
        }

        guard await requestAuthorizationIfNeeded() else { return nil }

        do {
            var request = MusicCatalogSearchRequest(term: "\(artist) \(title)", types: [MusicKit.Album.self])
            request.limit = 10
            let response = try await request.response()

            let match = response.albums.first { album in
                album.title.localizedCaseInsensitiveContains(title)
                    && album.artistName.localizedCaseInsensitiveContains(artist)
            } ?? response.albums.first

            guard let album = match, let url = album.url else {
                await AppLogger.debug("MusicKit: no album match for \(artist) - \(title)", category: .content)
                return nil
            }

            let artworkURL = album.artwork?.url(width: 1600, height: 1600)

            let result = MusicKitAlbumMatch(
                title: album.title,
                artist: album.artistName,
                artworkURL: artworkURL,
                appleMusicURL: url
            )
            albumCache.setObject(CachedAlbumMatch(match: result), forKey: cacheKey)
            return result
        } catch {
            await AppLogger.error("MusicKit album search failed: \(error.localizedDescription)", category: .content)
            return nil
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
                await AppLogger.debug("MusicKit: no artist artwork for \(artist)", category: .content)
                return nil
            }

            let (data, response2) = try await URLSession.shared.data(from: artworkURL)
            guard let http = response2 as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data
        } catch {
            await AppLogger.error("MusicKit artist image fetch failed: \(error.localizedDescription)", category: .content)
            return nil
        }
    }

    nonisolated func fetchAlbumArtwork(title: String, artist: String) async -> Data? {
        guard let album = await findAlbum(title: title, artist: artist),
              let artworkURL = album.artworkURL else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: artworkURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data
        } catch {
            await AppLogger.error("MusicKit artwork download failed: \(error.localizedDescription)", category: .content)
            return nil
        }
    }
}

private final class CachedSongMatch: NSObject {
    let match: MusicKitSongMatch
    init(match: MusicKitSongMatch) { self.match = match }
}

private final class CachedAlbumMatch: NSObject {
    let match: MusicKitAlbumMatch
    init(match: MusicKitAlbumMatch) { self.match = match }
}
