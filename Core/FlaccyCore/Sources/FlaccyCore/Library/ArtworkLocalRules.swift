import Foundation

/// Which images lying next to a release's music files are worth offering as
/// its cover, and in what order. File access stays with each client; this is
/// the part that must not drift: what counts as an image, which names are the
/// front cover, which are scans of the back or thumbnails nobody wants, and
/// which folders belong to a release. Mirrored in Rust as
/// `linux/shared/src/artwork_local.rs`.
public enum ArtworkLocalRules {

    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp"]

    /// Larger files are skipped rather than decoded: a 60 MB scan of a booklet
    /// is not a cover.
    public static let maximumFileBytes = 25 * 1024 * 1024

    public static let maximumImagesPerFolder = 12

    private static let frontNames = ["cover", "folder", "front", "albumart", "album", "artwork", "art"]
    private static let frontHints = ["cover", "front"]
    private static let backWords: Set<String> = ["disc", "disk", "cd", "inlay", "booklet", "tray", "spine", "obi"]
    private static let backPrefixes = ["back", "rear"]

    /// An image by extension, not hidden (this includes macOS `._name`
    /// resource forks on foreign volumes) and not a thumbnail.
    public static func isCandidate(fileName: String) -> Bool {
        guard !fileName.hasPrefix("."), let dot = fileName.lastIndex(of: ".") else { return false }
        let ext = fileName[fileName.index(after: dot)...].lowercased()
        guard imageExtensions.contains(ext) else { return false }
        return !isThumbnail(stem: String(fileName[..<dot]).lowercased())
    }

    /// The candidates among `names`, front covers first, then anything that
    /// merely sounds like one, then the rest, scans of the back last; ties
    /// alphabetical so the order never depends on directory enumeration.
    public static func rank(_ names: [String]) -> [String] {
        let ranked = names.filter(isCandidate).map { (name: $0, tier: tier(of: $0)) }
        let ordered = ranked.sorted { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            let order = lhs.name.lowercased().compare(rhs.name.lowercased())
            return order == .orderedSame ? lhs.name < rhs.name : order == .orderedAscending
        }
        return Array(ordered.prefix(maximumImagesPerFolder).map(\.name))
    }

    /// The folders to look in for a release whose tracks sit at
    /// `relativePaths` under the library root: the folder every track shares
    /// first (where a multi-disc release keeps its one cover), then each
    /// track's own folder. The root itself is never offered, because images
    /// there belong to no particular release.
    public static func folders(forRelativePaths relativePaths: [String]) -> [String] {
        let parents = Set(relativePaths.compactMap { path -> String? in
            let parts = path.split(separator: "/").dropLast()
            return parts.isEmpty ? nil : parts.joined(separator: "/")
        })
        guard !parents.isEmpty else { return [] }
        let shared = commonAncestor(of: parents)
        var result: [String] = []
        if !shared.isEmpty, !parents.contains(shared) { result.append(shared) }
        result.append(contentsOf: parents.sorted())
        return result
    }

    private static func tier(of fileName: String) -> Int {
        let stem = String(fileName[..<(fileName.lastIndex(of: ".") ?? fileName.endIndex)]).lowercased()
        if let index = frontNames.firstIndex(of: stem) { return index }
        if stem.hasPrefix("albumart") { return 3 }
        if isBack(stem: stem) { return 90 }
        if frontHints.contains(where: { stem.contains($0) }) { return 10 }
        return 20
    }

    /// Windows Media Player's `AlbumArtSmall.jpg` and `AlbumArt_{id}_Small.jpg`
    /// and any `thumb…` file: smaller copies of a cover that sits beside them.
    private static func isThumbnail(stem: String) -> Bool {
        words(of: stem).contains { $0 == "small" || $0.hasPrefix("thumb") || $0 == "albumartsmall" }
    }

    private static func isBack(stem: String) -> Bool {
        words(of: stem).contains { word in
            backWords.contains(word) || backPrefixes.contains { word.hasPrefix($0) }
        }
    }

    /// Lowercase alphanumeric runs of a file stem with trailing digits dropped,
    /// so `CD2` reads as `cd` and `acdc` does not read as one.
    private static func words(of stem: String) -> [String] {
        stem.split { !$0.isLetter && !$0.isNumber }.map { word in
            var trimmed = Substring(word)
            while let last = trimmed.last, last.isNumber, trimmed.count > 1 { trimmed = trimmed.dropLast() }
            return String(trimmed)
        }
    }

    private static func commonAncestor(of folders: Set<String>) -> String {
        var shared: [Substring]?
        for folder in folders {
            let parts = folder.split(separator: "/")
            guard let current = shared else {
                shared = parts
                continue
            }
            var kept: [Substring] = []
            for (left, right) in zip(current, parts) {
                guard left == right else { break }
                kept.append(left)
            }
            shared = kept
        }
        return (shared ?? []).joined(separator: "/")
    }
}
