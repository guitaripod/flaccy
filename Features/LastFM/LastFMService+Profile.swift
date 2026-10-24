import AuthenticationServices
import MidgarCore
import Foundation
import os
import Security

nonisolated extension LastFMService {

    nonisolated func fetchLovedTracks(page: Int = 1, limit: Int = 200) async -> (tracks: [LovedTrack], totalPages: Int) {
        guard let user = username else { return ([], 0) }
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
            MidgarLog.error("Fetch loved tracks failed: \(error.localizedDescription)", category: .sync)
            return ([], 0)
        }
    }

    nonisolated func fetchUserInfo() async -> LastFMUserInfo? {
        guard let user = username else { return nil }
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
            MidgarLog.error("Fetch user info failed: \(error.localizedDescription)", category: .sync)
            return nil
        }
    }

    nonisolated func fetchRecentTracks(page: Int = 1, limit: Int = 200, from: Int? = nil, to: Int? = nil) async -> (tracks: [RecentTrack], total: Int, totalPages: Int) {
        guard let user = username else { return ([], 0, 0) }
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
            MidgarLog.error("Fetch recent tracks failed: \(error.localizedDescription)", category: .sync)
            return ([], 0, 0)
        }
    }

    nonisolated func scrobbleCount(from: Int, to: Int) async -> Int {
        guard let user = username else { return 0 }
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
            MidgarLog.error("Scrobble count failed: \(error.localizedDescription)", category: .sync)
            return 0
        }
    }
}
