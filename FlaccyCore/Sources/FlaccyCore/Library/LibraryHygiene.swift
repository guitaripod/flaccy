import Foundation

/// Shared library-hygiene primitives: edition-aware title/artist normalization,
/// duplicate-track grouping, and album-variation consolidation. This is the
/// single source of truth reused by wantlist ownership matching and the desktop
/// "Clean Up Library" feature; the Linux app mirrors this exact spec in
/// `linux/src/hygiene.rs`, so any change here must be reflected there.
public enum LibraryHygiene {

    public static let wantlistKeywords: Set<String> = [
        "deluxe", "edition", "remaster", "bonus", "expanded", "anniversary",
        "special", "extended", "complete", "reissue", "version", "collector",
        "platinum", "legacy", "super", "tour", "feat", "ft.", "with", "explicit",
        "clean", "mono", "stereo", "single", "ep",
    ]

    /// The consolidation set intentionally drops `single`, `ep`, `with`, `feat`,
    /// `ft.` and `version` so a standalone single or an acoustic/live version is
    /// never silently folded into the album; `bonus` still catches "Bonus Track
    /// Version". It adds past-tense/plural edition forms the exact-word matcher
    /// would otherwise miss ("Remastered", "Remixes") since those are among the
    /// most common variation suffixes.
    public static let consolidationKeywords: Set<String> =
        wantlistKeywords
        .subtracting(["single", "ep", "with", "feat", "ft.", "version"])
        .union(["remastered", "remasters", "remix", "remixed", "remixes", "reissued"])

    /// The lead artist of a possibly-collaborative credit: the portion before
    /// the first multi-artist separator, with any trailing "feat."/"featuring"
    /// clause stripped. Only splits on separators that unambiguously join
    /// artists (";", "/", "×") so single names containing "&" or "," ("Corvid &
    /// Crane", "Earth, Wind & Fire") are preserved.
    public static func primaryArtist(_ raw: String) -> String {
        var name = raw
        for separator in [";", " / ", " × ", " x ", " & ", " + ", " vs. ", " vs ", " feat. ", " feat ",
                          " ft. ", " ft ", " featuring ", " (feat.", " (ft.", " (featuring", " with "] {
            if let range = name.range(of: separator, options: [.caseInsensitive]) {
                name = String(name[..<range.lowerBound])
            }
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? raw : trimmed
    }

    /// Aggressive artist grouping key: the lead artist, diacritic-folded and
    /// stripped of case, whitespace and punctuation, so "deadmau5"/"Deadmau5",
    /// "Beyoncé"/"Beyonce", "Jay-Z"/"Jay Z" and "deadmau5 & Kaskade" all collapse
    /// to one artist.
    public static func artistKey(_ credit: String) -> String {
        normalize(primaryArtist(credit))
    }

    public static func normalize(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var result = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            result.append(scalar)
        }
        return String(result)
    }

    public static func baseTitle(_ raw: String, keywords: Set<String> = wantlistKeywords) -> String {
        var title = stripDecoratedBrackets(from: raw.lowercased(), keywords: keywords)
        for separator in [" - ", ": ", " – "] {
            if let range = title.range(of: separator),
               containsEditionKeyword(String(title[range.upperBound...]), keywords: keywords) {
                title = String(title[..<range.lowerBound])
            }
        }
        return normalize(title)
    }

    public static func consolidationBaseTitle(_ raw: String) -> String {
        baseTitle(raw, keywords: consolidationKeywords)
    }

    public static func matchKey(title: String, artist: String, keywords: Set<String> = wantlistKeywords) -> String {
        normalize(artist) + "\u{0}" + baseTitle(title, keywords: keywords)
    }

    /// Album identity for edition folding: lead artist only (feat./with stripped)
    /// so a track tagged "50 Cent Feat. Eminem" still sits on the 50 Cent album.
    public static func consolidationKey(title: String, artist: String) -> String {
        artistKey(artist) + "\u{0}" + consolidationBaseTitle(title)
    }

    private static func stripDecoratedBrackets(from value: String, keywords: Set<String>) -> String {
        var result = value
        for (open, close) in [("(", ")"), ("[", "]"), ("{", "}")] {
            var searchStart = result.startIndex
            while let openRange = result.range(of: open, range: searchStart..<result.endIndex),
                  let closeRange = result.range(of: close, range: openRange.upperBound..<result.endIndex) {
                let segment = String(result[openRange.upperBound..<closeRange.lowerBound])
                if containsEditionKeyword(segment, keywords: keywords) {
                    result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
                    searchStart = result.startIndex
                } else {
                    searchStart = closeRange.upperBound
                }
            }
        }
        return result
    }

    private static func containsEditionKeyword(_ segment: String, keywords: Set<String>) -> Bool {
        let words = segment.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return words.contains { keywords.contains($0) }
            || (keywords.contains("ft.") && segment.lowercased().contains("ft."))
    }

    public static func isLossless(_ codec: String?) -> Bool {
        guard let codec else { return false }
        return ["FLAC", "ALAC", "WAV", "AIFF", "AIF"].contains(codec.uppercased())
    }

    public struct AlbumVariant: Sendable, Hashable {
        public let title: String
        public let artist: String

        public init(title: String, artist: String) {
            self.title = title
            self.artist = artist
        }
    }
}
