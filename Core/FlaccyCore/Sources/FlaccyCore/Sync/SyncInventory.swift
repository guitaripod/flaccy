import Foundation

/// What the watch holds: stored relative path to byte size, indexed by stem.
///
/// The watch keeps at most one audio file per stem, so inserting a file that
/// shares a stem with another extension displaces the other and reports it for
/// the caller to delete. Paths are canonicalised, so a name read back from disk
/// in decomposed form still matches the form the phone sent.
public struct SyncInventory: Sendable, Equatable {

    private var sizes: [String: Int64] = [:]
    private var pathsByStem: [String: Set<String>] = [:]

    public init() {}

    public init(_ entries: [String: Int64]) {
        for (path, size) in entries {
            _ = insert(path: path, size: size)
        }
    }

    public var count: Int { sizes.count }
    public var usedBytes: Int64 { sizes.values.reduce(0, +) }
    public var paths: [String] { sizes.keys.sorted() }
    public var isEmpty: Bool { sizes.isEmpty }

    public func contains(stem: String) -> Bool {
        pathsByStem[canonicalSyncPath(stem)] != nil
    }

    public func contains(path: String) -> Bool {
        sizes[canonicalSyncPath(path)] != nil
    }

    public func size(of path: String) -> Int64? {
        sizes[canonicalSyncPath(path)]
    }

    public func paths(forStem stem: String) -> [String] {
        (pathsByStem[canonicalSyncPath(stem)] ?? []).sorted()
    }

    /// Records `path` and returns the other-extension files of the same stem
    /// that the caller must delete from disk; they are already forgotten here.
    @discardableResult
    public mutating func insert(path: String, size: Int64) -> [String] {
        let canonical = canonicalSyncPath(path)
        let stem = SyncStem.of(canonical)
        let siblings = (pathsByStem[stem] ?? []).filter { $0 != canonical }.sorted()
        for sibling in siblings {
            sizes[sibling] = nil
        }
        sizes[canonical] = max(0, size)
        pathsByStem[stem] = [canonical]
        return siblings
    }

    @discardableResult
    public mutating func remove(path: String) -> Bool {
        let canonical = canonicalSyncPath(path)
        guard sizes.removeValue(forKey: canonical) != nil else { return false }
        let stem = SyncStem.of(canonical)
        pathsByStem[stem]?.remove(canonical)
        if pathsByStem[stem]?.isEmpty == true { pathsByStem[stem] = nil }
        return true
    }

    /// Forgets every file of `stem` and returns the paths that were stored.
    @discardableResult
    public mutating func remove(stem: String) -> [String] {
        let key = canonicalSyncPath(stem)
        guard let removed = pathsByStem.removeValue(forKey: key) else { return [] }
        for path in removed {
            sizes[path] = nil
        }
        return removed.sorted()
    }

    public mutating func removeAll() {
        sizes.removeAll()
        pathsByStem.removeAll()
    }
}

extension SyncInventory {

    /// One walk of `directory` that reads every audio file's size. This is the
    /// only place the disk is enumerated; after it the inventory is kept
    /// current by the operations that change the disk.
    public static func scanning(directory: URL) -> SyncInventory {
        let base = directory.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return SyncInventory() }

        var entries: [String: Int64] = [:]
        for case let url as URL in enumerator {
            guard LibraryScanner.supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile != false else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(base) else { continue }
            let relative = full.dropFirst(base.count).drop { $0 == "/" }
            entries[canonicalSyncPath(String(relative))] = Int64(values?.fileSize ?? 0)
        }
        return SyncInventory(entries)
    }
}
