import FlaccyCore
import FlaccyEngine
import Foundation
import os

/// A fold of a title and an artist, remembered per spelling across builds.
/// Folding is the costly step of every mix, station and duplicate pass, and a
/// library asks for the same few thousand spellings each time Home refreshes,
/// where `ListenKeyMemo` only lasts one pass over the history.
nonisolated final class SpellingMemo: Sendable {

    static let listenKeys = SpellingMemo { ListenHistory.trackKey(title: $0, artist: $1) }
    static let songKeys = SpellingMemo { LibraryHygiene.songKey(title: $0, artist: $1) }

    private static let capacity = 60_000

    private let folding: @Sendable (String, String) -> String
    private let folded = OSAllocatedUnfairLock(initialState: [String: String]())

    init(_ fold: @escaping @Sendable (String, String) -> String) {
        self.folding = fold
    }

    /// Folds every song's spellings into both memos at once, spread across
    /// the cores, so the first Home of a launch does not fold them one by one.
    static func warm(for tracks: [Track]) {
        let spellings = Array(Set(tracks.map { Spelling(title: $0.title, artist: $0.artist) }))
        for memo in [listenKeys, songKeys] {
            memo.foldAll(spellings)
        }
    }

    private struct Spelling: Hashable {
        let title: String
        let artist: String
    }

    private func foldAll(_ spellings: [Spelling]) {
        let fresh = folded.withLock { cache in spellings.filter { cache[$0.title + "\u{0}" + $0.artist] == nil } }
        guard !fresh.isEmpty else { return }
        let chunks = max(1, min(ProcessInfo.processInfo.activeProcessorCount, fresh.count / 256))
        let size = (fresh.count + chunks - 1) / chunks
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            let slice = fresh[min(chunk * size, fresh.count)..<min((chunk + 1) * size, fresh.count)]
            var keys: [String: String] = [:]
            keys.reserveCapacity(slice.count)
            for spelling in slice {
                keys[spelling.title + "\u{0}" + spelling.artist] = folding(spelling.title, spelling.artist)
            }
            let finished = keys
            folded.withLock { cache in
                if cache.count + finished.count > Self.capacity { cache.removeAll(keepingCapacity: true) }
                cache.merge(finished) { current, _ in current }
            }
        }
    }

    func key(title: String, artist: String) -> String {
        let spelling = title + "\u{0}" + artist
        if let known = folded.withLock({ $0[spelling] }) { return known }
        let key = folding(title, artist)
        folded.withLock { cache in
            if cache.count >= Self.capacity { cache.removeAll(keepingCapacity: true) }
            cache[spelling] = key
        }
        return key
    }
}
