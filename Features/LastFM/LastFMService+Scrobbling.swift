import AuthenticationServices
import MidgarCore
import Foundation
import os
import Security

nonisolated extension LastFMService {

    nonisolated func updateNowPlaying(track: String, artist: String, album: String, duration: Int) async {
        guard let sk = sessionKey else {
            MidgarLog.debug("Skipping now playing update — not authenticated", category: .sync)
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
            MidgarLog.debug("Now playing updated: \(track) - \(artist)", category: .sync)
        } catch {
            MidgarLog.error("Now playing update failed: \(error.localizedDescription)", category: .sync)
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
        guard let sk = sessionKey else {
            MidgarLog.debug("Skipping scrobble — not authenticated", category: .sync)
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
                MidgarLog.notice("Scrobble deferred (error \(code): \(message)): \(track) - \(artist)", category: .sync)
                return false
            case .acceptedCount(let accepted):
                if accepted > 0 {
                    MidgarLog.info("Scrobbled: \(track) - \(artist)", category: .sync)
                    return true
                }
                MidgarLog.notice("Scrobble rejected: \(track) - \(artist)", category: .sync)
                return false
            case .entries(let statuses):
                guard let status = statuses.first else { return false }
                if status.accepted {
                    MidgarLog.info("Scrobbled: \(track) - \(artist)", category: .sync)
                } else if status.ignoredCode == 3 {
                    MidgarLog.notice("Scrobble rejected as too old (>14 days): \(track) - \(artist)", category: .sync)
                } else {
                    MidgarLog.notice("Scrobble permanently ignored (code \(status.ignoredCode)): \(track) - \(artist)", category: .sync)
                }
                return true
            }
        } catch {
            MidgarLog.error("Scrobble failed: \(error.localizedDescription)", category: .sync)
            return false
        }
    }

    /// Submits pending scrobbles in batches and returns the ids that were
    /// actually accepted. Failed batches are omitted so they stay pending and
    /// are retried later (rather than being marked submitted and lost).
    nonisolated func submitPendingScrobbles(
        scrobbles: [(id: Int64, track: String, artist: String, album: String, timestamp: Date, duration: Int)]
    ) async -> [Int64] {
        guard let sk = sessionKey else {
            MidgarLog.debug("Skipping batch scrobble — not authenticated", category: .sync)
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
                    MidgarLog.notice("Batch scrobble deferred (error \(code): \(message)), \(batch.count) kept pending", category: .sync)
                case .acceptedCount(let accepted):
                    if accepted > 0 {
                        submittedIds.append(contentsOf: batch.map(\.id))
                        MidgarLog.info("Batch scrobbled \(batch.count) tracks (accepted \(accepted))", category: .sync)
                    } else {
                        MidgarLog.notice("Batch scrobble accepted 0 of \(batch.count), kept pending", category: .sync)
                    }
                case .entries(let statuses):
                    var acceptedCount = 0
                    for (entry, status) in zip(batch, statuses) {
                        submittedIds.append(entry.id)
                        if status.accepted {
                            acceptedCount += 1
                        } else {
                            MidgarLog.notice("Scrobble permanently ignored (code \(status.ignoredCode)): \(entry.track) - \(entry.artist)", category: .sync)
                        }
                    }
                    MidgarLog.info("Batch scrobbled \(acceptedCount)/\(batch.count) tracks accepted", category: .sync)
                }
            } catch {
                MidgarLog.error("Batch scrobble failed (kept pending): \(error.localizedDescription)", category: .sync)
            }
        }
        return submittedIds
    }

    nonisolated func loveTrack(artist: String, track: String) async -> Bool {
        await setLove(method: "track.love", artist: artist, track: track)
    }

    nonisolated func unloveTrack(artist: String, track: String) async -> Bool {
        await setLove(method: "track.unlove", artist: artist, track: track)
    }

    nonisolated func setLove(method: String, artist: String, track: String) async -> Bool {
        guard let sk = sessionKey else {
            MidgarLog.debug("Skipping \(method) — not authenticated", category: .sync)
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
            MidgarLog.error("\(method) failed: \(error.localizedDescription)", category: .sync)
            return false
        }
    }
}
