import AuthenticationServices
import MidgarCore
import Foundation
import os
import Security

nonisolated extension LastFMService {

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
            MidgarLog.error("Fetch similar artists failed: \(error.localizedDescription)", category: .content)
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
        if let user = username { params["username"] = user }
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
            MidgarLog.error("Fetch track info failed: \(error.localizedDescription)", category: .content)
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
            MidgarLog.error("Fetch artist top tracks failed: \(error.localizedDescription)", category: .content)
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
            MidgarLog.error("Fetch artist top albums failed: \(error.localizedDescription)", category: .content)
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
            MidgarLog.error("Fetch artist top tags failed: \(error.localizedDescription)", category: .content)
            return []
        }
    }
}
