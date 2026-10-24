import Foundation

/// Where a clock stands inside a line that has timed words.
public enum LyricsLineProgress: Sendable, Equatable {
    case notStarted
    case singing(word: Int, fraction: Double)
    case done
}

/// First index in `values` for which `isBefore` is false, assuming every
/// element it holds for comes first (Rust `slice::partition_point`).
private func partitionPoint<Element>(_ values: [Element], _ isBefore: (Element) -> Bool) -> Int {
    var low = 0
    var high = values.count
    while low < high {
        let middle = low + (high - low) / 2
        if isBefore(values[middle]) {
            low = middle + 1
        } else {
            high = middle
        }
    }
    return low
}

extension LyricsLine {

    /// The word being sung at `time` and how far through it, or nil for a line
    /// without timed words. Between two words the earlier one counts as
    /// finished, so a fill never runs backwards.
    public func progress(at time: Double) -> LyricsLineProgress? {
        guard let first = words.first, let last = words.last else { return nil }
        if time < first.start {
            return .notStarted
        }
        if time >= last.end {
            return .done
        }
        let index = partitionPoint(words) { $0.start <= time } - 1
        let word = words[index]
        let span = word.end - word.start
        let fraction = span <= 0.0 ? 1.0 : min(max((time - word.start) / span, 0.0), 1.0)
        return .singing(word: index, fraction: fraction)
    }

    /// How far through an instrumental break `time` is, 0 to 1.
    public func interludeFraction(at time: Double) -> Double {
        let span = end - start
        if !isInterlude || span <= 0.0 {
            return 0.0
        }
        return min(max((time - start) / span, 0.0), 1.0)
    }

    /// How many of the interlude's beats are lit at `time`.
    public func litBeats(at time: Double) -> Int {
        let beats = LyricsDocument.interludeBeats
        let lit = Int((interludeFraction(at: time) * Double(beats)).rounded(.down))
        return min(lit, beats)
    }
}

extension LyricsDocument {

    /// The last line to have started by `time`: where a view keeps its scroll
    /// and its emphasis, even through the stretch after that line has ended.
    public func primaryIndex(at time: Double) -> Int? {
        let count = partitionPoint(lines) { $0.start <= time }
        return count == 0 ? nil : count - 1
    }

    /// Every line that should be lit at `time`: the primary one plus any other
    /// still sounding, in order.
    public func highlighted(at time: Double) -> [Int] {
        guard let primary = primaryIndex(at: time) else { return [] }
        let from = max(primary - Self.overlapLookback, 0)
        return (from...primary).filter { index in
            if index == primary {
                return true
            }
            let line = lines[index]
            return line.start <= time && time < line.end && !line.isInterlude
        }
    }

    /// The sung line's text at `time`, for a surface that shows one line of
    /// lyrics and nothing else: blank during a break and once a line has
    /// ended.
    public func text(at time: Double) -> String? {
        guard let index = primaryIndex(at: time) else { return nil }
        let line = lines[index]
        return !line.isInterlude && time < line.end ? line.text : nil
    }

    /// The next instant after `time` at which anything on screen could change:
    /// a line starting or ending, a word starting or ending, or an interlude
    /// lighting its next beat. Nil once the song has nothing left to say.
    public func nextBoundary(after time: Double) -> Double? {
        var best = Double.infinity
        func consider(_ at: Double) {
            if at > time && at < best {
                best = at
            }
        }
        let beats = Self.interludeBeats
        for line in lines {
            if line.start > best {
                break
            }
            consider(line.start)
            consider(line.end)
            for word in line.words {
                consider(word.start)
                consider(word.end)
            }
            if line.isInterlude && beats > 1 {
                for beat in 1..<beats {
                    consider(line.start + (line.end - line.start) * Double(beat) / Double(beats))
                }
            }
        }
        return best.isFinite ? best : nil
    }
}
