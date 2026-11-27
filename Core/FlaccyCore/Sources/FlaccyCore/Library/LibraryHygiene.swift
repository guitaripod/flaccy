import Foundation
import Synchronization

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
        if let known = primaryArtists.withLock({ $0[raw] }) { return known }
        let primary = splitPrimaryArtist(raw)
        primaryArtists.withLock { known in
            if known.count >= primaryArtistMemoLimit { known.removeAll(keepingCapacity: true) }
            known[raw] = primary
        }
        return primary
    }

    /// The same credit is asked about once per song and once per play — a library of twelve
    /// thousand songs and a history of a hundred and sixty thousand plays name a few thousand
    /// artists — and each answer is seventeen case-insensitive searches, which was most of the
    /// CPU an iPad spent settling album credits and building Recap at launch. The answer never
    /// changes for a credit, so it is kept, up to a bound.
    private static let primaryArtists = Mutex<[String: String]>([:])
    private static let primaryArtistMemoLimit = 50_000

    private static let artistSeparators = [";", " / ", " × ", " x ", " & ", " + ", " vs. ", " vs ", " feat. ", " feat ",
                                           " ft. ", " ft ", " featuring ", " (feat.", " (ft.", " (featuring", " with "]

    private static let asciiArtistSeparators: [[UInt8]] = artistSeparators
        .filter { $0.utf8.allSatisfy { $0 < 0x80 } }
        .map { Array($0.utf8) }

    private static func splitPrimaryArtist(_ raw: String) -> String {
        if let ascii = splitPrimaryArtistASCII(raw) { return ascii }
        var name = raw
        for separator in artistSeparators {
            if let range = name.range(of: separator, options: [.caseInsensitive]) {
                name = String(name[..<range.lowerBound])
            }
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? raw : trimmed
    }

    /// The full split's answer for a plain ASCII credit: each separator is looked for in a lowercased copy, which for
    /// ASCII is exactly what the case-insensitive search matches, and the credit is cut at the same byte. Nil for a
    /// credit with any other character, which takes the full path.
    private static func splitPrimaryArtistASCII(_ raw: String) -> String? {
        var bytes = Array(raw.utf8)
        guard bytes.allSatisfy({ $0 < 0x80 }) else { return nil }
        var lowered = bytes.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }
        for separator in asciiArtistSeparators {
            guard let cut = firstOffset(of: separator, in: lowered) else { continue }
            bytes.removeSubrange(cut...)
            lowered.removeSubrange(cut...)
        }
        let trimmed = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? raw : trimmed
    }

    private static func firstOffset(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let first = needle[0]
        for start in 0...(haystack.count - needle.count) where haystack[start] == first {
            var matches = true
            for offset in 1..<needle.count where haystack[start + offset] != needle[offset] {
                matches = false
                break
            }
            if matches { return start }
        }
        return nil
    }

    /// Aggressive artist grouping key: the lead artist, diacritic-folded and
    /// stripped of case, whitespace and punctuation, so "deadmau5"/"Deadmau5",
    /// "Beyoncé"/"Beyonce", "Jay-Z"/"Jay Z" and "deadmau5 & Kaskade" all collapse
    /// to one artist.
    public static func artistKey(_ credit: String) -> String {
        normalize(primaryArtist(credit))
    }

    public static func normalize(_ value: String) -> String {
        if let ascii = asciiAlphanumericFold(value) { return ascii }
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var result = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            result.append(scalar)
        }
        return String(result)
    }

    public static func baseTitle(_ raw: String, keywords: Set<String> = wantlistKeywords) -> String {
        let lowered = raw.lowercased()
        guard mayCarryEdition(lowered) else { return normalize(lowered) }
        var title = stripDecoratedBrackets(from: lowered, keywords: keywords)
        for separator in [" - ", ": ", " – "] {
            if let range = title.range(of: separator),
               containsEditionKeyword(String(title[range.upperBound...]), keywords: keywords) {
                title = String(title[..<range.lowerBound])
            }
        }
        return normalize(title)
    }

    /// The full fold's answer for plain ASCII text, the common case for tags, without Foundation's Unicode folding:
    /// letters lowercased, digits kept, everything else dropped. Nil for text with any other character.
    private static func asciiAlphanumericFold(_ value: String) -> String? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 0x30...0x39, 0x61...0x7A: bytes.append(byte)
            case 0x41...0x5A: bytes.append(byte + 0x20)
            case 0x80...: return nil
            default: continue
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Whether a title holds a bracket or a byte that starts one of the separators an edition suffix follows
    /// (" - ", ": ", " – "). Most titles hold none, and for those every bracket and separator search comes back empty.
    private static func mayCarryEdition(_ title: String) -> Bool {
        title.utf8.contains { byte in
            byte == UInt8(ascii: "(") || byte == UInt8(ascii: "[") || byte == UInt8(ascii: "{")
                || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ":") || byte == 0xE2
        }
    }

    /// An album's title is folded once per song on it by every duplicate pass, so the answer is kept per title, up to a
    /// bound, as `primaryArtist` keeps credits.
    public static func consolidationBaseTitle(_ raw: String) -> String {
        if let known = consolidationBaseTitles.withLock({ $0[raw] }) { return known }
        let base = baseTitle(raw, keywords: consolidationKeywords)
        consolidationBaseTitles.withLock { known in
            if known.count >= primaryArtistMemoLimit { known.removeAll(keepingCapacity: true) }
            known[raw] = base
        }
        return base
    }

    private static let consolidationBaseTitles = Mutex<[String: String]>([:])

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
