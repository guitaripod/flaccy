import Foundation

extension LyricsParser {

    /// Reads a Lyricsfile 1.0 (the open YAML format lrclib serves):
    /// synchronized lines, each optionally carrying timed words. The reader
    /// understands exactly the YAML subset the format allows and refuses
    /// anything else (a duplicate key, a tag, an alias, a tab, an unknown
    /// version) by returning nil, so a caller falls back to the plain LRC text
    /// instead of showing a half-read file.
    public static func parseLyricsfile(_ text: String) -> LyricsDocument? {
        LyricsLyricsfile.parse(text)
    }
}

/// The strict YAML subset reader behind `LyricsParser.parseLyricsfile`,
/// mirroring `linux/shared/src/lyrics/lyricsfile.rs`. It walks
/// `Unicode.Scalar`s rather than `Character`s so that a "\r\n" or a combining
/// mark never changes where a quote, escape or indent is seen.
enum LyricsLyricsfile {

    static let maxBytes = 2 * 1024 * 1024
    static let maxDepth = 8
    static let maxLines = 5_000
    static let maxWords = 100_000

    struct Entry: Equatable {
        var key: String
        var value: Node
    }

    enum Node: Equatable {
        case map([Entry])
        case seq([Node])
        case str(String)
        case int(Int64)
        case bool(Bool)
        case null
    }

    struct Failure: Error {}

    fileprivate typealias Scalars = [Unicode.Scalar]
    fileprivate typealias Scanned = (value: String, rest: Scalars)
    fileprivate typealias Scan = (Scalars) throws -> Scanned?

    fileprivate enum Chomp {
        case clip
        case strip
        case keep
    }

    static func parse(_ text: String) -> LyricsDocument? {
        if text.utf8.count > maxBytes {
            return nil
        }
        var reader = Reader(text: text)
        guard let root = try? reader.readDocument() else { return nil }
        return document(from: root)
    }

    /// YAML types a plain scalar by its spelling: null, booleans and decimal
    /// integers are recognised, everything else stays text, and a trailing
    /// ` #` comment is dropped.
    static func plainScalar(_ text: String) -> Node {
        var scalars = Array(text.unicodeScalars)
        if let cut = find(Array(" #".unicodeScalars), in: scalars) {
            scalars = Array(scalars[..<cut])
        }
        let trimmed = LyricsText.trim(scalars)
        let value = LyricsText.string(trimmed)
        switch value {
        case "", "~", "null", "Null", "NULL":
            return .null
        case "true", "True", "TRUE":
            return .bool(true)
        case "false", "False", "FALSE":
            return .bool(false)
        default:
            break
        }
        var digits = trimmed[...]
        if let first = digits.first, first == "-" || first == "+" {
            digits = digits.dropFirst()
        }
        if !digits.isEmpty, digits.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }),
            let number = Int64(value)
        {
            return .int(number)
        }
        return .str(value)
    }

    fileprivate static func find(_ needle: Scalars, in haystack: Scalars) -> Int? {
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

    fileprivate static func isDash(_ content: Scalars) -> Bool {
        content == ["-"] || content.starts(with: "- ".unicodeScalars)
    }

    fileprivate static func leadingSpaces(_ line: Scalars) -> Int {
        var count = 0
        while count < line.count && line[count] == " " {
            count += 1
        }
        return count
    }

    /// Splits `key: value` at the first colon that is followed by a space or
    /// ends the line. Text that starts like a quoted, flow or special scalar
    /// is a value, never a key.
    fileprivate static func splitEntry(_ content: Scalars) -> (key: String, rest: Scalars)? {
        guard let first = content.first else { return nil }
        if "'\"[{|>&*!#".unicodeScalars.contains(first) {
            return nil
        }
        let colon: Int
        if let inside = find([":", " "], in: content) {
            colon = inside
        } else if content.last == ":" {
            colon = content.count - 1
        } else {
            return nil
        }
        let key = LyricsText.trimEnd(Array(content[..<colon]))
        if key.isEmpty {
            return nil
        }
        let rest = LyricsText.trimStart(Array(content[(colon + 1)...]))
        return (LyricsText.string(key), rest)
    }

    fileprivate static func fold(_ lines: [String]) -> String {
        var text = ""
        for line in lines {
            if line.isEmpty {
                text.unicodeScalars.append("\n")
                continue
            }
            if !text.isEmpty && text.unicodeScalars.last != "\n" {
                text.unicodeScalars.append(" ")
            }
            text.unicodeScalars.append(contentsOf: line.unicodeScalars)
        }
        return text
    }

    /// A single-quoted scalar's value and what follows its closing quote, or
    /// nil when the quote is still open at the end of the text.
    fileprivate static func scanSingle(_ text: Scalars) throws -> Scanned? {
        var value = String.UnicodeScalarView()
        var index = 0
        while index < text.count {
            let scalar = text[index]
            if scalar != "'" {
                value.append(scalar)
                index += 1
                continue
            }
            if index + 1 < text.count && text[index + 1] == "'" {
                value.append("'")
                index += 2
                continue
            }
            return (String(value), Array(text[(index + 1)...]))
        }
        return nil
    }

    /// A double-quoted scalar's value and what follows its closing quote, or
    /// nil when the quote is still open. Only the escapes YAML defines are
    /// accepted.
    fileprivate static func scanDouble(_ text: Scalars) throws -> Scanned? {
        var value = String.UnicodeScalarView()
        var index = 0
        while index < text.count {
            let scalar = text[index]
            index += 1
            switch scalar {
            case "\"":
                return (String(value), Array(text[index...]))
            case "\\":
                guard index < text.count else { return nil }
                let escape = text[index]
                index += 1
                switch escape {
                case "n": value.append("\n")
                case "t": value.append("\t")
                case "r": value.append("\r")
                case "0": value.append("\u{0}")
                case "a": value.append("\u{7}")
                case "b": value.append("\u{8}")
                case "e": value.append("\u{1b}")
                case "f": value.append("\u{c}")
                case "v": value.append("\u{b}")
                case " ", "\"", "/", "\\": value.append(escape)
                case "N": value.append("\u{85}")
                case "_": value.append("\u{a0}")
                case "L": value.append("\u{2028}")
                case "P": value.append("\u{2029}")
                case "x": value.append(try hexEscape(text, &index, digits: 2))
                case "u": value.append(try hexEscape(text, &index, digits: 4))
                case "U": value.append(try hexEscape(text, &index, digits: 8))
                default: throw Failure()
                }
            default:
                value.append(scalar)
            }
        }
        return nil
    }

    fileprivate static func hexEscape(_ text: Scalars, _ index: inout Int, digits: Int) throws -> Unicode.Scalar {
        var code: UInt64 = 0
        for _ in 0..<digits {
            guard index < text.count else { throw Failure() }
            let digit = text[index]
            index += 1
            let value: UInt64
            switch digit {
            case "0"..."9": value = UInt64(digit.value - 0x30)
            case "a"..."f": value = UInt64(digit.value - 0x61 + 10)
            case "A"..."F": value = UInt64(digit.value - 0x41 + 10)
            default: throw Failure()
            }
            code = code * 16 + value
        }
        guard code <= UInt64(UInt32.max), let scalar = Unicode.Scalar(UInt32(code)) else {
            throw Failure()
        }
        return scalar
    }

    private struct Reader {
        var lines: [Scalars]
        var pos = 0

        init(text: String) {
            lines = LyricsText.lines(LyricsText.droppingByteOrderMark(text))
                .map { Array($0.unicodeScalars) }
        }

        mutating func readDocument() throws -> Node {
            if let (_, content) = try peek(), content == ["-", "-", "-"] {
                pos += 1
            }
            guard let (indent, _) = try peek() else { throw Failure() }
            let node = try block(indent: indent, depth: 0)
            if try peek() != nil {
                throw Failure()
            }
            return node
        }

        /// The next line that carries content, as its indent and trimmed
        /// text, without consuming it. Blank and comment lines are skipped; a
        /// tab in the indentation is an error.
        mutating func peek() throws -> (indent: Int, content: Scalars)? {
            while pos < lines.count {
                let line = lines[pos]
                let indent = LyricsLyricsfile.leadingSpaces(line)
                let content = Array(line[indent...])
                if LyricsText.trim(content).isEmpty || content.first == "#" {
                    pos += 1
                    continue
                }
                if content.first == "\t" {
                    throw Failure()
                }
                return (indent, LyricsText.trimEnd(content))
            }
            return nil
        }

        mutating func block(indent: Int, depth: Int) throws -> Node {
            if depth > LyricsLyricsfile.maxDepth {
                throw Failure()
            }
            guard let (_, content) = try peek() else { throw Failure() }
            if LyricsLyricsfile.isDash(content) {
                return try sequence(indent: indent, depth: depth)
            }
            return try mapping(indent: indent, depth: depth)
        }

        mutating func sequence(indent: Int, depth: Int) throws -> Node {
            var items: [Node] = []
            while let (found, content) = try peek() {
                if found > indent {
                    throw Failure()
                }
                if found != indent || !LyricsLyricsfile.isDash(content) {
                    break
                }
                let afterDash = Array(content[1...])
                let rest = Array(afterDash.drop(while: { $0 == " " }))
                if rest.isEmpty {
                    pos += 1
                    if let (next, _) = try peek(), next > indent {
                        items.append(try block(indent: next, depth: depth + 1))
                    } else {
                        items.append(.null)
                    }
                    continue
                }
                if rest.first == "\t" || LyricsLyricsfile.isDash(rest) {
                    throw Failure()
                }
                let offset = indent + 1 + (afterDash.count - rest.count)
                lines[pos] = Array(repeating: " ", count: offset) + rest
                if LyricsLyricsfile.splitEntry(rest) != nil {
                    items.append(try mapping(indent: offset, depth: depth + 1))
                } else {
                    pos += 1
                    items.append(try scalar(rest))
                }
            }
            return .seq(items)
        }

        mutating func mapping(indent: Int, depth: Int) throws -> Node {
            var entries: [Entry] = []
            while let (found, content) = try peek() {
                if found < indent || LyricsLyricsfile.isDash(content) {
                    break
                }
                if found > indent {
                    throw Failure()
                }
                guard let (key, rest) = LyricsLyricsfile.splitEntry(content) else { throw Failure() }
                if entries.contains(where: { $0.key == key }) {
                    throw Failure()
                }
                pos += 1
                let node = try value(rest, indent: indent, depth: depth)
                entries.append(Entry(key: key, value: node))
            }
            if entries.isEmpty {
                throw Failure()
            }
            return .map(entries)
        }

        /// The value after `key:`. Nothing after the colon means a nested
        /// block on the following lines, which for a sequence may sit at the
        /// key's own indent.
        mutating func value(_ rest: Scalars, indent: Int, depth: Int) throws -> Node {
            if rest.isEmpty || rest.first == "#" {
                if let (next, content) = try peek() {
                    if next > indent {
                        return try block(indent: next, depth: depth + 1)
                    }
                    if next == indent && LyricsLyricsfile.isDash(content) {
                        return try sequence(indent: indent, depth: depth + 1)
                    }
                }
                return .null
            }
            if rest.first == "|" || rest.first == ">" {
                return try blockScalar(header: rest, parentIndent: indent)
            }
            return try scalar(rest)
        }

        mutating func scalar(_ source: Scalars) throws -> Node {
            let text = LyricsText.trim(source)
            switch text.first {
            case "'":
                return try quoted(text, scan: LyricsLyricsfile.scanSingle)
            case "\"":
                return try quoted(text, scan: LyricsLyricsfile.scanDouble)
            case "[" where text == ["[", "]"]:
                return .seq([])
            case "{" where text == ["{", "}"]:
                return .map([])
            case "[", "{", "&", "*", "!", "%", "@", "`":
                throw Failure()
            default:
                return LyricsLyricsfile.plainScalar(LyricsText.string(text))
            }
        }

        /// A quoted scalar, which a long line may fold across several; the
        /// pieces are joined with a space as YAML specifies.
        mutating func quoted(_ first: Scalars, scan: Scan) throws -> Node {
            var buffer = first
            while true {
                if let (value, rest) = try scan(Array(buffer[1...])) {
                    let trailing = LyricsText.trim(rest)
                    if !trailing.isEmpty && trailing.first != "#" {
                        throw Failure()
                    }
                    return .str(value)
                }
                guard pos < lines.count else { throw Failure() }
                let next = LyricsText.trim(lines[pos])
                pos += 1
                buffer.append(" ")
                buffer.append(contentsOf: next)
            }
        }

        mutating func blockScalar(header: Scalars, parentIndent: Int) throws -> Node {
            let folded = header.first == ">"
            var chomp = Chomp.clip
            for scalar in header.dropFirst() {
                if scalar == "-" {
                    chomp = .strip
                } else if scalar == "+" {
                    chomp = .keep
                } else if scalar == " " || scalar == "#" {
                    break
                } else {
                    throw Failure()
                }
            }
            var collected: [String] = []
            var contentIndent: Int?
            while pos < lines.count {
                let line = lines[pos]
                let indent = LyricsLyricsfile.leadingSpaces(line)
                if LyricsText.trim(Array(line[indent...])).isEmpty {
                    collected.append("")
                    pos += 1
                    continue
                }
                if indent <= parentIndent {
                    break
                }
                let base = contentIndent ?? indent
                contentIndent = base
                if indent < base {
                    break
                }
                collected.append(LyricsText.string(LyricsText.trimEnd(Array(line[base...]))))
                pos += 1
            }
            var trailing = 0
            for line in collected.reversed() {
                if !line.isEmpty { break }
                trailing += 1
            }
            collected.removeLast(trailing)
            var text = folded ? LyricsLyricsfile.fold(collected) : collected.joined(separator: "\n")
            if !collected.isEmpty {
                switch chomp {
                case .strip:
                    break
                case .clip:
                    text += "\n"
                case .keep:
                    text += "\n" + String(repeating: "\n", count: trailing)
                }
            }
            return .str(text)
        }
    }

    private static func get(_ map: [Entry], _ key: String) -> Node? {
        map.first { $0.key == key }?.value
    }

    private static func asMap(_ node: Node) -> [Entry]? {
        if case .map(let entries) = node {
            return entries
        }
        return nil
    }

    private static func document(from root: Node) -> LyricsDocument? {
        guard let map = asMap(root) else { return nil }
        guard case .str(let version)? = get(map, "version"), version == "1.0" else { return nil }
        guard let metadataNode = get(map, "metadata"), let metadata = asMap(metadataNode) else {
            return nil
        }
        let instrumental: Bool
        switch get(metadata, "instrumental") {
        case .bool(let flag)?: instrumental = flag
        case nil, .null?: instrumental = false
        default: return nil
        }
        let plain: String?
        switch get(map, "plain") {
        case .str(let text)?: plain = text
        case nil, .null?: plain = nil
        default: return nil
        }
        var lines: [LyricsRawLine] = []
        var wordsSeen = 0
        switch get(map, "lines") {
        case .seq(let items)?:
            if items.count > maxLines {
                return nil
            }
            for item in items {
                guard let line = rawLine(from: item) else { return nil }
                wordsSeen += line.words.count
                if wordsSeen > maxWords {
                    return nil
                }
                lines.append(line)
            }
        case nil, .null?:
            break
        default:
            return nil
        }
        if instrumental {
            return LyricsDocument.resolve(raw: [], plain: nil, instrumental: true)
        }
        return LyricsDocument.resolve(raw: lines, plain: plain, instrumental: false)
    }

    private static func rawLine(from node: Node) -> LyricsRawLine? {
        guard let map = asMap(node) else { return nil }
        var words: [LyricsRawWord] = []
        switch get(map, "words") {
        case .seq(let items)?:
            for item in items {
                guard let word = rawWord(from: item) else { return nil }
                words.append(word)
            }
        case nil, .null?:
            break
        default:
            return nil
        }
        guard let startNode = get(map, "start_ms"), let start = millis(startNode),
            let end = optionalMillis(get(map, "end_ms")),
            let textNode = get(map, "text"), let text = textOf(textNode)
        else { return nil }
        return LyricsRawLine(start: start, end: end, text: text, words: words)
    }

    private static func rawWord(from node: Node) -> LyricsRawWord? {
        guard let map = asMap(node),
            let startNode = get(map, "start_ms"), let start = millis(startNode),
            let end = optionalMillis(get(map, "end_ms")),
            let textNode = get(map, "text"), let text = textOf(textNode)
        else { return nil }
        return LyricsRawWord(start: start, end: end, text: text)
    }

    private static func textOf(_ node: Node) -> String? {
        switch node {
        case .str(let text): return text
        case .int(let number): return String(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return ""
        default: return nil
        }
    }

    private static func millis(_ node: Node) -> Double? {
        if case .int(let value) = node, value >= 0 {
            return Double(value) / 1000.0
        }
        return nil
    }

    /// Nothing stated is `.some(nil)`; a value that is not a non-negative
    /// whole number of milliseconds is `nil`, which refuses the file.
    private static func optionalMillis(_ node: Node?) -> Double?? {
        switch node {
        case nil, .null?:
            return .some(nil)
        case let other?:
            return millis(other).map { .some($0) }
        }
    }
}
