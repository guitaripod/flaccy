import Foundation

/// A search result: the article's title and its short description, which for
/// a song reads like "1991 single by Nirvana".
public struct MeaningArticleCandidate: Sendable, Equatable {
    public var title: String
    public var description: String

    public init(title: String, description: String) {
        self.title = title
        self.description = description
    }
}

/// One `== Heading ==` part of an article's plain text.
public struct MeaningSection: Sendable, Equatable {
    public var heading: String
    public var level: Int
    public var body: [String]
}

public struct SongStorySection: Sendable, Equatable, Codable {
    public var heading: String
    public var body: String

    public init(heading: String, body: String) {
        self.heading = heading
        self.body = body
    }
}

/// What Wikipedia says about a song: the introduction and the sections about
/// its meaning and making, cut to size, with where they came from.
public struct SongStory: Sendable, Equatable, Codable {
    public var article: String
    public var url: String
    public var language: String
    public var lead: String
    public var sections: [SongStorySection]

    public init(article: String, url: String, language: String, lead: String, sections: [SongStorySection]) {
        self.article = article
        self.url = url
        self.language = language
        self.lead = lead
        self.sections = sections
    }
}

/// The Wikipedia to read a story from: its subdomain, and the script variant
/// Chinese articles are converted to.
public struct MeaningWiki: Sendable, Equatable {
    public var language: String
    public var variant: String?

    public init(language: String, variant: String?) {
        self.language = language
        self.variant = variant
    }
}

/// Finding a song's own Wikipedia article and the parts of it about what the
/// song means. Mirrored in Rust as `linux/shared/src/meaning/wikipedia.rs`.
public enum MeaningWikipedia {

    /// How many search results are weighed before giving up on an article.
    public static let searchLimit = 10
    /// UTF-16 units kept of the article's introduction, of each section, and
    /// of everything handed to the model as background.
    public static let leadLimit = 1_500
    public static let sectionLimit = 2_000
    public static let backgroundLimit = 3_000
    /// The most sections of an article shown beside its introduction.
    public static let mostSections = 3

    /// Words in a section heading that promise the song's meaning or making.
    private static let meaningWords: Set<String> = [
        "background", "composition", "concept", "content", "inspiration", "inspirations",
        "interpretation", "interpretations", "lyric", "lyrical", "lyrics", "meaning", "meanings",
        "message", "origin", "origins", "song", "story", "subject", "theme", "themes", "writing",
        "written", "narrative",
    ]

    /// Words that mark a heading as about the record's life after it was
    /// made, which win over a meaning word in the same heading.
    private static let offTopicWords: Set<String> = [
        "accolades", "awards", "bibliography", "certification", "certifications", "chart", "charts",
        "controversy", "cover", "covers", "credits", "critical", "culture", "format", "formats",
        "legacy", "links", "listing", "live", "notes", "parodies", "performances", "personnel",
        "reception", "references", "release", "remixes", "sales", "versions", "video",
    ]

    private static let titleDashes = [" - ", " \u{2013} ", " \u{2014} "]

    /// The Wikipedia for an app localization such as `de`, `pt-BR` or
    /// `zh-Hant`.
    public static func wiki(for localization: String) -> MeaningWiki {
        let lower = LyricsText.trim(localization).lowercased().replacingOccurrences(of: "_", with: "-")
        let variant: String?
        switch lower {
        case "zh-hans", "zh-cn", "zh-sg": variant = "zh-cn"
        case "zh-hant", "zh-tw", "zh-hk", "zh-mo": variant = "zh-tw"
        default: variant = nil
        }
        let language = lower.split(separator: "-", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let valid = !language.isEmpty && language.unicodeScalars.allSatisfy { ("a"..."z").contains($0) }
        return MeaningWiki(language: valid ? language : "en", variant: variant)
    }

    /// The song a recording is a version of, for finding writing about it: a
    /// leading track number removed, then the lyrics query's cleaning, then
    /// every bracketed group and a dashed suffix ("- Live", "- Radio Edit").
    /// A live take or a remix means what the song means.
    public static func songTitle(_ title: String) -> String {
        let cleaned = LyricsQuery.cleanTitle(stripTrackNumber(LyricsText.trim(title)))
        let ungrouped = removeGroups(cleaned)
        let undashed = titleDashes
            .compactMap { ungrouped.range(of: $0)?.lowerBound }
            .min()
            .map { String(ungrouped[..<$0]) } ?? ungrouped
        let collapsed = undashed
            .unicodeScalars
            .split(omittingEmptySubsequences: true, whereSeparator: LyricsText.isWhitespace)
            .map { LyricsText.string($0) }
            .joined(separator: " ")
        return collapsed.isEmpty ? cleaned : collapsed
    }

    /// What to search Wikipedia for.
    public static func searchTerms(title: String, artist: String) -> String {
        "\(songTitle(title)) \(LyricsQuery.leadArtist(artist)) song"
    }

    /// The first search result that is this song's own article: its title,
    /// less a trailing disambiguation, reads as the song's title, and its
    /// description or disambiguation says it is a song or single by the lead
    /// artist.
    public static func pickArticle(_ candidates: [MeaningArticleCandidate], title: String, artist: String) -> Int? {
        let wantedTitle = tokens(songTitle(title))
        let wantedArtist = tokens(LyricsQuery.leadArtist(artist))
        guard !wantedTitle.isEmpty, !wantedArtist.isEmpty else { return nil }
        return candidates.firstIndex { candidate in
            let (base, qualifier) = splitDisambiguation(candidate.title)
            guard tokens(base) == wantedTitle else { return false }
            let description = tokens(candidate.description)
            let qualifierWords = tokens(qualifier)
            let isSong = [description, qualifierWords].contains { words in
                words.contains("song") || words.contains("single")
            }
            let byArtist = containsRun(description, wantedArtist) || containsRun(qualifierWords, wantedArtist)
            return isSong && byArtist
        }
    }

    /// Splits the plain text the TextExtracts API returns with
    /// `exsectionformat=wiki` into its introduction and its sections, each a
    /// list of paragraphs.
    public static func parseExtract(_ extract: String) -> (lead: [String], sections: [MeaningSection]) {
        var lead: [String] = []
        var sections: [MeaningSection] = []
        for raw in LyricsText.lines(extract) {
            let line = LyricsText.trim(raw)
            guard !line.isEmpty else { continue }
            if let (level, heading) = heading(of: line) {
                sections.append(MeaningSection(heading: heading, level: level, body: []))
                continue
            }
            if sections.isEmpty {
                lead.append(line)
            } else {
                sections[sections.count - 1].body.append(line)
            }
        }
        return (lead, sections)
    }

    /// Whether a section heading promises what the song means or how it was
    /// made.
    public static func isMeaningHeading(_ heading: String) -> Bool {
        let words = tokens(heading)
        return words.contains(where: meaningWords.contains) && !words.contains(where: offTopicWords.contains)
    }

    /// The story an article tells: its introduction, and with `withSections`
    /// (an English article, whose headings can be read) up to `mostSections`
    /// sections about the song's meaning, each cut to size. `nil` when
    /// nothing is left.
    public static func story(
        article: String, url: String, language: String, extract: String, withSections: Bool
    ) -> SongStory? {
        let parsed = parseExtract(extract)
        let lead = MeaningText.clip(parsed.lead, limit: leadLimit)
        let sections: [SongStorySection] = withSections
            ? parsed.sections
                .filter { !$0.body.isEmpty && isMeaningHeading($0.heading) }
                .prefix(mostSections)
                .map { SongStorySection(heading: $0.heading, body: MeaningText.clip($0.body, limit: sectionLimit)) }
                .filter { !$0.body.isEmpty }
            : []
        guard !lead.isEmpty || !sections.isEmpty else { return nil }
        return SongStory(article: article, url: url, language: language, lead: lead, sections: sections)
    }

    /// The story as one passage for the model, sections introduced by their
    /// headings, cut to `backgroundLimit`.
    public static func background(_ story: SongStory) -> String {
        var paragraphs = story.lead.components(separatedBy: "\n\n")
        for section in story.sections {
            let parts = section.body.components(separatedBy: "\n\n")
            if let first = parts.first {
                paragraphs.append("\(section.heading): \(first)")
            }
            paragraphs.append(contentsOf: parts.dropFirst())
        }
        return MeaningText.clip(paragraphs, limit: backgroundLimit)
    }

    /// `== Heading ==` at any depth, as its depth and text.
    private static func heading(of line: String) -> (Int, String)? {
        let scalars = Array(line.unicodeScalars)
        let level = scalars.prefix(while: { $0 == "=" }).count
        guard level >= 2, scalars.count > level * 2,
              scalars.suffix(level).allSatisfy({ $0 == "=" })
        else { return nil }
        let inner = LyricsText.trim(LyricsText.string(scalars[level..<(scalars.count - level)]))
        guard !inner.isEmpty else { return nil }
        return (level, inner)
    }

    /// Lowercased runs of letters and digits, the way titles and descriptions
    /// are compared.
    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func containsRun(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        return (0...(haystack.count - needle.count)).contains { start in
            Array(haystack[start..<(start + needle.count)]) == needle
        }
    }

    /// "Kim (song)" as "Kim" and "song"; a title without a trailing group as
    /// itself and nothing.
    private static func splitDisambiguation(_ title: String) -> (String, String) {
        let trimmed = LyricsText.trim(title)
        guard trimmed.hasSuffix(")"), let open = trimmed.range(of: " (", options: .backwards) else {
            return (trimmed, "")
        }
        let base = String(trimmed[..<open.lowerBound])
        let qualifier = String(trimmed[open.upperBound...].dropLast())
        return (base, qualifier)
    }

    /// "09 - Song" and "9. Song" as "Song"; a number that is the title's own
    /// first word ("99 Problems") stays.
    private static func stripTrackNumber(_ title: String) -> String {
        let scalars = Array(title.unicodeScalars)
        let digits = scalars.prefix(while: { ("0"..."9").contains($0) }).count
        guard digits > 0, digits <= 3 else { return title }
        let rest = LyricsText.trimStart(Array(scalars[digits...]))
        guard let mark = rest.first, mark == "-" || mark == "." else { return title }
        let after = Array(rest.dropFirst())
        guard let space = after.first, LyricsText.isWhitespace(space) else { return title }
        let remainder = LyricsText.string(LyricsText.trimStart(after))
        return remainder.isEmpty ? title : remainder
    }

    /// The text with every top-level `(…)` or `[…]` group removed; a group
    /// that never closes is kept as written.
    private static func removeGroups(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "(" || scalar == "[", let close = matchingClose(scalars, open: index) {
                index = close + 1
                continue
            }
            out.append(scalar)
            index += 1
        }
        return String(out)
    }

    private static func matchingClose(_ scalars: [Unicode.Scalar], open: Int) -> Int? {
        var depth = 0
        for index in open..<scalars.count {
            switch scalars[index] {
            case "(", "[":
                depth += 1
            case ")", "]":
                depth -= 1
                if depth == 0 { return index }
            default:
                break
            }
        }
        return nil
    }
}
