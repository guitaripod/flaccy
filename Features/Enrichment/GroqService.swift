import Foundation
import MidgarCore

nonisolated struct GenreClassification: Sendable, Codable {
    let genre: String
    let subGenre: String?
    let mood: String?
}

nonisolated struct IdentifiedMusic: Sendable, Codable {
    let albums: [IdentifiedAlbum]
}

nonisolated struct IdentifiedAlbum: Sendable, Codable {
    let artist: String
    let album: String
    let year: String?
    let genre: String?
    let tracks: [IdentifiedTrack]
}

nonisolated struct IdentifiedTrack: Sendable, Codable {
    let filename: String
    let title: String
    let trackNumber: Int
}

nonisolated struct TrackContext: Sendable {
    let relativePath: String
    let currentTitle: String
    let currentArtist: String
    let currentAlbum: String
    let trackNumber: Int
}

/// Why the AI pass stopped asking about a folder's tracks. Each reason wants a
/// different answer from the job — wait for the route, sleep until the daily
/// allowance resets, or give the service a breather — so none of them is folded
/// into a bare failure.
nonisolated enum AIInterruption: Sendable, Equatable {
    case unreachable
    case quotaReached(resetsAt: Date)
    case unavailable
}

/// What an analysis managed before it stopped. `music` holds whatever was
/// identified and is kept even when `interruption` is set, because a half
/// answered folder is worth writing down and re-asking about only for the rest.
nonisolated struct AIAnalysis: Sendable {
    let music: IdentifiedMusic?
    let interruption: AIInterruption?

    static let nothing = AIAnalysis(music: nil, interruption: nil)
}

protocol MetadataClassifying: AnyObject, Sendable {
    func analyzeLibrary(tracks: [TrackContext]) async -> AIAnalysis
    func classifyGenre(artist: String, album: String, trackTitles: [String]) async -> GenreClassification?
}

final class GroqService: MetadataClassifying {

    static let shared: MetadataClassifying = GroqService()

    private init() {}

    nonisolated private static let maxBatchSize = 40
    nonisolated private static let minBatchSize = 5
    nonisolated private static let busyBackoff = [10, 20, 40]

    nonisolated private static func hasActiveEntitlement() async -> Bool {
        await MainActor.run { PurchaseManager.shared.allowsPlayback }
    }

    nonisolated func analyzeLibrary(tracks: [TrackContext]) async -> AIAnalysis {
        guard !tracks.isEmpty else { return .nothing }
        guard await Self.hasActiveEntitlement() else {
            MidgarLog.info("Skipping AI analysis: no active entitlement", category: .content)
            return .nothing
        }

        let batch = await analyzeBatch(tracks)
        guard !batch.albums.isEmpty else {
            return AIAnalysis(music: nil, interruption: batch.interruption)
        }

        let merged = Self.mergeDuplicateAlbums(batch.albums)
        MidgarLog.info("AI analyzed library: \(merged.count) albums identified", category: .content)
        return AIAnalysis(music: IdentifiedMusic(albums: merged), interruption: batch.interruption)
    }

    nonisolated private func analyzeBatch(_ tracks: [TrackContext]) async -> BatchResult {
        if tracks.count > Self.maxBatchSize {
            return await bisectAndAnalyze(tracks)
        }

        let request = Self.makeAnalysisRequest(tracks: tracks)

        switch await performRequest(request) {
        case .success(let data):
            do {
                let albums = try JSONDecoder().decode(IdentifiedMusic.self, from: data).albums
                return BatchResult(albums: albums, interruption: nil)
            } catch {
                MidgarLog.error("Failed to decode library analysis: \(error.localizedDescription)", category: .content)
                return await splitOrGiveUp(tracks, reason: "undecodable response")
            }
        case .payloadTooLarge:
            return await splitOrGiveUp(tracks, reason: "payload too large")
        case .truncated:
            return await splitOrGiveUp(tracks, reason: "response truncated at token limit")
        case .interrupted(let interruption):
            return BatchResult(albums: [], interruption: interruption)
        }
    }

    /// Bisects a failed or oversized batch and retries each half, giving up once
    /// the batch is at or below the minimum size where splitting cannot help.
    nonisolated private func splitOrGiveUp(_ tracks: [TrackContext], reason: String) async -> BatchResult {
        guard tracks.count > Self.minBatchSize else {
            MidgarLog.notice("Giving up on batch of \(tracks.count) tracks: \(reason)", category: .content)
            return BatchResult(albums: [], interruption: nil)
        }
        MidgarLog.info("Splitting batch of \(tracks.count) tracks: \(reason)", category: .content)
        return await bisectAndAnalyze(tracks)
    }

    /// Stops at the first half that was interrupted: a spent allowance or a dead
    /// service will answer the second half no differently, and asking anyway is
    /// how a day's requests disappear into a failure.
    nonisolated private func bisectAndAnalyze(_ tracks: [TrackContext]) async -> BatchResult {
        let mid = tracks.count / 2
        let firstHalf = await analyzeBatch(Array(tracks[..<mid]))
        guard firstHalf.interruption == nil else { return firstHalf }
        let secondHalf = await analyzeBatch(Array(tracks[mid...]))
        return BatchResult(albums: firstHalf.albums + secondHalf.albums, interruption: secondHalf.interruption)
    }

    /// Recombines albums that were split across batches so the caller sees one
    /// entry per artist/album pair with the union of its identified tracks.
    nonisolated private static func mergeDuplicateAlbums(_ albums: [IdentifiedAlbum]) -> [IdentifiedAlbum] {
        var order: [String] = []
        var byKey: [String: IdentifiedAlbum] = [:]
        for album in albums {
            let key = "\(album.artist.lowercased())|\(album.album.lowercased())"
            if let existing = byKey[key] {
                byKey[key] = IdentifiedAlbum(
                    artist: existing.artist,
                    album: existing.album,
                    year: existing.year ?? album.year,
                    genre: existing.genre ?? album.genre,
                    tracks: existing.tracks + album.tracks
                )
            } else {
                order.append(key)
                byKey[key] = album
            }
        }
        return order.compactMap { byKey[$0] }
    }

    nonisolated private static func makeAnalysisRequest(tracks: [TrackContext]) -> ChatRequest {
        let trackDescriptions = tracks.enumerated().map { index, track in
            var parts = ["\(index + 1). Path: \(track.relativePath)"]
            if track.currentArtist != "Unknown Artist" { parts.append("Artist: \(track.currentArtist)") }
            if track.currentAlbum != "Unknown Album" { parts.append("Album: \(track.currentAlbum)") }
            if track.currentTitle != track.relativePath { parts.append("Title: \(track.currentTitle)") }
            if track.trackNumber > 0 { parts.append("Track#: \(track.trackNumber)") }
            return parts.joined(separator: " | ")
        }.joined(separator: "\n")

        return ChatRequest(
            messages: [
                ChatMessage(role: "system", content: """
                    You are an expert music librarian with encyclopedic knowledge of music. Your job is to analyze a collection of audio files and organize them into the correct artist/album/track structure.

                    For each file you receive, you may get: a file path, and optionally existing metadata (which may be wrong or missing).

                    Your task:
                    1. IDENTIFY the correct artist for each track. Use your knowledge of music — if you see tracks like "Schism", "Lateralus", "Parabola" you should know these are by Tool.
                    2. GROUP tracks into the correct albums. Don't put tracks from different albums together. Use your knowledge of discographies.
                    3. CLEAN UP track titles — remove track numbers, file extensions, underscores, dashes used purely as separators, and other artifacts. "01 - The Grudge.flac" becomes "The Grudge".
                    4. ASSIGN correct track numbers based on the official album track listing.
                    5. Include year and genre for each album if you know them.

                    PRESERVE VERSION IDENTITY — this is critical. A track is NOT the same as its original when it is a remix, edit, bootleg, mashup, cover, live/acoustic/instrumental version, or an altered speed/pitch version (e.g. "sped up", "slowed + reverb", "nightcore", "8D"). For these:
                    - KEEP the full version qualifier in the title verbatim, e.g. "All The Things She Said (DJ Gollum sped up)" — do NOT strip it down to "All The Things She Said".
                    - CREDIT the remixer/editor as the artist (e.g. "DJ Gollum"), NOT the original performer, unless the file clearly attributes it otherwise.
                    - Treat a dash or parentheses that introduces such a qualifier as meaningful, NOT a separator artifact to be removed.
                    When unsure whether a qualifier is a version marker, KEEP it. Never invent a canonical title that discards information present in the original metadata.

                    The "filename" field in each track MUST be the exact last component of the original path (e.g., "01 - The Grudge.flac") so it can be matched back to the file.

                    Respond with JSON: {"albums": [{"artist": "Artist Name", "album": "Album Title", "year": "2001", "genre": "Progressive Metal", "tracks": [{"filename": "01 - The Grudge.flac", "title": "The Grudge", "trackNumber": 1}]}]}
                    """),
                ChatMessage(role: "user", content: "Analyze and organize this music library:\n\n\(trackDescriptions)"),
            ],
            temperature: 0.1,
            max_completion_tokens: 8192,
            response_format: ResponseFormat(type: "json_object")
        )
    }

    nonisolated func classifyGenre(artist: String, album: String, trackTitles: [String]) async -> GenreClassification? {
        guard await Self.hasActiveEntitlement() else { return nil }
        let tracks = trackTitles.joined(separator: ", ")

        let request = ChatRequest(
            messages: [
                ChatMessage(role: "system", content: "You are a music classification expert. Classify the genre. Respond with JSON: {\"genre\": \"...\", \"subGenre\": \"...\", \"mood\": \"...\"}"),
                ChatMessage(role: "user", content: "Artist: \(artist), Album: \(album), Tracks: \(tracks)"),
            ],
            temperature: 0.2,
            max_completion_tokens: 256,
            response_format: ResponseFormat(type: "json_object")
        )

        guard case .success(let data) = await performRequest(request) else { return nil }

        do {
            return try JSONDecoder().decode(GenreClassification.self, from: data)
        } catch {
            MidgarLog.error("Failed to decode genre classification: \(error.localizedDescription)", category: .content)
            return nil
        }
    }

    nonisolated private func performRequest(_ chatRequest: ChatRequest, retryCount: Int = 0) async -> RequestOutcome {
        do {
            let proxyReply = try await FlaccyMidgar.shared.api.postMetadata(chatRequest)
            let data = proxyReply.body

            let reply = AIProxyReply.classify(
                status: proxyReply.status,
                errorCode: Self.errorCode(in: data),
                retryAfter: proxyReply.retryAfter,
                now: Date()
            )

            switch reply {
            case .answer:
                break
            case .busy:
                guard retryCount < Self.busyBackoff.count else {
                    MidgarLog.notice("AI proxy stayed busy through every retry", category: .content)
                    return .interrupted(.unavailable)
                }
                let waitSeconds = Self.busyBackoff[retryCount]
                MidgarLog.info("AI proxy busy, waiting \(waitSeconds)s (retry \(retryCount + 1)/\(Self.busyBackoff.count))", category: .content)
                try? await Task.sleep(for: .seconds(waitSeconds))
                return await performRequest(chatRequest, retryCount: retryCount + 1)
            case .quotaReached(let resetsAt):
                MidgarLog.info("AI daily limit reached; resumes \(resetsAt.formatted(date: .abbreviated, time: .shortened))", category: .content)
                return .interrupted(.quotaReached(resetsAt: resetsAt))
            case .payloadTooLarge:
                MidgarLog.notice("AI request too large", category: .content)
                return .payloadTooLarge
            case .unavailable:
                if let body = String(data: data, encoding: .utf8) {
                    MidgarLog.error("AI proxy \(proxyReply.status): \(body.prefix(200))", category: .content)
                }
                return .interrupted(.unavailable)
            }

            let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)
            guard let choice = chatResponse.choices.first else {
                MidgarLog.error("AI proxy returned an empty response", category: .content)
                return .interrupted(.unavailable)
            }

            if choice.finish_reason == "length" {
                MidgarLog.notice("AI response truncated at token limit", category: .content)
                return .truncated
            }

            return .success(Data(choice.message.content.utf8))
        } catch {
            MidgarLog.error("AI proxy error: \(error.localizedDescription)", category: .content)
            return .interrupted(error is URLError ? .unreachable : .unavailable)
        }
    }

    /// The proxy's machine-readable reason, `{"error": "<code>"}`; absent from an
    /// answer, and from the raw upstream bodies an older proxy passed through.
    nonisolated private static func errorCode(in data: Data) -> String? {
        (try? JSONDecoder().decode(ProxyError.self, from: data))?.error
    }
}

private nonisolated enum RequestOutcome {
    case success(Data)
    case payloadTooLarge
    case truncated
    case interrupted(AIInterruption)
}

private nonisolated struct BatchResult {
    let albums: [IdentifiedAlbum]
    let interruption: AIInterruption?
}

private nonisolated struct ProxyError: Decodable {
    let error: String
}

private nonisolated struct ChatRequest: Encodable, Sendable {
    let messages: [ChatMessage]
    let temperature: Double
    let max_completion_tokens: Int
    let response_format: ResponseFormat?
}

private nonisolated struct ChatMessage: Codable, Sendable {
    let role: String
    let content: String
}

private nonisolated struct ResponseFormat: Encodable, Sendable {
    let type: String
}

private nonisolated struct ChatResponse: Decodable {
    let choices: [Choice]
    struct Choice: Decodable {
        let message: ChatMessage
        let finish_reason: String?
    }
}
