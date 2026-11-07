import FlaccyCore
import FlaccyEngine
import Foundation
import MidgarCore

/// What Wikipedia had to say about a song.
nonisolated enum MeaningStoryOutcome: Sendable, Equatable {
    case found(SongStory)
    case missing
    case failed(WikipediaClient.Failure)
}

/// Why no reading came back, each with its own next step for the person.
nonisolated enum MeaningFailure: Sendable, Equatable {
    case needsEntitlement
    case unreachable
    case quotaReached(resetsAt: Date)
    case unavailable
    case unreadable
}

nonisolated enum MeaningReading: Sendable, Equatable {
    case answered(String)
    case failed(MeaningFailure)
}

/// The song a Meaning sheet is about.
nonisolated struct MeaningSong: Sendable, Equatable {
    let title: String
    let artist: String
    let album: String
}

/// What a song's lyrics mean on the Apple clients: the song's story from
/// Wikipedia, and a reading of the whole song or one line by flaccy-api's AI,
/// both kept in the library database. Mirrors `linux/src/meaning`, which asks
/// a model on the person's own computer instead.
nonisolated final class LyricsMeaningService: Sendable {

    static let shared = LyricsMeaningService()

    private let wikipedia = WikipediaClient()
    private static let maxCompletionTokens = 900
    private static let temperature = 0.4

    /// The localization the app is showing, which picks the Wikipedia and the
    /// language of the answer.
    static var localization: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }

    /// The English name of that language, the way the model is told it.
    static var languageName: String {
        Locale(identifier: "en").localizedString(forIdentifier: localization) ?? "English"
    }

    /// The song's story: a fresh stored answer, else Wikipedia's, which is
    /// then stored; a stale stored story stands in when Wikipedia cannot be
    /// reached.
    func story(for song: MeaningSong) async -> MeaningStoryOutcome {
        let language = Self.localization
        let stored = try? DatabaseManager.shared.lyricMeaning(
            trackTitle: song.title, artist: song.artist, scope: MeaningCache.storyScope, language: language)
        if let stored, MeaningCache.isFresh(scope: MeaningCache.storyScope, hasBody: !stored.body.isEmpty, ageDays: stored.ageDays) {
            return Self.decode(stored.body)
        }
        do throws(WikipediaClient.Failure) {
            let found = try await lookUp(song, wiki: MeaningWikipedia.wiki(for: language))
            let body = found.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            try? DatabaseManager.shared.saveLyricMeaning(
                trackTitle: song.title, artist: song.artist, scope: MeaningCache.storyScope, language: language, body: body)
            return found.map(MeaningStoryOutcome.found) ?? .missing
        } catch {
            if let stored, !stored.body.isEmpty { return Self.decode(stored.body) }
            MidgarLog.notice("Wikipedia lookup failed: \(error)", category: .content)
            return .failed(error)
        }
    }

    /// Finds the song's article on English Wikipedia, then reads it from the
    /// person's own Wikipedia when it has the article (the introduction only,
    /// since its headings cannot be read), else in English with the sections
    /// about the song's meaning.
    private func lookUp(_ song: MeaningSong, wiki: MeaningWiki) async throws(WikipediaClient.Failure) -> SongStory? {
        let linked = wiki.language == "en" ? nil : wiki.language
        let pages = try await wikipedia.search(
            MeaningWikipedia.searchTerms(title: song.title, artist: song.artist), linkedLanguage: linked)
        guard let index = MeaningWikipedia.pickArticle(pages.map(\.candidate), title: song.title, artist: song.artist) else {
            return nil
        }
        let page = pages[index]
        if linked != nil, let localTitle = page.linkedTitle,
           let article = try await wikipedia.article(localTitle, wiki: wiki, introOnly: true),
           let story = MeaningWikipedia.story(
               article: article.title, url: article.url, language: wiki.language, extract: article.extract, withSections: false) {
            return story
        }
        let english = MeaningWiki(language: "en", variant: nil)
        guard let article = try await wikipedia.article(page.candidate.title, wiki: english, introOnly: false) else { return nil }
        return MeaningWikipedia.story(
            article: article.title, url: article.url, language: "en", extract: article.extract, withSections: true)
    }

    private static func decode(_ body: String) -> MeaningStoryOutcome {
        guard let data = body.data(using: .utf8), let story = try? JSONDecoder().decode(SongStory.self, from: data) else {
            return .missing
        }
        return .found(story)
    }

    /// A reading of the song, or of `focus` within it: a stored one, else
    /// flaccy-api's, which is then stored. AI comes with Flaccy Lifetime and
    /// the trial, like the library cleanup.
    func reading(
        for song: MeaningSong, document: LyricsDocument, focus: MeaningFocus?, story: SongStory?
    ) async -> MeaningReading {
        let language = Self.localization
        let scope = focus.map { MeaningCache.lineScope($0.line) } ?? MeaningCache.songScope
        if let stored = try? DatabaseManager.shared.lyricMeaning(
            trackTitle: song.title, artist: song.artist, scope: scope, language: language),
           MeaningCache.isFresh(scope: scope, hasBody: !stored.body.isEmpty, ageDays: stored.ageDays) {
            return .answered(stored.body)
        }
        guard await MainActor.run(body: { PurchaseManager.shared.allowsPlayback }) else {
            return .failed(.needsEntitlement)
        }
        let question = MeaningQuestion(
            title: song.title, artist: song.artist, album: song.album,
            lyrics: MeaningPrompt.lyricsText(MeaningPrompt.sungLines(document)),
            background: story.map(MeaningWikipedia.background), focus: focus)
        let request = MeaningChatRequest(
            messages: [
                MeaningChatMessage(role: "system", content: MeaningPrompt.systemPrompt(language: Self.languageName)),
                MeaningChatMessage(role: "user", content: MeaningPrompt.userPrompt(question)),
            ],
            temperature: Self.temperature,
            max_completion_tokens: Self.maxCompletionTokens,
            response_format: MeaningResponseFormat(type: "json_object")
        )
        let reading = await ask(request)
        if case .answered(let text) = reading {
            try? DatabaseManager.shared.saveLyricMeaning(
                trackTitle: song.title, artist: song.artist, scope: scope, language: language, body: text)
        }
        return reading
    }

    private func ask(_ request: MeaningChatRequest) async -> MeaningReading {
        let reply: FlaccyAPIClient.ProxyReply
        do {
            reply = try await FlaccyMidgar.shared.api.postMetadata(request)
        } catch {
            MidgarLog.notice("Lyric meaning request failed: \(error.localizedDescription)", category: .content)
            return .failed(error is URLError ? .unreachable : .unavailable)
        }
        let errorCode = (try? JSONDecoder().decode(MeaningProxyError.self, from: reply.body))?.error
        switch AIProxyReply.classify(status: reply.status, errorCode: errorCode, retryAfter: reply.retryAfter, now: Date()) {
        case .answer:
            break
        case .quotaReached(let resetsAt):
            return .failed(.quotaReached(resetsAt: resetsAt))
        case .busy, .payloadTooLarge, .unavailable:
            MidgarLog.notice("Lyric meaning proxy answered \(reply.status) \(errorCode ?? "")", category: .content)
            return .failed(.unavailable)
        }
        guard let response = try? JSONDecoder().decode(MeaningChatResponse.self, from: reply.body),
              let content = response.choices.first?.message.content,
              let meaning = MeaningPrompt.parseReply(content)
        else {
            MidgarLog.notice("Lyric meaning reply could not be read", category: .content)
            return .failed(.unreadable)
        }
        return .answered(meaning)
    }
}

private nonisolated struct MeaningChatRequest: Encodable, Sendable {
    let messages: [MeaningChatMessage]
    let temperature: Double
    let max_completion_tokens: Int
    let response_format: MeaningResponseFormat
}

private nonisolated struct MeaningChatMessage: Codable, Sendable {
    let role: String
    let content: String
}

private nonisolated struct MeaningResponseFormat: Encodable, Sendable {
    let type: String
}

private nonisolated struct MeaningChatResponse: Decodable {
    let choices: [Choice]
    struct Choice: Decodable {
        let message: MeaningChatMessage
    }
}

private nonisolated struct MeaningProxyError: Decodable {
    let error: String
}
