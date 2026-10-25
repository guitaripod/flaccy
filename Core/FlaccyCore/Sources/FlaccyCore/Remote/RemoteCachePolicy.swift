import Foundation

/// Decides which cached remote files to evict once the cache outgrows its cap.
///
/// Pinned entries sit outside the cap and are never evicted. Among the rest, the least
/// recently used go first, ties broken by key, and protected keys (the playing and the
/// preloaded items) are skipped so playback never loses the file under it.
///
/// Mirrored in Rust as `linux/shared/src/remote/cache_policy.rs`, with times in milliseconds.
public enum RemoteCachePolicy {

    public static let defaultCapBytes: Int64 = 2_147_483_648

    public struct Entry: Equatable, Sendable {
        public let key: String
        public let bytes: Int64
        public let lastUsed: Date
        public let pinned: Bool

        public init(key: String, bytes: Int64, lastUsed: Date, pinned: Bool) {
            self.key = key
            self.bytes = bytes
            self.lastUsed = lastUsed
            self.pinned = pinned
        }
    }

    /// The keys to delete, in eviction order, so the unpinned total fits under `capBytes`.
    /// Returns nothing while the total is at or under the cap, and stops early once it fits.
    public static func victims(entries: [Entry], capBytes: Int64, protected: Set<String>) -> [String] {
        let unpinned = entries.filter { !$0.pinned }
        var total = unpinned.reduce(0) { $0 + $1.bytes }
        guard total > capBytes else { return [] }
        var evicted: [String] = []
        for entry in unpinned.sorted(by: isEvictedBefore) where total > capBytes {
            guard !protected.contains(entry.key) else { continue }
            evicted.append(entry.key)
            total -= entry.bytes
        }
        return evicted
    }

    private static func isEvictedBefore(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.lastUsed != rhs.lastUsed {
            return lhs.lastUsed < rhs.lastUsed
        }
        return lhs.key < rhs.key
    }
}
