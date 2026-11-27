import Foundation
import XCTest
@testable import FlaccyCore

/// The ASCII, no-edition and memo fast paths in `LibraryHygiene` must give exactly what the full Unicode path gives, or
/// duplicate detection, mixes and album folding would change for songs whose tags happen to be plain ASCII.
final class LibraryHygieneFastPathTests: XCTestCase {

    private static let pieces = [
        "a", "Z", "q", "7", "0", " ", "-", " - ", ": ", " – ", "(", ")", "[", "]", "{", "}", "'", ".", ",", "&", "/",
        "Deluxe", "Edition", "remastered", "Remaster 2011", "feat.", "ft.", "Live", "Mono", "EP", "Bonus Track",
        ";", " / ", " × ", " x ", " X ", " & ", " + ", " vs. ", " VS ", " Feat. ", " FEAT ", " ft. ", " Ft ",
        " featuring ", " (feat.", " (Ft.", " (FEATURING", " with ", " With ", "\t", "\n",
        "é", "É", "ß", "İ", "ı", "Σ", "ς", "Ø", "æ", "Å", "ü", "ñ", "東京", "事変", "한", "😀", "ﬁ", "Ⅻ", "½", "\u{301}",
    ]

    func testFastPathsMatchTheFullFold() {
        var generator = SplitMix(seed: 0x5EED_F1AC)
        for _ in 0..<20_000 {
            let length = Int(generator.next() % 9) + 1
            let text = (0..<length).map { _ in Self.pieces[Int(generator.next() % UInt64(Self.pieces.count))] }.joined()
            XCTAssertEqual(LibraryHygiene.normalize(text), Self.referenceNormalize(text), "normalize \(text)")
            XCTAssertEqual(LibraryHygiene.primaryArtist(text), Self.referencePrimaryArtist(text), "primaryArtist \(text)")
            XCTAssertEqual(
                LibraryHygiene.consolidationBaseTitle(text),
                Self.referenceBaseTitle(text, keywords: LibraryHygiene.consolidationKeywords),
                "consolidationBaseTitle \(text)"
            )
            for keywords in [LibraryHygiene.wantlistKeywords, LibraryHygiene.consolidationKeywords] {
                XCTAssertEqual(
                    LibraryHygiene.baseTitle(text, keywords: keywords),
                    Self.referenceBaseTitle(text, keywords: keywords),
                    "baseTitle \(text)"
                )
            }
        }
    }

    func testEditionSuffixesAreStillStripped() {
        XCTAssertEqual(LibraryHygiene.baseTitle("Kong (Remastered 2011)", keywords: LibraryHygiene.consolidationKeywords), "kong")
        XCTAssertEqual(LibraryHygiene.baseTitle("Evolution [Deluxe Edition]"), "evolution")
        XCTAssertEqual(LibraryHygiene.baseTitle("Reckoner - Mono"), "reckoner")
        XCTAssertEqual(LibraryHygiene.baseTitle("Overgrown 123"), "overgrown123")
        XCTAssertEqual(LibraryHygiene.normalize("Beyoncé"), "beyonce")
    }

    private static func referencePrimaryArtist(_ raw: String) -> String {
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

    private static func referenceNormalize(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var result = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            result.append(scalar)
        }
        return String(result)
    }

    private static func referenceBaseTitle(_ raw: String, keywords: Set<String>) -> String {
        var title = referenceStrip(raw.lowercased(), keywords: keywords)
        for separator in [" - ", ": ", " – "] {
            if let range = title.range(of: separator),
               referenceContainsKeyword(String(title[range.upperBound...]), keywords: keywords) {
                title = String(title[..<range.lowerBound])
            }
        }
        return referenceNormalize(title)
    }

    private static func referenceStrip(_ value: String, keywords: Set<String>) -> String {
        var result = value
        for (open, close) in [("(", ")"), ("[", "]"), ("{", "}")] {
            var searchStart = result.startIndex
            while let openRange = result.range(of: open, range: searchStart..<result.endIndex),
                  let closeRange = result.range(of: close, range: openRange.upperBound..<result.endIndex) {
                let segment = String(result[openRange.upperBound..<closeRange.lowerBound])
                if referenceContainsKeyword(segment, keywords: keywords) {
                    result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
                    searchStart = result.startIndex
                } else {
                    searchStart = closeRange.upperBound
                }
            }
        }
        return result
    }

    private static func referenceContainsKeyword(_ segment: String, keywords: Set<String>) -> Bool {
        let words = segment.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return words.contains { keywords.contains($0) }
            || (keywords.contains("ft.") && segment.lowercased().contains("ft."))
    }
}

private struct SplitMix {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
