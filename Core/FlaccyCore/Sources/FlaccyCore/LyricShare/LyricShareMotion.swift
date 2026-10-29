import Foundation

/// The selected line a frame is about and how far it has come in, 0 to 1.
/// `rank` is its place among the selection's sung lines.
public struct LyricShareFocus: Sendable, Equatable {
    public var index: Int
    public var rank: Int
    public var entrance: Double

    public init(index: Int, rank: Int, entrance: Double) {
        self.index = index
        self.rank = rank
        self.entrance = entrance
    }
}

/// How the lines of a clip move from frame to frame, so every client animates
/// the same template the same way. Mirrored in Rust as
/// `linux/shared/src/lyric_share/motion.rs`.
public enum LyricShareMotion {

    /// How long a line takes to come in.
    public static let entranceDuration = 0.42
    /// How far ahead of its start a line begins to come in, so it has landed
    /// by the time it is sung.
    public static let entranceLead = 0.12
    /// How bright a line is that is not the one being sung.
    public static let dim = 0.34
    /// How far, in line heights of the lyric size, a line rises as it comes in
    /// and the one before it rises as it leaves.
    public static let rise = 0.35

    /// The selection's sung lines, in order: the run without its interludes.
    public static func lines(of selection: LyricShareSelection, in document: LyricsDocument) -> [Int] {
        (selection.first...selection.last).filter { !document.lines[$0].isInterlude }
    }

    /// The selected line a frame at `time` is about: the last one to have
    /// started coming in, or the first while none has. The first line comes
    /// in with the clip itself.
    public static func focus(
        _ selection: LyricShareSelection, in document: LyricsDocument, at time: Double, clipStart: Double
    ) -> LyricShareFocus {
        let sung = lines(of: selection, in: document)
        var rank = 0
        for (position, index) in sung.enumerated() where document.lines[index].start - entranceLead <= time {
            rank = position
        }
        let index = sung[rank]
        let from = rank == 0 ? clipStart : document.lines[index].start - entranceLead
        return LyricShareFocus(index: index, rank: rank, entrance: ease((time - from) / entranceDuration))
    }

    /// Ease-out cubic over 0 to 1, clamped.
    public static func ease(_ x: Double) -> Double {
        let clamped = min(max(x, 0.0), 1.0)
        let rest = 1 - clamped
        return 1 - rest * rest * rest
    }

    /// Where a scrolling stack stands: the focused line's rank, reached as it
    /// comes in, so the stack glides from one line to the next.
    public static func scrollPosition(_ focus: LyricShareFocus) -> Double {
        focus.rank == 0 ? 0 : Double(focus.rank - 1) + focus.entrance
    }

    /// How bright the line at `rank` is in a frame. A verse lights the line
    /// being sung and lets the one before it go; a poster keeps every sung
    /// line lit; spotlight and pulse show one line, so the value is its
    /// opacity as one crossfades into the next.
    public static func ink(rank: Int, focus: LyricShareFocus, template: LyricShareTemplate) -> Double {
        let entrance = focus.entrance
        switch template {
        case .verse:
            if rank == focus.rank { return dim + (1 - dim) * entrance }
            if rank == focus.rank - 1 { return 1 - (1 - dim) * entrance }
            return dim
        case .poster:
            if rank < focus.rank { return 1 }
            if rank == focus.rank { return dim + (1 - dim) * entrance }
            return dim
        case .spotlight, .pulse:
            if rank == focus.rank { return entrance }
            if rank == focus.rank - 1 { return 1 - entrance }
            return 0
        }
    }
}

/// The shape of the audio picture each template draws, the same on every
/// client.
public enum LyricShareVisualizer {

    /// The share of each bar's slot left empty between bars.
    public static let gapRatio = 0.44
    /// The shortest bar, as a share of the strip's height, so silence still
    /// reads as a strip.
    public static let minimumBar = 0.08
    /// The ring around the pulse disc starts this far out, in disc radii.
    public static let ringInner = 1.1
    /// The longest ring bar, in disc radii.
    public static let ringLength = 0.32
    /// How much the pulse disc grows at full level.
    public static let discPulse = 0.05

    /// A strip's bars: the bands mirrored, lows in the middle.
    public static func strip(_ bands: [Float]) -> [Float] {
        bands.reversed() + bands
    }

    /// A ring's bars clockwise from the top: lows at the top, the highs
    /// meeting at the bottom.
    public static func ring(_ bands: [Float]) -> [Float] {
        bands + bands.reversed()
    }
}
