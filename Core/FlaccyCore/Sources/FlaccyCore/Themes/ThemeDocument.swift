import Foundation

/// Reads the TOML a `theme.toml` is written in. Mirrored character for
/// character by `linux/shared/src/theme/document.rs`, so a theme means the
/// same thing on every client and a mistake in one is reported in the same
/// words.
///
/// It reads what a theme can need: strings of all four kinds, numbers,
/// booleans, arrays, inline tables, `[tables]`, `[[arrays of tables]]`, dotted
/// keys and comments. A value it has no use for (a date) is kept as written
/// rather than refused.
public enum ThemeDocument {

    /// One value of a document.
    public indirect enum Value: Equatable, Sendable {
        case text(String)
        case integer(Int64)
        case float(Double)
        case flag(Bool)
        case list([Value])
        case table(Table)
        case other(String)
    }

    /// A table with its keys in the order they were written.
    public struct Table: Equatable, Sendable {
        var entries: [(key: String, value: Value)] = []

        public init() {}

        public subscript(key: String) -> Value? {
            entries.first { $0.key == key }?.value
        }

        public var keys: [String] { entries.map(\.key) }

        func position(of key: String) -> Int? {
            entries.firstIndex { $0.key == key }
        }

        mutating func insert(_ key: String, _ value: Value) {
            entries.append((key, value))
        }

        public static func == (lhs: Table, rhs: Table) -> Bool {
            lhs.entries.count == rhs.entries.count
                && zip(lhs.entries, rhs.entries).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        }
    }

    /// What is wrong with a document, with the line it is on.
    public struct Failure: Error, Equatable, Sendable {
        public let message: String
    }

    /// Reads a whole document. The error names the line and what is wrong on it.
    public static func read(_ document: String) throws(Failure) -> Table {
        var reader = Reader(document)
        return try reader.document()
    }

    /// How a `[header]` reaches the table its keys belong to.
    private enum Step {
        case key
        case lastOfList
    }

    private struct Reader {
        let characters: [Character]
        var at = 0
        var line = 1

        init(_ document: String) {
            var characters: [Character] = []
            for scalar in document.unicodeScalars {
                characters.append(Character(scalar))
            }
            self.characters = characters
        }

        func failure(_ what: String) -> Failure {
            Failure(message: "line \(line): \(what)")
        }

        var peek: Character? { at < characters.count ? characters[at] : nil }

        func peek(ahead: Int) -> Character? {
            at + ahead < characters.count ? characters[at + ahead] : nil
        }

        func starts(with text: String) -> Bool {
            for (index, character) in text.enumerated() where peek(ahead: index) != character {
                return false
            }
            return true
        }

        @discardableResult
        mutating func advance() -> Character? {
            guard let character = peek else { return nil }
            at += 1
            if character == "\n" { line += 1 }
            return character
        }

        /// Steps over `wanted` if it is next, and says whether it was. Looking
        /// before stepping keeps a mistake on the line it was made on.
        mutating func take(_ wanted: Character) -> Bool {
            guard peek == wanted else { return false }
            advance()
            return true
        }

        mutating func skipSpaces() {
            while peek == " " || peek == "\t" { at += 1 }
        }

        mutating func skipComment() {
            guard peek == "#" else { return }
            while let character = peek, character != "\n" { at += 1 }
        }

        /// Skips spaces, comments and line ends, as between the items of an array.
        mutating func skipBlank() {
            while true {
                skipSpaces()
                skipComment()
                guard peek == "\n" || peek == "\r" else { return }
                advance()
            }
        }

        /// Ends a line: nothing but spaces and a comment may follow a value.
        mutating func endLine() throws(Failure) {
            skipSpaces()
            skipComment()
            switch peek {
            case nil:
                return
            case "\r" where peek(ahead: 1) == "\n":
                advance()
                advance()
            case "\n":
                advance()
            default:
                throw failure("there is something after the value that does not belong")
            }
        }

        mutating func escape() throws(Failure) -> Character {
            guard let character = advance() else {
                throw failure("a string ends in the middle of an escape")
            }
            switch character {
            case "b": return "\u{8}"
            case "t": return "\t"
            case "n": return "\n"
            case "f": return "\u{c}"
            case "r": return "\r"
            case "\"": return "\""
            case "\\": return "\\"
            case "u", "U":
                var code: UInt32 = 0
                for _ in 0..<(character == "u" ? 4 : 8) {
                    guard let digit = advance()?.hexDigitValue, advanceWasASCII else {
                        throw failure("a \\u escape needs hexadecimal digits")
                    }
                    code = code &* 16 &+ UInt32(digit)
                }
                guard let scalar = Unicode.Scalar(code) else {
                    throw failure("a \\u escape names no character")
                }
                return Character(scalar)
            default:
                throw failure("a backslash is followed by something that is not an escape")
            }
        }

        /// Whether the character just stepped over was ASCII, which a
        /// hexadecimal digit has to be.
        var advanceWasASCII: Bool {
            at > 0 && characters[at - 1].isASCII
        }

        mutating func basicString() throws(Failure) -> String {
            advance()
            var text = String.UnicodeScalarView()
            while true {
                switch advance() {
                case nil, "\n": throw failure("a string is never closed")
                case "\"": return String(text)
                case "\\": text.append(contentsOf: try escape().unicodeScalars)
                case let character?: text.append(contentsOf: character.unicodeScalars)
                }
            }
        }

        mutating func literalString() throws(Failure) -> String {
            advance()
            var text = String.UnicodeScalarView()
            while true {
                switch advance() {
                case nil, "\n": throw failure("a string is never closed")
                case "'": return String(text)
                case let character?: text.append(contentsOf: character.unicodeScalars)
                }
            }
        }

        /// A string in triple quotes. A line end right after the opening
        /// quotes is dropped, and in a basic string a backslash at a line's end
        /// joins it to the next line's first word.
        mutating func longString(_ quote: Character) throws(Failure) -> String {
            for _ in 0..<3 { advance() }
            if peek == "\r", peek(ahead: 1) == "\n" { advance() }
            if peek == "\n" { advance() }
            let closing = String(repeating: quote, count: 3)
            var text = String.UnicodeScalarView()
            while true {
                if starts(with: closing) {
                    for _ in 0..<3 { advance() }
                    return String(text)
                }
                guard let character = advance() else {
                    throw failure("a string is never closed")
                }
                guard character == "\\", quote == "\"" else {
                    text.append(contentsOf: character.unicodeScalars)
                    continue
                }
                guard peek == "\n" || peek == "\r" || peek == " " || peek == "\t" else {
                    text.append(contentsOf: try escape().unicodeScalars)
                    continue
                }
                let mark = at
                skipSpaces()
                guard peek == "\n" || peek == "\r" else {
                    at = mark
                    throw failure("a backslash is followed by something that is not an escape")
                }
                while peek == "\n" || peek == "\r" || peek == " " || peek == "\t" { advance() }
            }
        }

        mutating func keyPart() throws(Failure) -> String {
            if peek == "\"" { return try basicString() }
            if peek == "'" { return try literalString() }
            var name = ""
            while let character = peek, character.isASCII,
                character.isLetter || character.isNumber || character == "_" || character == "-" {
                name.append(character)
                at += 1
            }
            guard !name.isEmpty else { throw failure("a key is missing") }
            return name
        }

        /// One or more key parts joined by dots.
        mutating func keyPath() throws(Failure) -> [String] {
            var path = [try keyPart()]
            while true {
                skipSpaces()
                guard peek == "." else { return path }
                advance()
                skipSpaces()
                path.append(try keyPart())
            }
        }

        mutating func list() throws(Failure) -> Value {
            advance()
            var items: [Value] = []
            while true {
                skipBlank()
                if take("]") { return .list(items) }
                items.append(try value())
                skipBlank()
                if take(",") { continue }
                guard peek == "]" else {
                    throw failure("an array's items must be separated by commas")
                }
            }
        }

        mutating func inlineTable() throws(Failure) -> Value {
            advance()
            var table = Table()
            skipSpaces()
            if take("}") { return .table(table) }
            while true {
                skipSpaces()
                let path = try keyPath()
                skipSpaces()
                guard take("=") else { throw failure("a key must be followed by =") }
                skipSpaces()
                let value = try value()
                try assign(&table, path, value)
                skipSpaces()
                if take("}") { return .table(table) }
                guard take(",") else {
                    throw failure("an inline table's entries must be separated by commas")
                }
            }
        }

        /// A number, a boolean, or anything else written without quotes.
        mutating func bare() throws(Failure) -> Value {
            var word = ""
            while let character = peek, !",]}#\n\r \t".contains(character) {
                word.append(character)
                at += 1
            }
            guard !word.isEmpty else { throw failure("a value is missing") }
            switch word {
            case "true": return .flag(true)
            case "false": return .flag(false)
            default: return ThemeDocument.number(word) ?? .other(word)
            }
        }

        mutating func value() throws(Failure) -> Value {
            switch peek {
            case nil, "\n", "\r": throw failure("a value is missing")
            case "\"" where starts(with: "\"\"\""): return .text(try longString("\""))
            case "'" where starts(with: "'''"): return .text(try longString("'"))
            case "\"": return .text(try basicString())
            case "'": return .text(try literalString())
            case "[": return try list()
            case "{": return try inlineTable()
            default: return try bare()
            }
        }

        /// Sets `path` inside `table`, making the tables a dotted key passes
        /// through. A key may be set once.
        func assign(_ table: inout Table, _ path: [String], _ value: Value) throws(Failure) {
            guard let part = path.first else { return }
            if path.count == 1 {
                guard table.position(of: part) == nil else { throw failure("\(part) is set twice") }
                table.insert(part, value)
                return
            }
            if table.position(of: part) == nil { table.insert(part, .table(Table())) }
            let at = table.position(of: part)!
            guard case .table(var inner) = table.entries[at].value else {
                throw failure("\(part) is already a value, so it cannot hold keys")
            }
            try assign(&inner, Array(path.dropFirst()), value)
            table.entries[at].value = .table(inner)
        }

        /// Runs `change` on the table a header names, making tables on the way
        /// and stepping into the last entry of any array of tables it crosses.
        func withTable(
            _ table: inout Table, _ path: ArraySlice<(String, Step)>, line: Int,
            _ change: (inout Table) throws(Failure) -> Void
        ) throws(Failure) {
            guard let (part, step) = path.first else {
                try change(&table)
                return
            }
            if table.position(of: part) == nil {
                switch step {
                case .key: table.insert(part, .table(Table()))
                case .lastOfList: table.insert(part, .list([.table(Table())]))
                }
            }
            let at = table.position(of: part)!
            switch table.entries[at].value {
            case .table(var inner):
                try withTable(&inner, path.dropFirst(), line: line, change)
                table.entries[at].value = .table(inner)
            case .list(var items):
                guard case .table(var inner)? = items.last else {
                    throw Failure(message: "line \(line): \(part) is not a list of tables")
                }
                try withTable(&inner, path.dropFirst(), line: line, change)
                items[items.count - 1] = .table(inner)
                table.entries[at].value = .list(items)
            default:
                throw Failure(message: "line \(line): \(part) is already a value, so it cannot be a table")
            }
        }

        mutating func header(_ root: inout Table) throws(Failure) -> [(String, Step)] {
            let listed = peek(ahead: 1) == "["
            advance()
            if listed { advance() }
            skipSpaces()
            let path = try keyPath()
            skipSpaces()
            guard take("]"), !listed || take("]") else {
                throw failure("a table's name is never closed")
            }
            let line = line
            let last = path[path.count - 1]
            var route: [(String, Step)] = path.dropLast().map { ($0, Step.key) }
            try withTable(&root, route[...], line: line) { (parent: inout Table) throws(Failure) in
                guard let at = parent.position(of: last) else {
                    parent.insert(last, listed ? .list([.table(Table())]) : .table(Table()))
                    return
                }
                switch (parent.entries[at].value, listed) {
                case (.list(var items), true):
                    items.append(.table(Table()))
                    parent.entries[at].value = .list(items)
                case (_, true):
                    throw Failure(message: "line \(line): \(last) is already a value, so it cannot be a list of tables")
                case (.table, false), (.list, false):
                    return
                case (_, false):
                    throw Failure(message: "line \(line): \(last) is already a value, so it cannot be a table")
                }
            }
            route.append((last, listed ? .lastOfList : .key))
            try endLine()
            return route
        }

        mutating func document() throws(Failure) -> Table {
            var root = Table()
            var here: [(String, Step)] = []
            while true {
                skipBlank()
                guard let character = peek else { return root }
                if character == "[" {
                    here = try header(&root)
                    continue
                }
                let path = try keyPath()
                skipSpaces()
                guard take("=") else { throw failure("a key must be followed by =") }
                skipSpaces()
                let value = try value()
                let reader = self
                try withTable(&root, here[...], line: line) { (table: inout Table) throws(Failure) in
                    try reader.assign(&table, path, value)
                }
                try endLine()
            }
        }
    }

    /// An integer or a float as TOML writes them, or nothing if `word` is neither.
    static func number(_ word: String) -> Value? {
        let plain = word.filter { $0 != "_" }
        let negative = plain.hasPrefix("-")
        let unsigned = (plain.hasPrefix("+") || negative) ? String(plain.dropFirst()) : plain
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where unsigned.hasPrefix(prefix) {
            return Int64(unsigned.dropFirst(2), radix: radix).map { .integer(negative ? -$0 : $0) }
        }
        if unsigned == "inf" { return .float(negative ? -.infinity : .infinity) }
        if unsigned == "nan" { return .float(.nan) }
        guard let first = unsigned.first, first.isASCII, first.isNumber else { return nil }
        if unsigned.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return Int64(plain).map(Value.integer)
        }
        let numeric = unsigned.allSatisfy { ($0.isASCII && $0.isNumber) || ".eE+-".contains($0) }
        guard numeric, !unsigned.hasSuffix(".") else { return nil }
        return Double(plain).map(Value.float)
    }
}
