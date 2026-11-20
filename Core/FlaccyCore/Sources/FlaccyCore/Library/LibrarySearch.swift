import Foundation

/// How a typed query finds an album, an artist, a song or a playlist, the same
/// on every client. Text is folded before it is compared: case and accents go,
/// and punctuation is read both as a word break and as nothing at all, so
/// "ac dc", "acdc" and "AC/DC" all meet. A query is cut into words and every
/// word must be found somewhere in the row, in any order and in any field, so
/// "beatles abbey" finds Abbey Road. `rank` says how well a name answers the
/// query, which is the order results are shown in. Mirrored in Rust as
/// `linux/shared/src/library_search.rs`.
public enum LibrarySearch {

    /// Keeps the fields of one haystack apart. A query word can never contain
    /// it, so a match can never straddle two fields.
    public static let fieldBreak: Character = "\n"

    /// How well a name answers a query, best first.
    public enum Rank: Int, Comparable, Sendable {
        case exact
        case prefix
        case wordPrefix
        case contains
        case elsewhere

        public static func < (lhs: Rank, rhs: Rank) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// What a query is matched against for one row: every field folded and
    /// kept apart. Build it once per row and keep it when the rows outlive a
    /// keystroke.
    public static func haystack(_ fields: [String]) -> String {
        var out = ""
        for (index, field) in fields.enumerated() {
            if index > 0 { out.append(fieldBreak) }
            let folded = Folded(field)
            if folded.spaced.isEmpty {
                out.append(lowercased(field.trimmingCharacters(in: .whitespacesAndNewlines)))
                continue
            }
            out.append(folded.spaced)
            if folded.joined != folded.spaced {
                out.append(fieldBreak)
                out.append(folded.joined)
            }
        }
        return out
    }

    /// A typed query, cut into folded words.
    public struct Query: Sendable, Equatable {

        public let words: [String]

        public init(_ text: String) {
            words = text.unicodeScalars
                .split(whereSeparator: \.properties.isWhitespace)
                .map { chunk in
                    let text = String(String.UnicodeScalarView(chunk))
                    let joined = Folded(text).joined
                    return joined.isEmpty ? LibrarySearch.lowercased(text) : joined
                }
        }

        /// A query of nothing but spaces asks for nothing and matches every row.
        public var isEmpty: Bool { words.isEmpty }

        /// Whether every word of the query is in a haystack built by
        /// `LibrarySearch.haystack`.
        public func matches(haystack: String) -> Bool {
            words.allSatisfy { haystack.contains($0) }
        }

        /// Whether every word of the query is in one of `fields`.
        public func matches(fields: [String]) -> Bool {
            isEmpty || matches(haystack: LibrarySearch.haystack(fields))
        }

        /// How well a row named `name` answers the query, or nil when the name
        /// and the row's `other` fields together do not hold every word of it.
        /// Words the other fields answer (the artist in "metallica one") are
        /// set aside and the name is judged by the rest, so the song called
        /// One comes before a song that merely mentions both words in its
        /// title.
        public func rank(name: String, other: [String] = []) -> Rank? {
            guard !isEmpty else { return nil }
            let nameText = LibrarySearch.haystack([name])
            let otherText = LibrarySearch.haystack(other)
            let leftToName = words.filter { other.isEmpty || !otherText.contains($0) }
            if leftToName.isEmpty {
                return matches(haystack: nameText) ? Self.rank(of: words, in: nameText) : .elsewhere
            }
            guard leftToName.allSatisfy({ nameText.contains($0) }) else { return nil }
            return Self.rank(of: leftToName, in: nameText)
        }

        private static func rank(of words: [String], in nameText: String) -> Rank {
            let readings = nameText.split(separator: LibrarySearch.fieldBreak, omittingEmptySubsequences: false)
            let phrase = words.joined(separator: " ")
            let joined = words.joined()
            if readings.contains(where: { $0 == phrase || $0 == joined }) { return .exact }
            if readings.contains(where: { $0.hasPrefix(phrase) }) { return .prefix }
            let everyWordBeginsOne = words.allSatisfy { word in
                readings.contains { reading in
                    reading.split(separator: " ").contains { $0.hasPrefix(word) }
                }
            }
            return everyWordBeginsOne ? .wordPrefix : .contains
        }
    }

    /// One field folded twice: `spaced` reads punctuation as a word break,
    /// `joined` reads it as nothing. Both are lowercase, unaccented, and hold
    /// single spaces between words with none at either end.
    struct Folded {

        private(set) var spaced = ""
        private(set) var joined = ""

        init(_ text: String) {
            for scalar in text.unicodeScalars {
                push(scalar)
            }
            if spaced.hasSuffix(" ") { spaced.removeLast() }
            if joined.hasSuffix(" ") { joined.removeLast() }
        }

        private static func breakWord(_ text: inout String) {
            if !text.isEmpty, !text.hasSuffix(" ") { text.append(" ") }
        }

        private mutating func breakBoth() {
            Self.breakWord(&spaced)
            Self.breakWord(&joined)
        }

        private mutating func keep(_ letters: String) {
            spaced.append(letters)
            joined.append(letters)
        }

        private mutating func push(_ scalar: Unicode.Scalar) {
            if scalar.isASCII {
                pushASCII(scalar)
                return
            }
            if scalar.properties.isWhitespace {
                breakBoth()
                return
            }
            if LibrarySearch.isCombiningMark(scalar) { return }
            var kept = false
            for lower in scalar.properties.lowercaseMapping.unicodeScalars {
                if LibrarySearch.isCombiningMark(lower) {
                    kept = true
                } else if let letters = LibrarySearch.diacriticFold[lower] {
                    keep(letters)
                    kept = true
                } else if LibrarySearch.isAlphanumeric(lower) {
                    keep(String(lower))
                    kept = true
                }
            }
            if !kept { Self.breakWord(&spaced) }
        }

        private mutating func pushASCII(_ scalar: Unicode.Scalar) {
            switch scalar.value {
            case 0x30...0x39, 0x61...0x7A:
                keep(String(scalar))
            case 0x41...0x5A:
                keep(String(Unicode.Scalar(scalar.value + 0x20) ?? scalar))
            case 0x09, 0x0A, 0x0C, 0x0D, 0x20:
                breakBoth()
            default:
                Self.breakWord(&spaced)
            }
        }
    }

    static func lowercased(_ text: String) -> String {
        text.unicodeScalars.map(\.properties.lowercaseMapping).joined()
    }

    static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        (0x0300...0x036F).contains(scalar.value)
    }

    static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isAlphabetic { return true }
        switch scalar.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    /// ASCII letters for the Latin letters with a diacritic or a ligature that
    /// music tags carry, lowercase only. Other scripts are compared as written.
    static let diacriticFold: [Unicode.Scalar: String] = {
        let groups: [(String, String)] = [
            ("àáâãäåāăą", "a"), ("èéêëēĕėęě", "e"), ("ìíîïīįı", "i"), ("òóôõöøōő", "o"),
            ("ùúûüūůű", "u"), ("ýÿ", "y"), ("ñńň", "n"), ("çćč", "c"), ("ß", "ss"),
            ("šśş", "s"), ("žźż", "z"), ("ł", "l"), ("đďð", "d"), ("ţť", "t"), ("ř", "r"),
            ("ğ", "g"), ("æ", "ae"), ("œ", "oe"), ("þ", "th"),
        ]
        var table = [Unicode.Scalar: String]()
        for (letters, folded) in groups {
            for scalar in letters.precomposedStringWithCanonicalMapping.unicodeScalars {
                table[scalar] = folded
            }
        }
        return table
    }()
}
