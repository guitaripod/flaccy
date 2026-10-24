import Foundation

/// What to ask a lyrics server: the title and artist with edition decoration
/// and collaboration credits removed. Mirrored in Rust as
/// `linux/shared/src/lyrics/query.rs`.
public enum LyricsQuery {

    /// Words that mark a bracketed or dashed title suffix as the same
    /// recording re-released or credited differently. Live, acoustic, demo,
    /// instrumental and remix are left out on purpose: those are different
    /// recordings whose lyrics time differently.
    public static let editionKeywords: [String] = [
        "remaster",
        "remastered",
        "remasters",
        "mono",
        "stereo",
        "explicit",
        "clean",
        "deluxe",
        "edition",
        "bonus",
        "reissue",
        "reissued",
        "expanded",
        "anniversary",
        "feat",
        "featuring",
        "ft",
    ]

    private static let titleSuffixSeparators = [" - ", " \u{2013} ", ": "]

    private static let featuringMarkers = [" feat. ", " feat ", " ft. ", " ft ", " featuring "]

    private static let artistSeparators = [
        ";",
        " / ",
        " feat. ",
        " feat ",
        " ft. ",
        " ft ",
        " featuring ",
        " (feat.",
        " (ft.",
    ]

    /// The title a lyrics server is most likely to know the song by:
    /// bracketed and dashed edition decoration removed ("Song (Remastered
    /// 2011)", "Song - 2011 Remaster", "Song [Deluxe]"), a trailing featuring
    /// clause cut, case and punctuation kept. Falls back to the input when
    /// nothing would be left.
    public static func cleanTitle(_ title: String) -> String {
        let withoutGroups = removeDecoratedGroups(Array(title.unicodeScalars))
        let withoutSuffix = cutDecoratedSuffix(withoutGroups)
        let withoutFeaturing = cutFeaturing(withoutSuffix)
        let collapsed = withoutFeaturing
            .split(omittingEmptySubsequences: true, whereSeparator: LyricsText.isWhitespace)
            .map { LyricsText.string($0) }
            .joined(separator: " ")
        return collapsed.isEmpty ? LyricsText.trim(title) : collapsed
    }

    /// The first credited artist of a collaboration: the text before a `;`,
    /// ` / ` or featuring marker. Names that merely contain `&` or `,` stay
    /// whole.
    public static func leadArtist(_ artist: String) -> String {
        let lead: String
        if let index = earliestMarker(artistSeparators, in: artist),
            let head = head(of: artist, before: index)
        {
            lead = LyricsText.trim(head)
        } else {
            lead = LyricsText.trim(artist)
        }
        return lead.isEmpty ? LyricsText.trim(artist) : lead
    }

    private static func contains(keywordIn text: String) -> Bool {
        text.lowercased()
            .unicodeScalars
            .split(omittingEmptySubsequences: true) { !CharacterSet.alphanumerics.contains($0) }
            .contains { editionKeywords.contains(LyricsText.string($0)) }
    }

    /// Drops every top-level `(…)` or `[…]` group that holds an edition
    /// keyword. A group that never closes is kept as written.
    private static func removeDecoratedGroups(_ characters: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(characters.count)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "(" || character == "[",
                let close = matchingClose(characters, open: index),
                contains(keywordIn: LyricsText.string(characters[(index + 1)..<close]))
            {
                index = close + 1
                continue
            }
            out.append(character)
            index += 1
        }
        return out
    }

    private static func matchingClose(_ characters: [Unicode.Scalar], open: Int) -> Int? {
        var depth = 0
        for offset in 0..<(characters.count - open) {
            let character = characters[open + offset]
            if character == "(" || character == "[" {
                depth += 1
            } else if character == ")" || character == "]" {
                depth -= 1
                if depth == 0 {
                    return open + offset
                }
            }
        }
        return nil
    }

    /// Cuts at the first separator whose suffix holds an edition keyword.
    private static func cutDecoratedSuffix(_ text: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var cut = text.count
        for separator in titleSuffixSeparators {
            let needle = Array(separator.unicodeScalars)
            if let index = find(needle, in: text),
                contains(keywordIn: LyricsText.string(text[(index + needle.count)...]))
            {
                cut = min(cut, index)
            }
        }
        return Array(text[..<cut])
    }

    private static func cutFeaturing(_ text: [Unicode.Scalar]) -> [Unicode.Scalar] {
        let string = LyricsText.string(text)
        guard let index = earliestMarker(featuringMarkers, in: string),
            let cutText = head(of: string, before: index)
        else { return text }
        return Array(cutText.unicodeScalars)
    }

    /// The earliest UTF-8 byte offset at which any marker occurs in the
    /// lowercased text, or nil when none does or lowercasing changed the
    /// text's byte length, in which case offsets in the lowercase form no
    /// longer point into the original.
    private static func earliestMarker(_ markers: [String], in text: String) -> Int? {
        let lower = Array(text.lowercased().utf8)
        guard lower.count == text.utf8.count else { return nil }
        return markers.compactMap { find(Array($0.utf8), in: lower) }.min()
    }

    /// The text before a UTF-8 byte offset, or nil when the offset falls
    /// inside a multi-byte scalar (Rust `str::get(..index)`).
    private static func head(of text: String, before index: Int) -> String? {
        let bytes = Array(text.utf8)
        guard index <= bytes.count else { return nil }
        if index < bytes.count && (bytes[index] & 0xC0) == 0x80 {
            return nil
        }
        return String(decoding: bytes[..<index], as: UTF8.self)
    }

    private static func find<Element: Equatable>(_ needle: [Element], in haystack: [Element]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            var matches = true
            for offset in 0..<needle.count where haystack[start + offset] != needle[offset] {
                matches = false
                break
            }
            if matches {
                return start
            }
        }
        return nil
    }
}
