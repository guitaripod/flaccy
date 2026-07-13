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
    /// value rather than lexically.
    public static func ordered<T>(
        _ items: [T],
        number: (T) -> Int,
        path: (T) -> String,
        title: (T) -> String
    ) -> [T] {
        if isMultiDisc(items, number: number) {
            return stableSorted(items) {
                naturalCompare(path($0).lowercased(), path($1).lowercased()) == .orderedAscending
            }
        }
        return stableSorted(items) { lhs, rhs in
            let ln = number(lhs)
            let rn = number(rhs)
            if ln != rn { return ln < rn }
            return lexicographicScalarCompare(title(lhs).lowercased(), title(rhs).lowercased()) == .orderedAscending
        }
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
        let av = Array(a.unicodeScalars)
        let bv = Array(b.unicodeScalars)
        var i = 0
        var j = 0
        while true {
            if i >= av.count, j >= bv.count { return .orderedSame }
            if i >= av.count { return .orderedAscending }
            if j >= bv.count { return .orderedDescending }

            let ac = av[i]
            let bc = bv[j]
            if isAsciiDigit(ac), isAsciiDigit(bc) {
                var an = String.UnicodeScalarView()
                while i < av.count, isAsciiDigit(av[i]) {
                    an.append(av[i])
                    i += 1
                }
                var bn = String.UnicodeScalarView()
                while j < bv.count, isAsciiDigit(bv[j]) {
                    bn.append(bv[j])
                    j += 1
                }
                let aLen = trimmedZeroLength(an)
                let bLen = trimmedZeroLength(bn)
                if aLen != bLen { return aLen < bLen ? .orderedAscending : .orderedDescending }
                let ord = lexicographicScalarCompare(String(an), String(bn))
                if ord != .orderedSame { return ord }
            } else {
                if ac != bc { return ac.value < bc.value ? .orderedAscending : .orderedDescending }
                i += 1
                j += 1
            }
        }
    }

    static func lexicographicScalarCompare(_ a: String, _ b: String) -> ComparisonResult {
        let av = Array(a.unicodeScalars)
        let bv = Array(b.unicodeScalars)
        var i = 0
        while i < av.count, i < bv.count {
            if av[i].value != bv[i].value {
                return av[i].value < bv[i].value ? .orderedAscending : .orderedDescending
            }
            i += 1
        }
        if av.count == bv.count { return .orderedSame }
        return av.count < bv.count ? .orderedAscending : .orderedDescending
    }

    private static func trimmedZeroLength(_ scalars: String.UnicodeScalarView) -> Int {
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

    private static func stableSorted<T>(_ items: [T], _ areInIncreasingOrder: (T, T) -> Bool) -> [T] {
        items.enumerated()
            .sorted { lhs, rhs in
                if areInIncreasingOrder(lhs.element, rhs.element) { return true }
                if areInIncreasingOrder(rhs.element, lhs.element) { return false }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
