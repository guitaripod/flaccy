import Foundation

/// One timed word or syllable of a sung line. `text` keeps the space that
/// follows it, so joining every word rebuilds the line.
public struct LyricsWord: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// A word as a file states it, before missing ends are worked out.
public struct LyricsRawWord: Sendable, Equatable {
    public var start: Double
    public var end: Double?
    public var text: String

    public init(start: Double, end: Double?, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// A line as a file states it, before ends, breaks and interludes are worked
/// out. An empty `text` with no words is an LRC break marker.
public struct LyricsRawLine: Sendable, Equatable {
    public var start: Double
    public var end: Double?
    public var text: String
    public var words: [LyricsRawWord]

    public init(start: Double, end: Double?, text: String, words: [LyricsRawWord] = []) {
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }
}

public enum LyricsLineKind: Sendable, Equatable {
    case text
    case interlude
}

/// A resolved line: it always knows where it ends, and an instrumental break
/// is a line of its own so a list of rows maps one to one onto `lines`.
public struct LyricsLine: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [LyricsWord]
    public var kind: LyricsLineKind
    public var background: Bool

    public init(
        start: Double, end: Double, text: String, words: [LyricsWord],
        kind: LyricsLineKind, background: Bool
    ) {
        self.start = start
        self.end = end
        self.text = text
        self.words = words
        self.kind = kind
        self.background = background
    }

    public var isInterlude: Bool {
        kind == .interlude
    }

    public var hasWords: Bool {
        !words.isEmpty
    }
}

/// Everything known about one track's lyrics, whichever file format or server
/// it came from. Mirrored in Rust as `linux/shared/src/lyrics/`.
public struct LyricsDocument: Sendable, Equatable {
    public var lines: [LyricsLine]
    public var plain: String?
    public var instrumental: Bool

    /// How long a line with no end of its own stays "being sung" when nothing
    /// marks where it stops: past this the music has moved on.
    public static let maxInferredHold = 10.0

    /// The shortest gap between two lines that is worth showing as an
    /// instrumental break rather than simply holding the previous line.
    public static let minInterlude = 4.0

    /// How many lines before the latest-started one are checked for a line
    /// that is still sounding, which is how overlapping voices stay lit
    /// together.
    public static let overlapLookback = 8

    /// An interlude is shown as this many beats that light one after another.
    public static let interludeBeats = 3

    public init(lines: [LyricsLine] = [], plain: String? = nil, instrumental: Bool = false) {
        self.lines = lines
        self.plain = plain
        self.instrumental = instrumental
    }

    /// Orders the lines, gives each one an end, folds LRC break markers into
    /// those ends, and turns every long enough gap into an interlude line.
    public static func resolve(
        raw: [LyricsRawLine], plain: String? = nil, instrumental: Bool = false
    ) -> LyricsDocument {
        let ordered = raw
            .filter { $0.start.isFinite && $0.start >= 0.0 }
            .enumerated()
            .sorted { left, right in
                if left.element.start != right.element.start {
                    return left.element.start < right.element.start
                }
                return left.offset < right.offset
            }

        var entries: [LyricsRawLine] = []
        var breaks: [Double] = []
        for (_, line) in ordered {
            if isBlank(line) {
                breaks.append(line.start)
            } else {
                entries.append(line)
            }
        }

        let nextStarts = nextDistinctStarts(entries)
        var textLines: [LyricsLine] = []
        textLines.reserveCapacity(entries.count)
        for (entry, next) in zip(entries, nextStarts) {
            let end = lineEnd(entry, nextStart: next, breaks: breaks)
            textLines.append(buildLine(entry, end: end))
        }

        let keptPlain = plain.flatMap { LyricsText.trim($0).isEmpty ? nil : $0 }
        return LyricsDocument(
            lines: withInterludes(textLines),
            plain: keptPlain,
            instrumental: instrumental
        )
    }

    /// True when there is nothing to show at all.
    public var isEmpty: Bool {
        !instrumental && !hasSynced && plain == nil
    }

    public var hasSynced: Bool {
        lines.contains { !$0.isInterlude }
    }

    public var hasWordSync: Bool {
        lines.contains { $0.hasWords }
    }

    private static let noteMarks: Set<Unicode.Scalar> = ["\u{266A}", "\u{266B}", "\u{266C}", "\u{2669}"]

    /// A line with nothing to sing: empty, or only whitespace and music notes,
    /// which is how a file marks an instrumental stretch.
    private static func isSilent(_ text: String) -> Bool {
        LyricsText.trim(String(String.UnicodeScalarView(text.unicodeScalars.filter { !noteMarks.contains($0) })))
            .isEmpty
    }

    private static func isBlank(_ line: LyricsRawLine) -> Bool {
        isSilent(line.text) && line.words.allSatisfy { isSilent($0.text) }
    }

    /// For every entry, the start of the first later entry that starts
    /// strictly after it: lines stamped at the same instant are one moment of
    /// the song and share an end.
    private static func nextDistinctStarts(_ entries: [LyricsRawLine]) -> [Double?] {
        var next = [Double?](repeating: nil, count: entries.count)
        guard entries.count >= 2 else { return next }
        for index in stride(from: entries.count - 2, through: 0, by: -1) {
            if entries[index + 1].start > entries[index].start {
                next[index] = entries[index + 1].start
            } else {
                next[index] = next[index + 1]
            }
        }
        return next
    }

    /// An end a file states wins, and failing that the end of the line's last
    /// timed word. Otherwise the line runs to the first break marker after it,
    /// else to the next line, and never past the longest hold.
    private static func lineEnd(_ entry: LyricsRawLine, nextStart: Double?, breaks: [Double]) -> Double {
        if let end = entry.end {
            return max(end, entry.start)
        }
        let lastWordEnd = entry.words.compactMap(\.end).max()
        if let lastWordEnd {
            return max(lastWordEnd, entry.start)
        }
        let limit = entry.start + maxInferredHold
        let marker = breaks.first { at in
            guard at > entry.start else { return false }
            guard let nextStart else { return true }
            return at <= nextStart
        }
        let target = marker ?? nextStart ?? limit
        return max(min(target, limit), entry.start)
    }

    private static func buildLine(_ entry: LyricsRawLine, end: Double) -> LyricsLine {
        let words = resolveWords(entry.words, lineEnd: end)
        let text = words.isEmpty ? LyricsText.trim(entry.text) : words.map(\.text).joined()
        return LyricsLine(
            start: entry.start,
            end: end,
            text: text,
            words: words,
            kind: .text,
            background: isBackground(text)
        )
    }

    /// Folds whitespace-only fragments into the word before them, trims the
    /// line's outer whitespace, orders by start, and gives each word the end
    /// the next one implies.
    private static func resolveWords(_ raw: [LyricsRawWord], lineEnd: Double) -> [LyricsWord] {
        var merged: [LyricsRawWord] = []
        merged.reserveCapacity(raw.count)
        for word in raw {
            if word.text.isEmpty {
                continue
            }
            if LyricsText.trim(word.text).isEmpty {
                if !merged.isEmpty {
                    merged[merged.count - 1].text += word.text
                }
                continue
            }
            merged.append(word)
        }
        merged = merged.enumerated()
            .sorted { left, right in
                if left.element.start != right.element.start {
                    return left.element.start < right.element.start
                }
                return left.offset < right.offset
            }
            .map(\.element)
        if !merged.isEmpty {
            merged[0].text = LyricsText.trimStart(merged[0].text)
            merged[merged.count - 1].text = LyricsText.trimEnd(merged[merged.count - 1].text)
        }
        var resolved: [LyricsWord] = []
        resolved.reserveCapacity(merged.count)
        for (index, word) in merged.enumerated() {
            let implied = index + 1 < merged.count ? merged[index + 1].start : lineEnd
            resolved.append(
                LyricsWord(start: word.start, end: max(word.end ?? implied, word.start), text: word.text)
            )
        }
        return resolved
    }

    /// Backing vocals are conventionally written in one pair of parentheses.
    static func isBackground(_ text: String) -> Bool {
        let scalars = Array(LyricsText.trim(text).unicodeScalars)
        guard scalars.first == "(", scalars.last == ")" else { return false }
        var depth = 0
        for (index, scalar) in scalars.enumerated() {
            if scalar == "(" {
                depth += 1
            } else if scalar == ")" {
                depth -= 1
                if depth == 0 && index + 1 < scalars.count {
                    return false
                }
            }
        }
        return depth == 0
    }

    /// Inserts an interlude line into the intro and into every gap of at least
    /// `minInterlude` seconds between the furthest end so far and the next
    /// start.
    private static func withInterludes(_ lines: [LyricsLine]) -> [LyricsLine] {
        var out: [LyricsLine] = []
        out.reserveCapacity(lines.count + 4)
        var furthestEnd = 0.0
        for line in lines {
            if line.start - furthestEnd >= minInterlude {
                out.append(interlude(start: furthestEnd, end: line.start))
            }
            furthestEnd = max(furthestEnd, line.end)
            out.append(line)
        }
        return out
    }

    private static func interlude(start: Double, end: Double) -> LyricsLine {
        LyricsLine(start: start, end: end, text: "", words: [], kind: .interlude, background: false)
    }
}

/// Scalar-level text helpers shared by the lyrics parsers. Swift `Character`
/// merges "\r\n" and combining marks, so everything here works on
/// `Unicode.Scalar`s the way Rust's `str` methods work on code points.
enum LyricsText {

    /// Rust `char::is_whitespace`: the Unicode White_Space property.
    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    static func string<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    static func trimStart(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        Array(scalars.drop(while: isWhitespace))
    }

    static func trimEnd(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var end = scalars.count
        while end > 0 && isWhitespace(scalars[end - 1]) {
            end -= 1
        }
        return Array(scalars[..<end])
    }

    static func trim(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        trimStart(trimEnd(scalars))
    }

    static func trim(_ text: String) -> String {
        string(trim(Array(text.unicodeScalars)))
    }

    static func trimStart(_ text: String) -> String {
        string(trimStart(Array(text.unicodeScalars)))
    }

    static func trimEnd(_ text: String) -> String {
        string(trimEnd(Array(text.unicodeScalars)))
    }

    static func droppingByteOrderMark(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard scalars.first == "\u{feff}" else { return text }
        return string(scalars.dropFirst())
    }

    /// Rust `str::lines`: split on "\n", drop one "\r" before each "\n", and
    /// produce no final empty line after a trailing "\n".
    static func lines(_ text: String) -> [String] {
        var parts = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
        var lastIsTerminated = true
        if let last = parts.last, last.isEmpty {
            parts.removeLast()
        } else {
            lastIsTerminated = false
        }
        var out: [String] = []
        out.reserveCapacity(parts.count)
        for (index, part) in parts.enumerated() {
            let terminated = index + 1 < parts.count || lastIsTerminated
            if terminated, part.last == "\r" {
                out.append(string(part.dropLast()))
            } else {
                out.append(string(part))
            }
        }
        return out
    }

    /// Rust `str::parse::<f64>` on the decimal forms: digits, sign, point and
    /// exponent only. Swift's own parser would also accept hexadecimal floats
    /// and `nan(...)`, which Rust rejects; infinities and NaN are dropped here
    /// because every caller rejects a non-finite result anyway.
    static func parseDouble(_ text: String) -> Double? {
        guard !text.isEmpty else { return nil }
        for scalar in text.unicodeScalars {
            switch scalar {
            case "0"..."9", "+", "-", ".", "e", "E":
                continue
            default:
                return nil
            }
        }
        return Double(text)
    }
}
