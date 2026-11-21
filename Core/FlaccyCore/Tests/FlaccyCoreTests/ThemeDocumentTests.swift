import XCTest
@testable import FlaccyCore

/// The same cases as `linux/shared/src/theme/document.rs`.
final class ThemeDocumentTests: XCTestCase {

    private func text(_ table: ThemeDocument.Table, _ key: String) -> String? {
        if case .text(let text)? = table[key] { return text }
        return nil
    }

    private func table(_ table: ThemeDocument.Table, _ key: String) -> ThemeDocument.Table {
        if case .table(let inner)? = table[key] { return inner }
        XCTFail("\(key) is not a table")
        return ThemeDocument.Table()
    }

    private func tables(_ table: ThemeDocument.Table, _ key: String) -> [ThemeDocument.Table] {
        guard case .list(let items)? = table[key] else {
            XCTFail("\(key) is not a list")
            return []
        }
        return items.compactMap { if case .table(let inner) = $0 { inner } else { nil } }
    }

    func testReadsKeysTablesAndListsOfTablesInOrder() throws {
        let root = try ThemeDocument.read(
            "# a theme\nname = \"Phosphor\"  # trailing\nformat = 1\nratio = 1.25\nloud = true\n\n"
                + "[fonts]\ninterface = 'JetBrains Mono, monospace'\n\n"
                + "[[scheme]]\nname = \"Green\"\n[scheme.dark]\nwindow = \"#040705\"\n\n"
                + "[[scheme]]\nname = \"Amber\"\n[scheme.dark]\nwindow = \"#070502\"\n"
        )
        XCTAssertEqual(root.keys, ["name", "format", "ratio", "loud", "fonts", "scheme"])
        XCTAssertEqual(text(root, "name"), "Phosphor")
        XCTAssertEqual(root["format"], .integer(1))
        XCTAssertEqual(root["ratio"], .float(1.25))
        XCTAssertEqual(root["loud"], .flag(true))
        XCTAssertEqual(text(table(root, "fonts"), "interface"), "JetBrains Mono, monospace")
        let schemes = tables(root, "scheme")
        XCTAssertEqual(schemes.count, 2)
        XCTAssertEqual(text(schemes[0], "name"), "Green")
        XCTAssertEqual(text(table(schemes[0], "dark"), "window"), "#040705")
        XCTAssertEqual(text(table(schemes[1], "dark"), "window"), "#070502")
    }

    func testReadsEveryKindOfString() throws {
        let root = try ThemeDocument.read(
            "a = \"tab\\there \\\"quoted\\\" \\u00e9 \\\\\"\nb = 'C:\\raw\\path'\n"
                + "c = \"\"\"\nfirst\nsecond \\\n   joined\"\"\"\nd = '''\nkept \\ as is\n'''\n"
        )
        XCTAssertEqual(text(root, "a"), "tab\there \"quoted\" é \\")
        XCTAssertEqual(text(root, "b"), "C:\\raw\\path")
        XCTAssertEqual(text(root, "c"), "first\nsecond joined")
        XCTAssertEqual(text(root, "d"), "kept \\ as is\n")
    }

    func testReadsNumbersListsInlineTablesAndDottedKeys() throws {
        let root = try ThemeDocument.read(
            "big = 1_000\nneg = -7\nhex = 0xff\nexp = 5e-1\nwhen = 2026-11-21\n"
                + "sizes = [96, 140,\n  320, # the largest\n]\npoint = { x = 1, y = 2.5 }\n"
                + "fonts.interface = \"Inter\"\nfonts.headings = \"Charter\"\n\"quoted key\" = false\n"
        )
        XCTAssertEqual(root["big"], .integer(1000))
        XCTAssertEqual(root["neg"], .integer(-7))
        XCTAssertEqual(root["hex"], .integer(255))
        XCTAssertEqual(root["exp"], .float(0.5))
        XCTAssertEqual(root["when"], .other("2026-11-21"))
        XCTAssertEqual(root["sizes"], .list([.integer(96), .integer(140), .integer(320)]))
        XCTAssertEqual(table(root, "point")["y"], .float(2.5))
        XCTAssertEqual(text(table(root, "fonts"), "headings"), "Charter")
        XCTAssertEqual(root["quoted key"], .flag(false))
    }

    func testATableCanComeBackAndAWindowsFileReadsTheSame() throws {
        let root = try ThemeDocument.read(
            "[layout]\r\nalbums = \"list\"\r\n[shape]\r\ncovers = \"square\"\r\n[layout.extra]\r\nglow = false\r\n"
        )
        XCTAssertEqual(text(table(root, "layout"), "albums"), "list")
        XCTAssertEqual(table(table(root, "layout"), "extra")["glow"], .flag(false))
    }

    func testNamesTheLineAndTheMistake() {
        let cases: [(String, String)] = [
            ("name = ", "line 1: a value is missing"),
            ("name = \"open", "line 1: a string is never closed"),
            ("a = 1\nname \"x\"", "line 2: a key must be followed by ="),
            ("a = 1\na = 2", "line 2: a is set twice"),
            ("a = 1 2", "line 1: there is something after the value that does not belong"),
            ("[fonts\ninterface = 1", "line 1: a table's name is never closed"),
            ("a = [1 2]", "line 1: an array's items must be separated by commas"),
            ("a = \"bad \\q\"", "line 1: a backslash is followed by something that is not an escape"),
            ("a = 1\n[a]\nb = 2", "line 2: a is already a value, so it cannot be a table"),
            ("= 1", "line 1: a key is missing"),
        ]
        for (document, message) in cases {
            XCTAssertThrowsError(try ThemeDocument.read(document), document) { error in
                XCTAssertEqual((error as? ThemeDocument.Failure)?.message, message, document)
            }
        }
    }
}
