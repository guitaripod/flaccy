import Foundation

/// The lines a clip holds, as the first and last index of a run of lines.
/// For synced lyrics both index `LyricsDocument.lines` and are never an
/// interlude; for plain lyrics they index `LyricShareClip.plainLines`.
public struct LyricShareSelection: Sendable, Equatable {
    public var first: Int
    public var last: Int

    public init(first: Int, last: Int) {
        self.first = first
        self.last = last
    }

    public func contains(_ index: Int) -> Bool {
        index >= first && index <= last
    }
}

/// The stretch of the song a clip plays. `lyricStart` is on the lyrics clock;
/// the audio is that moment plus the listener's timing correction.
public struct LyricShareWindow: Sendable, Equatable {
    public var lyricStart: Double
    public var duration: Double
    public var offset: Double

    public init(lyricStart: Double, duration: Double, offset: Double) {
        self.lyricStart = lyricStart
        self.duration = duration
        self.offset = offset
    }

    public var audioStart: Double {
        lyricStart + offset
    }

    public var lyricEnd: Double {
        lyricStart + duration
    }
}

/// Which lines a lyric clip starts with, how a tap changes them, and the
/// stretch of audio and frames that follow. Mirrored in Rust as
/// `linux/shared/src/lyric_share/clip.rs`.
public enum LyricShareClip {

    /// The longest clip: what every story and short-video app takes whole.
    public static let maxDuration = 30.0
    /// The shortest clip, so a single short line still has music around it.
    public static let minDuration = 6.0
    /// Music before the first line, so the clip does not open mid-breath.
    public static let leadIn = 0.6
    /// Music after the last line ends.
    public static let tail = 1.4
    /// How long the lines a clip starts with may run.
    public static let defaultSpan = 15.0
    /// How many lines a clip starts with at most.
    public static let defaultLines = 4
    /// How many plain lines one card holds, since they are all on screen at once.
    public static let maxPlainLines = 6
    /// How long a clip of plain lyrics plays.
    public static let plainDuration = 15.0
    public static let fps = 30
    public static let fadeIn = 0.3
    public static let fadeOut = 0.9

    /// The lines of plain lyrics a card can hold: trimmed, blank ones dropped.
    public static func plainLines(_ plain: String) -> [String] {
        LyricsText.lines(plain)
            .map { LyricsText.trim($0) }
            .filter { !$0.isEmpty }
    }

    public static func isSelectable(_ index: Int, in document: LyricsDocument) -> Bool {
        document.lines.indices.contains(index) && !document.lines[index].isInterlude
    }

    /// The lines a clip starts with. With the song's clock, the line being
    /// sung or the next one to come; without it, the chorus, else the first
    /// line. Then the lines after it while they fit the default span.
    public static func defaultSelection(in document: LyricsDocument, at time: Double?) -> LyricShareSelection? {
        let texts = document.lines.indices.filter { !document.lines[$0].isInterlude }
        guard let firstText = texts.first, let lastText = texts.last else { return nil }
        let start: Int
        if let time {
            if let primary = document.primaryIndex(at: time),
               !document.lines[primary].isInterlude,
               time < document.lines[primary].end {
                start = primary
            } else {
                start = texts.first { document.lines[$0].start > time } ?? lastText
            }
        } else {
            start = chorusStart(in: document, among: texts) ?? firstText
        }
        var last = start
        var count = 1
        while count < defaultLines, let next = nextText(after: last, in: document) {
            if document.lines[next].end - document.lines[start].start > defaultSpan {
                break
            }
            last = next
            count += 1
        }
        return LyricShareSelection(first: start, last: last)
    }

    /// The first plain lines, or from the chorus when one line repeats.
    public static func defaultPlainSelection(lines: [String]) -> LyricShareSelection? {
        guard !lines.isEmpty else { return nil }
        let start = mostRepeated(lines.map(normalized)) ?? 0
        let last = min(start + defaultLines - 1, lines.count - 1)
        return LyricShareSelection(first: start, last: last)
    }

    /// What a tap on a line makes of the selection, which always stays one
    /// unbroken run. A line outside it extends the run to reach it, letting go
    /// of lines at the far end if the clip would grow too long; the first or
    /// last line drops out; a line inside becomes the new last line. The last
    /// remaining line cannot be taken away.
    public static func toggle(
        _ selection: LyricShareSelection, line index: Int, in document: LyricsDocument
    ) -> LyricShareSelection {
        guard isSelectable(index, in: document) else { return selection }
        var next = selection
        if index < selection.first {
            next.first = index
            while !fits(next, in: document), next.last > index,
                  let earlier = previousText(before: next.last, in: document) {
                next.last = earlier
            }
        } else if index > selection.last {
            next.last = index
            while !fits(next, in: document), next.first < index,
                  let later = nextText(after: next.first, in: document) {
                next.first = later
            }
        } else if selection.first == selection.last {
            return selection
        } else if index == selection.first {
            next.first = nextText(after: index, in: document) ?? selection.first
        } else if index == selection.last {
            next.last = previousText(before: index, in: document) ?? selection.last
        } else {
            next.last = index
        }
        return next
    }

    /// The same rule for plain lines, where the limit is a count rather than a
    /// length of time.
    public static func togglePlain(_ selection: LyricShareSelection, line index: Int, count: Int) -> LyricShareSelection {
        guard index >= 0, index < count else { return selection }
        var next = selection
        if index < selection.first {
            next.first = index
            next.last = min(next.last, index + maxPlainLines - 1)
        } else if index > selection.last {
            next.last = index
            next.first = max(next.first, index - maxPlainLines + 1)
        } else if selection.first == selection.last {
            return selection
        } else if index == selection.first {
            next.first += 1
        } else if index == selection.last {
            next.last -= 1
        } else {
            next.last = index
        }
        return next
    }

    /// From the first selected line's start to the last one's end.
    public static func span(of selection: LyricShareSelection, in document: LyricsDocument) -> Double {
        document.lines[selection.last].end - document.lines[selection.first].start
    }

    /// A single line always fits; a longer run fits while it and the lead-in
    /// play within the longest clip. The tail is trimmed before a line is.
    public static func fits(_ selection: LyricShareSelection, in document: LyricsDocument) -> Bool {
        selection.first == selection.last || span(of: selection, in: document) + leadIn <= maxDuration
    }

    /// The stretch a selection plays: a breath before the first line, the
    /// tail after the last, at least the shortest clip and at most the
    /// longest, never before the song starts or past its end.
    public static func window(
        for selection: LyricShareSelection, in document: LyricsDocument, offset: Double, trackDuration: Double
    ) -> LyricShareWindow {
        let first = document.lines[selection.first]
        let last = document.lines[selection.last]
        let floor = max(0.0, -offset)
        var start = max(first.start - leadIn, floor)
        var end = max(last.end + tail, start + minDuration)
        end = min(end, start + maxDuration)
        if trackDuration > 0 {
            let limit = trackDuration - offset
            if end > limit {
                end = limit
                start = max(min(start, end - minDuration), floor)
            }
        }
        return LyricShareWindow(lyricStart: start, duration: max(end - start, 0.0), offset: offset)
    }

    /// The stretch a card of plain lyrics plays, from where the listener chose.
    public static func plainWindow(start: Double, trackDuration: Double) -> LyricShareWindow {
        var from = max(start, 0.0)
        var duration = plainDuration
        if trackDuration > 0 {
            from = min(from, max(trackDuration - plainDuration, 0.0))
            duration = min(plainDuration, trackDuration - from)
        }
        return LyricShareWindow(lyricStart: from, duration: max(duration, 0.0), offset: 0)
    }

    public static func frameCount(_ window: LyricShareWindow) -> Int {
        max(1, Int((window.duration * Double(fps) - 1e-9).rounded(.up)))
    }

    /// The lyrics clock at a frame of the clip.
    public static func time(ofFrame frame: Int, in window: LyricShareWindow) -> Double {
        window.lyricStart + Double(frame) / Double(fps)
    }

    /// How loud the clip's audio is at `time` seconds into it: a short fade in
    /// and a longer fade out, each an S-curve.
    public static func gain(at time: Double, duration: Double) -> Double {
        guard time >= 0, time <= duration else { return 0 }
        let rise = time / fadeIn
        let fall = (duration - time) / fadeOut
        let x = min(max(min(rise, fall, 1.0), 0.0), 1.0)
        return x * x * (3 - 2 * x)
    }

    static func nextText(after index: Int, in document: LyricsDocument) -> Int? {
        var at = index + 1
        while at < document.lines.count {
            if !document.lines[at].isInterlude { return at }
            at += 1
        }
        return nil
    }

    static func previousText(before index: Int, in document: LyricsDocument) -> Int? {
        var at = index - 1
        while at >= 0 {
            if !document.lines[at].isInterlude { return at }
            at -= 1
        }
        return nil
    }

    /// The first time the most repeated line is sung, when any line repeats.
    static func chorusStart(in document: LyricsDocument, among texts: [Int]) -> Int? {
        let keys = texts.map { normalized(document.lines[$0].text) }
        return mostRepeated(keys).map { texts[$0] }
    }

    /// The position of the first occurrence of the key that occurs most often,
    /// the earliest such key on a tie, or nil when nothing repeats.
    static func mostRepeated(_ keys: [String]) -> Int? {
        var counts: [String: Int] = [:]
        for key in keys where !key.isEmpty {
            counts[key, default: 0] += 1
        }
        var best: (position: Int, count: Int)?
        var seen: Set<String> = []
        for (position, key) in keys.enumerated() where !key.isEmpty && !seen.contains(key) {
            seen.insert(key)
            let count = counts[key] ?? 0
            if count >= 2, count > (best?.count ?? 0) {
                best = (position, count)
            }
        }
        return best?.position
    }

    /// Lowercase letters and digits with single spaces between words, so
    /// "Hold on!" and "hold on" are one line.
    static func normalized(_ text: String) -> String {
        var words: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                current.append(scalar)
            } else if !current.isEmpty {
                words.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty {
            words.append(String(current))
        }
        return words.joined(separator: " ")
    }
}
