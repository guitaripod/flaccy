import Foundation

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

protocol MetadataClassifying: AnyObject, Sendable {
    func analyzeLibrary(tracks: [TrackContext]) async -> IdentifiedMusic?
    func classifyGenre(artist: String, album: String, trackTitles: [String]) async -> GenreClassification?
}

final class GroqService: MetadataClassifying {

    static let shared: MetadataClassifying = GroqService()

    nonisolated private static let apiKey = Secrets.groqApiKey
    nonisolated private static let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    nonisolated private static let model = "llama-3.3-70b-versatile"

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config)
    }

    nonisolated func analyzeLibrary(tracks: [TrackContext]) async -> IdentifiedMusic? {
        guard Self.apiKey != "YOUR_GROQ_API_KEY" else { return nil }
        guard !tracks.isEmpty else { return nil }

        let trackDescriptions = tracks.enumerated().map { index, track in
            var parts = ["\(index + 1). Path: \(track.relativePath)"]
            if track.currentArtist != "Unknown Artist" { parts.append("Artist: \(track.currentArtist)") }
            if track.currentAlbum != "Unknown Album" { parts.append("Album: \(track.currentAlbum)") }
            if track.currentTitle != track.relativePath { parts.append("Title: \(track.currentTitle)") }
            if track.trackNumber > 0 { parts.append("Track#: \(track.trackNumber)") }
            return parts.joined(separator: " | ")
        }.joined(separator: "\n")

        let request = ChatRequest(
            model: Self.model,
            messages: [
                ChatMessage(role: "system", content: """
                    You are an expert music librarian with encyclopedic knowledge of music. Your job is to analyze a collection of audio files and organize them into the correct artist/album/track structure.

                    For each file you receive, you may get: a file path, and optionally existing metadata (which may be wrong or missing).

                    Your task:
                    1. IDENTIFY the correct artist for each track. Use your knowledge of music — if you see tracks like "Schism", "Lateralus", "Parabola" you should know these are by Tool.
                    2. GROUP tracks into the correct albums. Don't put tracks from different albums together. Use your knowledge of discographies.
                    3. CLEAN UP track titles — remove track numbers, file extensions, underscores, dashes used as separators, and other artifacts. "01 - The Grudge.flac" becomes "The Grudge".
                    4. ASSIGN correct track numbers based on the official album track listing.
                    5. Include year and genre for each album if you know them.

                    The "filename" field in each track MUST be the exact last component of the original path (e.g., "01 - The Grudge.flac") so it can be matched back to the file.

                    Respond with JSON: {"albums": [{"artist": "Artist Name", "album": "Album Title", "year": "2001", "genre": "Progressive Metal", "tracks": [{"filename": "01 - The Grudge.flac", "title": "The Grudge", "trackNumber": 1}]}]}
                    """),
                ChatMessage(role: "user", content: "Analyze and organize this music library:\n\n\(trackDescriptions)"),
            ],
            temperature: 0.1,
            max_completion_tokens: 8192,
            response_format: ResponseFormat(type: "json_object")
        )

        guard let data = await performRequest(request) else { return nil }

        do {
            let result = try JSONDecoder().decode(IdentifiedMusic.self, from: data)
            await AppLogger.info("Groq analyzed library: \(result.albums.count) albums identified", category: .content)
            return result
        } catch {
            await AppLogger.error("Failed to decode library analysis: \(error.localizedDescription)", category: .content)
            return nil
        }
    }

    nonisolated func classifyGenre(artist: String, album: String, trackTitles: [String]) async -> GenreClassification? {
        guard Self.apiKey != "YOUR_GROQ_API_KEY" else { return nil }

        let tracks = trackTitles.joined(separator: ", ")

        let request = ChatRequest(
            model: Self.model,
            messages: [
                ChatMessage(role: "system", content: "You are a music classification expert. Classify the genre. Respond with JSON: {\"genre\": \"...\", \"subGenre\": \"...\", \"mood\": \"...\"}"),
                ChatMessage(role: "user", content: "Artist: \(artist), Album: \(album), Tracks: \(tracks)"),
            ],
            temperature: 0.2,
            max_completion_tokens: 256,
            response_format: ResponseFormat(type: "json_object")
        )

        guard let data = await performRequest(request) else { return nil }

        do {
            return try JSONDecoder().decode(GenreClassification.self, from: data)
        } catch {
            await AppLogger.error("Failed to decode genre classification: \(error.localizedDescription)", category: .content)
            return nil
        }
    }

    nonisolated private func performRequest(_ chatRequest: ChatRequest, retryCount: Int = 0) async -> Data? {
        do {
            var urlRequest = URLRequest(url: Self.endpoint)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("Bearer \(Self.apiKey)", forHTTPHeaderField: "Authorization")
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONEncoder().encode(chatRequest)

            let (data, response) = try await session.data(for: urlRequest)

            guard let http = response as? HTTPURLResponse else { return nil }

            if http.statusCode == 429 && retryCount < 3 {
                let waitSeconds = [10, 20, 40][retryCount]
                await AppLogger.info("Groq rate limited, waiting \(waitSeconds)s (retry \(retryCount + 1)/3)", category: .content)
                try? await Task.sleep(for: .seconds(waitSeconds))
                return await performRequest(chatRequest, retryCount: retryCount + 1)
            }

            if http.statusCode == 413 && retryCount == 0 {
                await AppLogger.warning("Groq request too large, cannot retry", category: .content)
                return nil
            }

            guard (200...299).contains(http.statusCode) else {
                if let body = String(data: data, encoding: .utf8) {
                    await AppLogger.error("Groq API \(http.statusCode): \(body.prefix(200))", category: .content)
                }
                return nil
            }

            let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)
            guard let content = chatResponse.choices.first?.message.content else {
                await AppLogger.error("Groq API returned empty response", category: .content)
                return nil
            }

            return Data(content.utf8)
        } catch {
            await AppLogger.error("Groq API error: \(error.localizedDescription)", category: .content)
            return nil
        }
    }
}

private nonisolated struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let max_completion_tokens: Int
    let response_format: ResponseFormat?
}

private nonisolated struct ChatMessage: Codable {
    let role: String
    let content: String
}

private nonisolated struct ResponseFormat: Encodable {
    let type: String
}

private nonisolated struct ChatResponse: Decodable {
    let choices: [Choice]
    struct Choice: Decodable {
        let message: ChatMessage
    }
}
