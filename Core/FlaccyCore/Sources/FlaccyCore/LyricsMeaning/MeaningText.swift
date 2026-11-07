import Foundation

/// Text cut to a budget measured the way the flaccy-api Worker measures it.
/// Mirrored in Rust as `linux/shared/src/meaning/text.rs`.
public enum MeaningText {

    /// Sentence ends that need a space after them, and the full-width ones
    /// that do not.
    private static let sentenceEnds: Set<Unicode.Scalar> = [".", "!", "?"]
    private static let wideSentenceEnds: Set<Unicode.Scalar> = ["\u{3002}", "\u{FF01}", "\u{FF1F}"]
    /// The least room worth filling with part of a paragraph after a whole one.
    private static let smallestTail = 120
    private static let ellipsis = "\u{2026}"

    /// Length in UTF-16 units, as JavaScript's `length` counts it.
    public static func utf16Length(_ text: String) -> Int {
        text.utf16.count
    }

    /// Whole paragraphs, trimmed and joined by a blank line, up to `limit`
    /// UTF-16 units. A paragraph that does not fit whole is cut after its last
    /// sentence that does, or after a word with an ellipsis, and nothing
    /// follows it.
    public static func clip(_ paragraphs: [String], limit: Int) -> String {
        var out = ""
        var used = 0
        for raw in paragraphs {
            let paragraph = LyricsText.trim(raw)
            guard !paragraph.isEmpty else { continue }
            let separator = out.isEmpty ? 0 : 2
            let length = utf16Length(paragraph)
            if used + separator + length <= limit {
                if separator > 0 { out += "\n\n" }
                out += paragraph
                used += separator + length
                continue
            }
            let room = max(0, limit - used - separator)
            if out.isEmpty || room >= smallestTail, let head = cut(paragraph, room: room) {
                if separator > 0 { out += "\n\n" }
                out += head
            }
            break
        }
        return out
    }

    /// The longest head of `text` within `room` units that ends a sentence,
    /// when that keeps at least half of what fits; otherwise the head that
    /// ends a word, or failing that the head that fits, followed by an
    /// ellipsis.
    private static func cut(_ text: String, room: Int) -> String? {
        let scalars = Array(text.unicodeScalars)
        let fits = fitting(scalars, room: room)
        if let end = stride(from: fits, through: 1, by: -1).first(where: { endsSentence(scalars, at: $0) }),
           end * 2 >= fits {
            return LyricsText.string(scalars[..<end])
        }
        let shorter = fitting(scalars, room: max(0, room - 1))
        guard shorter > 0 else { return nil }
        let word = stride(from: shorter, through: 1, by: -1).first { end in
            end >= scalars.count || LyricsText.isWhitespace(scalars[end])
        }
        let end = word ?? shorter
        return LyricsText.trimEnd(LyricsText.string(scalars[..<end])) + ellipsis
    }

    /// How many leading scalars fit in `room` UTF-16 units.
    private static func fitting(_ scalars: [Unicode.Scalar], room: Int) -> Int {
        var used = 0
        for (index, scalar) in scalars.enumerated() {
            used += UTF16.width(scalar)
            if used > room { return index }
        }
        return scalars.count
    }

    private static func endsSentence(_ scalars: [Unicode.Scalar], at end: Int) -> Bool {
        let last = scalars[end - 1]
        if wideSentenceEnds.contains(last) { return true }
        return sentenceEnds.contains(last) && (end >= scalars.count || LyricsText.isWhitespace(scalars[end]))
    }
}
