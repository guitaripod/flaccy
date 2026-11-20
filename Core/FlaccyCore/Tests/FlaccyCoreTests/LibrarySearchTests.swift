import XCTest
@testable import FlaccyCore

final class LibrarySearchTests: XCTestCase {

    func testS1HaystacksMatchTheSharedVectors() {
        let cases: [([String], String)] = [
            (["Abbey Road", "The Beatles"], "abbey road\nthe beatles"),
            (["AC/DC"], "ac dc\nacdc"),
            (["Sigur Rós", "Ágætis byrjun"], "sigur ros\nagaetis byrjun"),
            (["Don't Stop Me Now"], "don t stop me now\ndont stop me now"),
            (["R.E.M."], "r e m\nrem"),
            (["÷"], "÷"),
            (["  !!!  "], "!!!"),
            (["Motörhead", "Björk", "Mötley Crüe"], "motorhead\nbjork\nmotley crue"),
            (["Straße", "ŁÓDŹ", "İstanbul"], "strasse\nlodz\nistanbul"),
            (["Beyonce\u{0301}"], "beyonce"),
            (["東京事変  スポーツ"], "東京事変 スポーツ"),
            (["Jay-Z", ""], "jay z\njayz\n"),
        ]
        for (fields, expected) in cases {
            XCTAssertEqual(
                Array(LibrarySearch.haystack(fields).unicodeScalars),
                Array(expected.unicodeScalars),
                "\(fields)"
            )
        }
    }

    func testS2MatchesAgreeWithTheSharedVectors() {
        let cases: [(String, [String], Bool)] = [
            ("", ["anything"], true),
            ("   ", ["anything"], true),
            ("ROAD", ["Abbey Road", "The Beatles"], true),
            ("beatles abbey", ["Abbey Road", "The Beatles"], true),
            ("abbey beatles road", ["Abbey Road", "The Beatles"], true),
            ("beatles revolver", ["Abbey Road", "The Beatles"], false),
            ("sigur ros", ["Sigur Rós"], true),
            ("SIGUR RÓS", ["Sigur Ros"], true),
            ("acdc", ["AC/DC"], true),
            ("ac dc", ["AC/DC"], true),
            ("ac/dc", ["AC/DC"], true),
            ("ac-dc", ["ACDC"], true),
            ("dont stop", ["Don't Stop Me Now"], true),
            ("don't", ["Dont Stop Me Now"], true),
            ("rem", ["R.E.M."], true),
            ("r.e.m.", ["REM"], true),
            ("÷", ["÷"], true),
            ("÷", ["Divide"], false),
            ("!!!", ["!!!"], true),
            ("roadthe", ["Abbey Road", "The Beatles"], false),
            ("jayz", ["Jay-Z"], true),
            ("東京", ["東京事変"], true),
        ]
        for (text, fields, expected) in cases {
            let query = LibrarySearch.Query(text)
            XCTAssertEqual(query.matches(fields: fields), expected, "\(text) in \(fields)")
            if !query.isEmpty {
                XCTAssertEqual(
                    query.matches(haystack: LibrarySearch.haystack(fields)), expected, "\(text) in the haystack of \(fields)"
                )
            }
        }
    }

    func testS3RanksAgreeWithTheSharedVectors() {
        let cases: [(String, String, [String], LibrarySearch.Rank?)] = [
            ("abbey road", "Abbey Road", [], .exact),
            ("acdc", "AC/DC", [], .exact),
            ("ac dc", "AC/DC", [], .exact),
            ("abbey", "Abbey Road", [], .prefix),
            ("abbey ro", "Abbey Road", [], .prefix),
            ("road", "Abbey Road", [], .wordPrefix),
            ("ro ab", "Abbey Road", [], .wordPrefix),
            ("bey", "Abbey Road", [], .contains),
            ("road bey", "Abbey Road", [], .contains),
            ("beatles", "Abbey Road", ["The Beatles"], .elsewhere),
            ("beatles abbey", "Abbey Road", ["The Beatles"], .prefix),
            ("abbey road", "Come Together", ["The Beatles", "Abbey Road"], .elsewhere),
            ("abbey road", "Abbey Road", ["The Beatles", "Abbey Road"], .exact),
            ("metallica one", "One", ["Metallica", "...And Justice for All"], .exact),
            ("metallica one", "One [Live cover on Metallica]", ["KoRn", "Live & Rare"], .wordPrefix),
            ("metallica one", "Spit Out the Bone", ["Metallica", "Hardwired"], .contains),
            ("metallica two", "One", ["Metallica", "...And Justice for All"], nil),
            ("stones", "Abbey Road", ["The Beatles"], nil),
            ("", "Abbey Road", [], nil),
            ("bjork", "Björk", [], .exact),
        ]
        for (text, name, other, expected) in cases {
            XCTAssertEqual(LibrarySearch.Query(text).rank(name: name, other: other), expected, "\(text) for \(name)")
        }
    }

    func testS4RanksOrderBestFirst() {
        let ranks: [LibrarySearch.Rank] = [.elsewhere, .contains, .exact, .wordPrefix, .prefix]
        XCTAssertEqual(ranks.sorted(), [.exact, .prefix, .wordPrefix, .contains, .elsewhere])
    }
}
