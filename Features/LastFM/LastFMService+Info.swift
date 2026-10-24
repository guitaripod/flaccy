import AuthenticationServices
import MidgarCore
import Foundation
import os
import Security

nonisolated extension LastFMService {

    nonisolated func fetchAlbumInfo(artist: String, album: String) async -> AlbumInfo? {
        switch await classifiedAlbumInfo(artist: artist, album: album) {
        case .value(let info):
            return info
        case .empty:
            return nil
        case .failed(let failure):
            MidgarLog.error("Fetch album info failed: \(failure.rawValue)", category: .content)
            return nil
        }
    }

    nonisolated func fetchArtistInfo(artist: String) async -> ArtistInfo? {
        switch await classifiedArtistInfo(artist: artist) {
        case .value(let info):
            return info
        case .empty:
            return nil
        case .failed(let failure):
            MidgarLog.error("Fetch artist info failed: \(failure.rawValue)", category: .content)
            return nil
        }
    }

    /// `album.getInfo` with the outcome classified for `EnrichmentPolicy`:
    /// `.empty` is Last.fm answering that it has no such album, which may cost
    /// the album an attempt, while `.failed` never does.
    nonisolated func classifiedAlbumInfo(
        artist: String, album: String
    ) async -> EnrichmentSourceOutcome<AlbumInfo> {
        var params: [String: String] = [
            "method": "album.getInfo",
            "api_key": Self.apiKey,
            "artist": artist,
            "album": album,
            "autocorrect": "1",
        ]
        if let user = username { params["username"] = user }

        return await classifiedRead(params: params) { json in
            guard let albumDict = json["album"] as? [String: Any] else { return nil }
            return AlbumInfo(
                title: albumDict["name"] as? String ?? album,
                artist: albumDict["artist"] as? String ?? artist,
                imageURL: Self.extractLargestImage(from: albumDict["image"]),
                summary: (albumDict["wiki"] as? [String: Any])?["summary"] as? String,
                musicBrainzID: albumDict["mbid"] as? String,
                userPlayCount: Self.intValue(albumDict["userplaycount"])
            )
        }
    }

    /// The artist twin of `classifiedAlbumInfo`. This is the endpoint the
    /// enrichment job hits most, which is why it now goes through the same
    /// 0.25 s read throttle as every other unsigned read.
    nonisolated func classifiedArtistInfo(artist: String) async -> EnrichmentSourceOutcome<ArtistInfo> {
        let params: [String: String] = [
            "method": "artist.getInfo",
            "api_key": Self.apiKey,
            "artist": artist,
            "autocorrect": "1",
        ]

        return await classifiedRead(params: params) { json in
            guard let artistDict = json["artist"] as? [String: Any] else { return nil }
            return ArtistInfo(
                name: artistDict["name"] as? String ?? artist,
                bio: (artistDict["bio"] as? [String: Any])?["summary"] as? String,
                imageURL: Self.extractLargestImage(from: artistDict["image"]),
                musicBrainzID: artistDict["mbid"] as? String
            )
        }
    }
}
