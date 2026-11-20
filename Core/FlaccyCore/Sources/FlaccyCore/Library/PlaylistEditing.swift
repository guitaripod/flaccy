import Foundation

/// The rules every client follows when it changes a playlist: what an
/// addition really adds, where a drag leaves the songs it carries, and where
/// songs taken out go back when the person undoes it. Entries are addressed by
/// whatever stable id the client keeps for a row. Mirrored in Rust as
/// `linux/shared/src/playlist_editing.rs`.
public enum PlaylistEditing {

    /// What adding songs to a playlist does: the files it appends, in the
    /// order given and each once, and the files it leaves out because the
    /// playlist already holds them or the same addition named them twice.
    public struct Addition: Equatable, Sendable {
        public let added: [String]
        public let alreadyIn: [String]

        public init(added: [String], alreadyIn: [String]) {
            self.added = added
            self.alreadyIn = alreadyIn
        }
    }

    public static func addition(existing: [String], adding: [String]) -> Addition {
        let present = Set(existing)
        var held = present
        var reported = Set<String>()
        var added: [String] = []
        var alreadyIn: [String] = []
        for file in adding {
            if held.insert(file).inserted {
                added.append(file)
            } else if present.contains(file), reported.insert(file).inserted {
                alreadyIn.append(file)
            }
        }
        return Addition(added: added, alreadyIn: alreadyIn)
    }

    /// The order a drag leaves: the `moving` entries, in the order they held,
    /// lifted out and set down together at `insertionIndex`, an index into
    /// `order` as it stood before the drag (0 puts them first, `order.count`
    /// last). Entries `order` does not hold are ignored.
    public static func moved<ID: Hashable>(_ order: [ID], moving: Set<ID>, to insertionIndex: Int) -> [ID] {
        let carried = order.filter { moving.contains($0) }
        guard !carried.isEmpty else { return order }
        let clamped = min(max(insertionIndex, 0), order.count)
        let before = order[..<clamped].filter { !moving.contains($0) }
        let after = order[clamped...].filter { !moving.contains($0) }
        return before + carried + after
    }

    /// The index a single row dragged from `source` to `destination` in a
    /// list that reports where the row ends up (UIKit's table and collection
    /// views) is set down at, in `moved(_:moving:to:)`'s terms.
    public static func insertionIndex(movingRowFrom source: Int, to destination: Int) -> Int {
        destination > source ? destination + 1 : destination
    }

    /// The playlist's order once entries that were taken out go back where
    /// they stood: `kept` is the order now and `removed` names each entry with
    /// the index it held, so restoring them earliest first rebuilds the
    /// playlist as it was. An index past the end, after the playlist got
    /// shorter meanwhile, puts the entry last.
    public static func restored<ID>(kept: [ID], removed: [(id: ID, index: Int)]) -> [ID] {
        var order = kept
        for entry in removed.sorted(by: { $0.index < $1.index }) {
            order.insert(entry.id, at: min(max(entry.index, 0), order.count))
        }
        return order
    }

    /// A name for a copy of the playlist called `name` that no playlist in
    /// `taken` already carries: "Name Copy", then "Name Copy 2" and on.
    public static func copyName(of name: String, copyWord: String, taken: [String]) -> String {
        let names = Set(taken.map(HomeKeys.fold))
        let base = "\(name) \(copyWord)"
        guard names.contains(HomeKeys.fold(base)) else { return base }
        var number = 2
        while names.contains(HomeKeys.fold("\(base) \(number)")) { number += 1 }
        return "\(base) \(number)"
    }
}
