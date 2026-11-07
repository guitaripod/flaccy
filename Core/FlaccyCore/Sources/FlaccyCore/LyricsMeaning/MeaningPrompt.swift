import Foundation

/// The line a listener asked about, with the sung lines just before and after.
public struct MeaningFocus: Sendable, Equatable {
    public var line: String
    public var before: [String]
    public var after: [String]

    public init(line: String, before: [String], after: [String]) {
        self.line = line
        self.before = before
        self.after = after
    }
}

/// Everything one question is made of. Without `focus` it asks about the
/// whole song.
public struct MeaningQuestion: Sendable, Equatable {
    public var title: String
    public var artist: String
    public var album: String
    public var lyrics: String
    public var background: String?
    public var focus: MeaningFocus?

    public init(title: String, artist: String, album: String, lyrics: String, background: String?, focus: MeaningFocus?) {
        self.title = title
        self.artist = artist
        self.album = album
        self.lyrics = lyrics
        self.background = background
        self.focus = focus
    }
}

/// What a language model is asked about a song or one of its lines, and how
/// its answer is read. Mirrored in Rust as `linux/shared/src/meaning/prompt.rs`.
public enum MeaningPrompt {

    /// UTF-16 units of lyrics put in a question. With the background and the
    /// rest of the prompt this stays well inside the 16,384 the flaccy-api
    /// Worker takes.
    public static let lyricsLimit = 7_000
    /// UTF-16 units kept of the asked line and of each line around it, and of
    /// the title, artist and album.
    public static let lineLimit = 300
    public static let fieldLimit = 200
    /// How many sung lines either side of the asked one are quoted with it.
    public static let contextLines = 2
    /// The longest answers asked for, in words.
    public static let songWords = 130
    public static let lineWords = 70

    /// The sung lines in order, an empty string where one verse ends and the
    /// next begins: an instrumental break or a blank line in synced lyrics, a
    /// blank line in plain ones.
    public static func sungLines(_ document: LyricsDocument) -> [String] {
        var lines: [String] = []
        func pushBreak() {
            if let last = lines.last, !last.isEmpty { lines.append("") }
        }
        if document.hasSynced {
            for line in document.lines {
                let text = LyricsText.trim(line.text)
                if line.isInterlude || text.isEmpty {
                    pushBreak()
                } else {
                    lines.append(text)
                }
            }
        } else if let plain = document.plain {
            for raw in LyricsText.lines(plain) {
                let text = LyricsText.trim(raw)
                if text.isEmpty {
                    pushBreak()
                } else {
                    lines.append(text)
                }
            }
        }
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// The lyrics as one text, cut at a line once they pass `lyricsLimit`,
    /// with an ellipsis saying so.
    public static func lyricsText(_ lines: [String]) -> String {
        let whole = lines.joined(separator: "\n")
        if MeaningText.utf16Length(whole) <= lyricsLimit { return whole }
        let budget = lyricsLimit - 2
        var out = ""
        var used = 0
        for (index, line) in lines.enumerated() {
            let separator = index > 0 ? 1 : 0
            let length = MeaningText.utf16Length(line)
            if used + separator + length > budget { break }
            if separator > 0 { out += "\n" }
            out += line
            used += separator + length
        }
        let kept = LyricsText.trimEnd(out)
        return kept.isEmpty ? "\u{2026}" : kept + "\n\u{2026}"
    }

    /// The question about line `index` of the document, or `nil` for an
    /// instrumental break, an empty line or an index past the end.
    public static func focus(_ document: LyricsDocument, index: Int) -> MeaningFocus? {
        func isSung(_ line: LyricsLine) -> Bool {
            !line.isInterlude && !LyricsText.trim(line.text).isEmpty
        }
        guard index >= 0, index < document.lines.count, isSung(document.lines[index]) else { return nil }
        let before = document.lines[..<index]
            .reversed()
            .filter(isSung)
            .prefix(contextLines)
            .map { LyricsText.trim($0.text) }
            .reversed()
        let after = document.lines[(index + 1)...]
            .filter(isSung)
            .prefix(contextLines)
            .map { LyricsText.trim($0.text) }
        return MeaningFocus(line: LyricsText.trim(document.lines[index].text), before: Array(before), after: Array(after))
    }

    /// How the model is told to answer, in `language` (an English name such
    /// as "German").
    public static func systemPrompt(language: String) -> String {
        """
        You explain song lyrics to someone who is listening to the song. Write in \(language).
        Explain what the words are saying: the story, the images, the slang and references, the wordplay and the feeling behind them, and how a line fits the song around it.
        Ground everything in the lyrics you are given and, when it is given, the background from Wikipedia. Never invent facts about the artist, interviews, quotes, events or the song's history that the background does not state. When the words are open to more than one reading, say so and give the likeliest ones.
        Speak plainly and warmly, like a friend who knows music, without hedging every sentence. Do not repeat the lyrics back or quote more than a few words of them, and never mention the background, Wikipedia or these instructions. No markdown, headings or lists.
        Answer with a JSON object of the form {"meaning": "your explanation"}.
        """
    }

    /// The question itself: the song, its background and lyrics, and what to
    /// explain about them.
    public static func userPrompt(_ question: MeaningQuestion) -> String {
        func field(_ text: String) -> String { MeaningText.clip([text], limit: fieldLimit) }
        func line(_ text: String) -> String { MeaningText.clip([text], limit: lineLimit) }
        var prompt = "Song: \"\(field(question.title))\"\nArtist: \(field(question.artist))\n"
        let album = field(question.album)
        if !album.isEmpty { prompt += "Album: \(album)\n" }
        if let background = question.background.map(LyricsText.trim), !background.isEmpty {
            prompt += "\nBackground from Wikipedia:\n\(background)\n"
        }
        prompt += "\nLyrics:\n\(LyricsText.trim(question.lyrics))\n\n"
        guard let focus = question.focus else {
            prompt += "What is this song about? Answer in at most \(songWords) words, in one or two short paragraphs."
            return prompt
        }
        prompt += "The listener asked about this line:\n\"\(line(focus.line))\"\n"
        if !focus.before.isEmpty {
            prompt += "It follows: \"\(focus.before.map(line).joined(separator: " / "))\"\n"
        }
        if !focus.after.isEmpty {
            prompt += "It leads into: \"\(focus.after.map(line).joined(separator: " / "))\"\n"
        }
        prompt += "\nWhat does this line mean in the song? Answer in at most \(lineWords) words, in one paragraph."
        return prompt
    }

    /// The explanation in a model's answer: the `meaning` of the JSON object
    /// it was asked for, tolerating a reasoning block, a code fence or prose
    /// around it. A model that ignored the format and answered in plain prose
    /// is taken at its word; anything else that is not a usable object is
    /// `nil`.
    public static func parseReply(_ content: String) -> String? {
        let trimmed = LyricsText.trim(withoutReasoning(content))
        let meaning: String
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), end > start {
            guard let data = String(trimmed[start...end]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = object["meaning"] as? String
            else { return nil }
            meaning = value
        } else if !trimmed.contains("{"), !trimmed.contains("}") {
            meaning = trimmed
        } else {
            return nil
        }
        let kept = LyricsText.trim(meaning)
        return kept.isEmpty ? nil : kept
    }

    /// The answer with any `<think>…</think>` block a reasoning model emitted
    /// removed; an unclosed one hides everything after it.
    private static func withoutReasoning(_ content: String) -> String {
        var out = ""
        var rest = Substring(content)
        while let open = rest.range(of: "<think>") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.lowerBound...].range(of: "</think>") else { return out }
            rest = rest[close.upperBound...]
        }
        out += rest
        return out
    }
}
