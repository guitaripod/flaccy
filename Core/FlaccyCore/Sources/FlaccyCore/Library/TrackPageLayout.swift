import Foundation

/// How a page of songs arranges itself in the room it has: when its hero
/// stacks, when it moves into a rail, how many columns the songs flow over and
/// which layouts a page offers. Pure, so every client decides the same way.
/// Mirrored in Rust as `linux/shared/src/track_page_layout.rs`.
public enum TrackPageLayout {

    /// At or below this width the hero stacks over a smaller cover.
    public static let compactMax = 560
    /// From this width the hero moves into a rail beside the song list, so Play
    /// and Shuffle stay in reach however far the list is scrolled.
    public static let wideMin = 1100
    /// Pages with at least this many songs get a filter box.
    public static let filterThreshold = 8
    /// An album with fewer songs than this per column is never split over
    /// several columns.
    public static let songsPerColumn = 6

    public enum Layout: String, Sendable, CaseIterable, Equatable {
        case list
        case table
        case columns

        public init(id: String) {
            self = Layout(rawValue: id) ?? .list
        }

        public var id: String { rawValue }

        /// Columns flow an album's discs side by side; a playlist is one run
        /// the listener orders by hand, which a column break would cut in two.
        public func isOffered(on kind: PageKind) -> Bool {
            self != .columns || kind == .album
        }

        /// The layout a page actually draws for a remembered choice.
        public func resolved(for kind: PageKind) -> Layout {
            isOffered(on: kind) ? self : .list
        }
    }

    public enum PageKind: Sendable, Equatable {
        case album
        case playlist
    }

    public enum Mode: Sendable, Equatable {
        case compact
        case regular
        case wide
    }

    public static func mode(forWidth width: Int) -> Mode {
        if width <= compactMax { return .compact }
        if width >= wideMin { return .wide }
        return .regular
    }

    /// How many side-by-side columns a pane of `width` points has room for,
    /// never more than there are blocks of songs to put in them.
    public static func columnCount(width: Int, blocks: Int) -> Int {
        let fit: Int
        switch width {
        case ..<880: fit = 1
        case 880..<1360: fit = 2
        default: fit = 3
        }
        return min(fit, max(blocks, 1))
    }

    /// Splits consecutive blocks (a disc, or a side) over `columns` runs of the
    /// order they already have, so the heights come out as even as the blocks
    /// allow. Returns half-open ranges of block indices.
    public static func balanceColumns(sizes: [Int], columns: Int) -> [Range<Int>] {
        guard !sizes.isEmpty else { return [0..<0] }
        let columns = min(max(columns, 1), sizes.count)
        let total = sizes.reduce(0, +)
        var ranges: [Range<Int>] = []
        var start = 0
        var taken = 0
        for column in 0..<columns {
            let remainingColumns = columns - column
            if remainingColumns == 1 {
                ranges.append(start..<sizes.count)
                break
            }
            let target = (total - taken + remainingColumns - 1) / remainingColumns
            let latestEnd = sizes.count - (remainingColumns - 1)
            var end = start
            var height = 0
            while end < latestEnd && (end == start || height + sizes[end] / 2 < target) {
                height += sizes[end]
                end += 1
            }
            taken += height
            ranges.append(start..<end)
            start = end
        }
        return ranges
    }

    /// Cuts `count` songs into `columns` equal consecutive runs, for an album
    /// with no discs to follow.
    public static func evenRuns(count: Int, columns: Int) -> [Range<Int>] {
        let columns = min(max(columns, 1), max(count, 1))
        let size = max((count + columns - 1) / columns, 1)
        return (0..<columns)
            .map { min($0 * size, count)..<min(($0 + 1) * size, count) }
            .filter { !$0.isEmpty }
    }
}
