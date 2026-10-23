import AuthenticationServices
import MidgarCore
import Foundation
import os
import Security

nonisolated extension LastFMService {

    nonisolated func fetchTopTracks(period: ChartPeriod, limit: Int = 50) async -> [ChartTrack] {
        guard let user = username else {
            MidgarLog.debug("Skipping chart fetch — no username", category: .sync)
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
            MidgarLog.error("Chart fetch failed: \(error.localizedDescription)", category: .sync)
            return []
        }
    }

    nonisolated func fetchTopArtists(period: ChartPeriod, limit: Int = 50) async -> [ChartArtist] {
        guard let user = username else { return [] }
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
            MidgarLog.error("Fetch top artists failed: \(error.localizedDescription)", category: .sync)
            return []
        }
    }

    nonisolated func fetchTopAlbums(period: ChartPeriod, limit: Int = 50) async -> [ChartAlbum] {
        guard let user = username else { return [] }
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
            MidgarLog.error("Fetch top albums failed: \(error.localizedDescription)", category: .sync)
            return []
        }
    }

    nonisolated func fetchWeeklyChartList() async -> [(fromUts: Int, toUts: Int)] {
        guard let user = username else { return [] }
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
            MidgarLog.error("Fetch weekly chart list failed: \(error.localizedDescription)", category: .sync)
            return []
        }
    }

    nonisolated func fetchWeeklyArtistChart(from: Int, to: Int) async -> [ChartArtist] {
        guard let user = username else { return [] }
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
            MidgarLog.error("Fetch weekly artist chart failed: \(error.localizedDescription)", category: .sync)
            return []
        }
    }

    nonisolated func fetchWeeklyTrackChart(from: Int, to: Int) async -> [ChartTrack] {
        guard let user = username else { return [] }
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
            MidgarLog.error("Fetch weekly track chart failed: \(error.localizedDescription)", category: .sync)
            return []
        }
    }

    nonisolated func fetchWeeklyAlbumChart(from: Int, to: Int) async -> [ChartAlbum] {
        guard let user = username else { return [] }
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
            MidgarLog.error("Fetch weekly album chart failed: \(error.localizedDescription)", category: .sync)
            return []
        }
    }
}
