import Foundation

/// Reads lyrics files into `LyricsDocument`s. Mirrored in Rust as
/// `linux/shared/src/lyrics/lrc.rs` and `lyricsfile.rs`.
public enum LyricsParser {

    /// Parses an LRC or enhanced-LRC file. Word tags inside a line
    /// (`<mm:ss.xx>`) become timed words; a file with none is plain
    /// line-synced lyrics.
    public static func parseLRC(_ text: String) -> LyricsDocument {
        LyricsDocument.resolve(raw: parseRawLines(text), plain: nil, instrumental: false)
    }

    /// The lines of an LRC file as stated, one per timestamp: a line carrying
    /// several stamps appears once for each.
    public static func parseRawLines(_ text: String) -> [LyricsRawLine] {
        var lines: [LyricsRawLine] = []
        for rawLine in LyricsText.lines(LyricsText.droppingByteOrderMark(text)) {
            let (parsedStamps, content) = splitLineStamps(Array(rawLine.unicodeScalars))
            let segments = splitWordTags(content)
            let words = timedWords(from: segments, lineStart: parsedStamps.first)
            var stamps = parsedStamps
            if stamps.isEmpty, let first = words.first {
                stamps = [first.start]
            }
            let plain = words.isEmpty ? LyricsText.string(LyricsText.trim(content)) : ""
            for (index, stamp) in stamps.enumerated() {
                let shift = index == 0 || words.isEmpty ? 0.0 : stamp - stamps[0]
                lines.append(
                    LyricsRawLine(
                        start: stamp,
                        end: nil,
                        text: plain,
                        words: words.map { word in
                            LyricsRawWord(
                                start: word.start + shift,
                                end: word.end.map { $0 + shift },
                                text: word.text
                            )
                        }
                    )
                )
            }
        }
        return lines
    }

    /// Accepts `[mm:ss]`, `[mm:ss.xx]`, `[mm:ss:xx]` and `[hh:mm:ss.xx]`: all
    /// four appear in files in the wild, and rejecting one silently drops the
    /// whole set.
    public static func parseTimestamp(_ tag: String) -> Double? {
        let parts = LyricsText.trim(tag).unicodeScalars
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { LyricsText.string($0) }
        func seconds(_ text: String) -> Double? {
            LyricsText.parseDouble(text.replacingOccurrences(of: ",", with: "."))
        }
        let stamp: Double
        switch parts.count {
        case 2:
            guard let minutes = LyricsText.parseDouble(parts[0]), let rest = seconds(parts[1]) else {
                return nil
            }
            stamp = minutes * 60.0 + rest
        case 3:
            guard let first = LyricsText.parseDouble(parts[0]),
                let second = LyricsText.parseDouble(parts[1])
            else { return nil }
            if parts[2].utf8.count <= 2 && second < 60.0 && first < 60.0 && parts[0].utf8.count <= 2 {
                guard let fraction = LyricsText.parseDouble(parts[2]) else { return nil }
                stamp = first * 60.0 + second + fraction / 100.0
            } else {
                guard let rest = seconds(parts[2]) else { return nil }
                stamp = first * 3600.0 + second * 60.0 + rest
            }
        default:
            return nil
        }
        return stamp.isFinite && stamp >= 0.0 ? stamp : nil
    }

    private typealias Segment = (time: Double?, text: String)

    private static func index(of target: Unicode.Scalar, in scalars: [Unicode.Scalar], from start: Int) -> Int? {
        var index = start
        while index < scalars.count {
            if scalars[index] == target {
                return index
            }
            index += 1
        }
        return nil
    }

    /// The leading `[mm:ss.xx]` stamps of a line and what follows them. A
    /// leading tag that is not a timestamp (`[ar:Artist]`) ends the stamps
    /// and, with none found, makes the whole line metadata.
    private static func splitLineStamps(_ line: [Unicode.Scalar]) -> (stamps: [Double], content: [Unicode.Scalar]) {
        var rest = LyricsText.trimStart(line)
        var stamps: [Double] = []
        while rest.first == "[" {
            guard let close = index(of: "]", in: rest, from: 0) else { break }
            guard let stamp = parseTimestamp(LyricsText.string(rest[1..<close])) else { break }
            stamps.append(stamp)
            rest = Array(rest[(close + 1)...])
        }
        if stamps.isEmpty && rest.first == "[" {
            return (stamps, [])
        }
        return (stamps, rest)
    }

    /// Cuts a line at every valid `<mm:ss.xx>` tag. The first segment carries
    /// no time; each later one starts at the tag before it. Angle brackets
    /// that do not hold a timestamp stay in the text.
    private static func splitWordTags(_ content: [Unicode.Scalar]) -> [Segment] {
        var segments: [Segment] = []
        var pending: Double?
        var buffer: [Unicode.Scalar] = []
        var restStart = 0
        while let open = index(of: "<", in: content, from: restStart) {
            let afterStart = open + 1
            var tag: (close: Int, stamp: Double)?
            if let close = index(of: ">", in: content, from: afterStart),
                let stamp = parseTimestamp(LyricsText.string(content[afterStart..<close]))
            {
                tag = (close, stamp)
            }
            if let tag {
                buffer.append(contentsOf: content[restStart..<open])
                segments.append((pending, LyricsText.string(buffer)))
                buffer = []
                pending = tag.stamp
                restStart = tag.close + 1
            } else {
                buffer.append(contentsOf: content[restStart...open])
                restStart = afterStart
            }
        }
        buffer.append(contentsOf: content[restStart...])
        segments.append((pending, LyricsText.string(buffer)))
        if segments.count == 1 {
            return []
        }
        return segments
    }

    /// Turns segments into words. Text before the first tag belongs to a word
    /// that starts with the line; a tag followed by nothing closes the word
    /// before it.
    private static func timedWords(from segments: [Segment], lineStart: Double?) -> [LyricsRawWord] {
        var words: [LyricsRawWord] = []
        for (time, text) in segments {
            guard let stamp = time else {
                if !text.isEmpty, let start = lineStart {
                    words.append(LyricsRawWord(start: start, end: nil, text: text))
                }
                continue
            }
            if text.isEmpty {
                if let last = words.last, last.end == nil {
                    words[words.count - 1].end = stamp
                }
            } else {
                words.append(LyricsRawWord(start: stamp, end: nil, text: text))
            }
        }
        return words
    }
}
