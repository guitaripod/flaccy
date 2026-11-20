import Foundation

/// A contiguous run of an album's items belonging to one physical disc or
/// vinyl side, named the way a listener holding the release would read it.
public struct DiscSection<T> {

    public let label: String
    public let items: [T]

    public init(label: String, items: [T]) {
        self.label = label
        self.items = items
    }
}

/// Disc-aware track ordering shared by every flaccy Apple client, a semantic
/// port of the verified Linux Rust reference (`linux/src/library.rs`). All
/// methods are generic over closures so the same logic drives the iOS `Track`
/// (`fileURL.path`), the `MediaItem` (`relativePath`), and the
/// `LightTrackRecord` (`fileURL`) without any of them importing the others.
public enum TrackOrdering {

    /// Orders an album's items for display. A `trackNumber` restarts at 1 on
    /// every disc of a multi-disc release and there is no disc column, so
    /// sorting by it alone collapses each disc's opener together. When the same
    /// non-zero track number appears more than once the release is multi-disc,
    /// and the file path (e.g. `a1, a2, b1` or `1-01, 2-01`) is the only
    /// reliable ordering signal, natural-sorted so numeric runs compare by
    /// value rather than lexically. Each item's sort key is folded once, not
    /// once per comparison: restoring a library orders every album this way
    /// while it holds the database.
    public static func ordered<T>(
        _ items: [T],
        number: (T) -> Int,
        path: (T) -> String,
        title: (T) -> String
    ) -> [T] {
        if isMultiDisc(items, number: number) {
            let keys = items.map { Array(path($0).lowercased().unicodeScalars) }
            return stableSorted(items, keys: keys, by: naturalCompare)
        }
        let keys = items.map { NumberedTitle(number: number($0), title: Array(title($0).lowercased().unicodeScalars)) }
        return stableSorted(items, keys: keys) { lhs, rhs in
            if lhs.number != rhs.number { return lhs.number < rhs.number ? .orderedAscending : .orderedDescending }
            return lexicographicScalarCompare(lhs.title, rhs.title)
        }
    }

    private struct NumberedTitle {
        let number: Int
        let title: [Unicode.Scalar]
    }

    /// Splits already-ordered items into physical disc/side sections when every
    /// item's path carries a consistent disc or side marker and at least two
    /// distinct sections result. Returns `nil` for a single unmarked unit so
    /// the caller renders one plain list — a normal album shouldn't sprout
    /// headers.
    public static func sections<T>(_ items: [T], path: (T) -> String) -> [DiscSection<T>]? {
        var labels: [String] = []
        labels.reserveCapacity(items.count)
        for item in items {
            guard let label = discLabel(path(item)) else { return nil }
            labels.append(label)
        }
        if Set(labels).count < 2 { return nil }

        var sections: [DiscSection<T>] = []
        var currentLabel: String?
        var currentItems: [T] = []
        for (item, label) in zip(items, labels) {
            if currentLabel == label {
                currentItems.append(item)
            } else {
                if let current = currentLabel {
                    sections.append(DiscSection(label: current, items: currentItems))
                }
                currentLabel = label
                currentItems = [item]
            }
        }
        if let current = currentLabel {
            sections.append(DiscSection(label: current, items: currentItems))
        }
        return sections
    }

    static func isMultiDisc<T>(_ items: [T], number: (T) -> Int) -> Bool {
        var seen = Set<Int>()
        for item in items {
            let value = number(item)
            if value > 0, !seen.insert(value).inserted { return true }
        }
        return false
    }

    /// Reads the disc/side marker from a file path: a leading vinyl side letter
    /// (`a1` → "Side A"), a `disc-track` numeric prefix (`1-05` → "Disc 1"), or
    /// a `CD2`/`Disc 3` parent folder. Title prefixes like `03-title` do not
    /// match because the character after the dash is not a digit.
    static func discLabel(_ relPath: String) -> String? {
        let file: String
        if let slash = relPath.lastIndex(of: "/") {
            file = String(relPath[relPath.index(after: slash)...])
        } else {
            file = relPath
        }

        let stem: String
        if let dot = file.lastIndex(of: ".") {
            stem = String(file[..<dot]).lowercased()
        } else {
            stem = file.lowercased()
        }
        let stemScalars = Array(stem.unicodeScalars)

        if stemScalars.count >= 2,
           isAsciiAlphabetic(stemScalars[0]),
           isAsciiDigit(stemScalars[1]) {
            return "Side \(String(stemScalars[0]).uppercased())"
        }

        if let dash = stemScalars.firstIndex(of: "-") {
            let head = stemScalars[..<dash]
            let tail = stemScalars[(dash + 1)...]
            if !head.isEmpty,
               head.allSatisfy(isAsciiDigit),
               let tailFirst = tail.first, isAsciiDigit(tailFirst),
               let disc = UInt32(String(String.UnicodeScalarView(head))) {
                return "Disc \(disc)"
            }
        }

        let parts = relPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 2 {
            let parent = parts[parts.count - 2].lowercased()
            for prefix in ["disc", "cd"] where parent.hasPrefix(prefix) {
                let rest = Array(parent.dropFirst(prefix.count).unicodeScalars)
                var index = 0
                while index < rest.count, rest[index] == " " || rest[index] == "-" || rest[index] == "_" {
                    index += 1
                }
                var digits = String.UnicodeScalarView()
                while index < rest.count, isAsciiDigit(rest[index]) {
                    digits.append(rest[index])
                    index += 1
                }
                if let disc = UInt32(String(digits)) {
                    return "Disc \(disc)"
                }
            }
        }

        return nil
    }

    /// Compares two strings so that embedded digit runs order by numeric value
    /// (`track2` before `track10`) while everything else compares by scalar.
    static func naturalCompare(_ a: String, _ b: String) -> ComparisonResult {
        naturalCompare(Array(a.unicodeScalars), Array(b.unicodeScalars))
    }

    private static func naturalCompare(_ av: [Unicode.Scalar], _ bv: [Unicode.Scalar]) -> ComparisonResult {
        var i = 0
        var j = 0
        while true {
            if i >= av.count, j >= bv.count { return .orderedSame }
            if i >= av.count { return .orderedAscending }
            if j >= bv.count { return .orderedDescending }

            let ac = av[i]
            let bc = bv[j]
            if isAsciiDigit(ac), isAsciiDigit(bc) {
                let aStart = i
                while i < av.count, isAsciiDigit(av[i]) { i += 1 }
                let bStart = j
                while j < bv.count, isAsciiDigit(bv[j]) { j += 1 }
                let an = av[aStart..<i]
                let bn = bv[bStart..<j]
                let aLen = trimmedZeroLength(an)
                let bLen = trimmedZeroLength(bn)
                if aLen != bLen { return aLen < bLen ? .orderedAscending : .orderedDescending }
                let ord = lexicographicScalarCompare(an, bn)
                if ord != .orderedSame { return ord }
            } else {
                if ac != bc { return ac.value < bc.value ? .orderedAscending : .orderedDescending }
                i += 1
                j += 1
            }
        }
    }

    static func lexicographicScalarCompare(_ a: String, _ b: String) -> ComparisonResult {
        lexicographicScalarCompare(Array(a.unicodeScalars), Array(b.unicodeScalars))
    }

    private static func lexicographicScalarCompare<Scalars: Collection<Unicode.Scalar>>(
        _ a: Scalars, _ b: Scalars
    ) -> ComparisonResult {
        var ai = a.startIndex
        var bi = b.startIndex
        while ai != a.endIndex, bi != b.endIndex {
            if a[ai].value != b[bi].value {
                return a[ai].value < b[bi].value ? .orderedAscending : .orderedDescending
            }
            a.formIndex(after: &ai)
            b.formIndex(after: &bi)
        }
        if ai == a.endIndex, bi == b.endIndex { return .orderedSame }
        return ai == a.endIndex ? .orderedAscending : .orderedDescending
    }

    private static func trimmedZeroLength(_ scalars: ArraySlice<Unicode.Scalar>) -> Int {
        var leadingZeros = 0
        for scalar in scalars {
            if scalar == "0" { leadingZeros += 1 } else { break }
        }
        return scalars.count - leadingZeros
    }

    private static func isAsciiDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 48 && scalar.value <= 57
    }

    private static func isAsciiAlphabetic(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
    }

    /// `items` ordered by their precomputed `keys`, equal keys keeping the
    /// order they came in.
    private static func stableSorted<T, Key>(
        _ items: [T], keys: [Key], by compare: (Key, Key) -> ComparisonResult
    ) -> [T] {
        items.indices
            .sorted { lhs, rhs in
                switch compare(keys[lhs], keys[rhs]) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: lhs < rhs
                }
            }
            .map { items[$0] }
    }
}
