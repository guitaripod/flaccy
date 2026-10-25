import Foundation

/// Last.fm history as Flaccy's own listening history: the keys a play is
/// counted under, how a pulled scrobble is told apart from one already stored,
/// and which pull the history sync makes next. Mirrored in Rust as
/// `linux/library/src/listen_history.rs`; the test vectors are asserted on
/// both sides.
public enum ListenHistory {

    /// Words whose bracketed or dashed segment says nothing about which
    /// recording played: a featured credit or a remaster. "Song (feat. X)",
    /// "Song - 2011 Remaster" and "Song" are one song; "Song (Live)" and
    /// "Song (Acoustic Version)" are not.
    public static let titleKeywords: Set<String> = [
        "feat", "ft.", "featuring", "with", "remaster", "remastered", "explicit",
    ]

    private static let titleFeatureClauses = [" feat. ", " feat ", " ft. ", " featuring "]

    /// How far back Last.fm accepts a scrobble, so how far back a late-arriving
    /// one from another device can land.
    public static let lateScrobbleWindow = 14 * 86_400

    /// How often the sync re-reads that whole window for late arrivals.
    public static let settleInterval = 86_400

    /// How far before the newest pulled scrobble a catch-up starts, so a
    /// scrobble stamped a little before it but submitted after the last pull is
    /// not missed.
    public static let catchUpOverlap = 3_600

    /// The shortest gap between two automatic syncs (focus, launch, timer).
    public static let automaticSyncSpacing = 120

    /// How often a running client syncs on its own.
    public static let periodicSync = 600

    /// The title a play is counted under: case, diacritics and punctuation
    /// folded, featured credits and remaster tags dropped.
    public static func titleKey(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let cut = titleFeatureClauses
            .compactMap { lowered.range(of: $0)?.lowerBound }
            .min() ?? lowered.endIndex
        let key = LibraryHygiene.baseTitle(String(lowered[..<cut]), keywords: titleKeywords)
        return key.isEmpty ? LibraryHygiene.normalize(raw) : key
    }

    /// The artist a play is counted under: the lead of the credit, folded the
    /// way the library groups its Artists.
    public static func artistKey(_ raw: String) -> String {
        LibraryHygiene.artistKey(raw)
    }

    /// The release a play is counted under, without its artist: the
    /// edition-free base title, so "Abbey Road (2019 Remaster)" counts toward
    /// "Abbey Road".
    public static func albumKey(_ raw: String) -> String {
        LibraryHygiene.consolidationBaseTitle(raw)
    }

    /// `title ␀ artist`: the key a song's plays are counted under, used alike
    /// for a scrobble and for a library track.
    public static func trackKey(title: String, artist: String) -> String {
        titleKey(title) + "\u{0}" + artistKey(artist)
    }

    /// The keys one play is stored with.
    public struct Keys: Hashable, Sendable {
        public let title: String
        public let artist: String
        public let album: String

        public init(title: String, artist: String, album: String) {
            self.title = ListenHistory.titleKey(title)
            self.artist = ListenHistory.artistKey(artist)
            self.album = ListenHistory.albumKey(album)
        }
    }

    /// One stored play, as dedup needs it. `playedHere` is a play Flaccy
    /// recorded itself (it knows how long the song is) rather than one pulled
    /// from Last.fm.
    public struct StoredListen: Sendable {
        public let timestamp: Int
        public let titleKey: String
        public let artistKey: String
        public let playedHere: Bool

        public init(timestamp: Int, titleKey: String, artistKey: String, playedHere: Bool) {
            self.timestamp = timestamp
            self.titleKey = titleKey
            self.artistKey = artistKey
            self.playedHere = playedHere
        }
    }

    /// What is already stored, asked whether a pulled scrobble is new.
    public struct Ledger: Sendable {
        private struct Stamp: Hashable, Sendable {
            let timestamp: Int
            let key: String
        }

        private var titles = Set<Stamp>()
        private var playedHere = Set<Stamp>()

        public init<S: Sequence>(_ stored: S) where S.Element == StoredListen {
            for listen in stored {
                if listen.playedHere {
                    playedHere.insert(Stamp(timestamp: listen.timestamp, key: listen.artistKey))
                }
                titles.insert(Stamp(timestamp: listen.timestamp, key: listen.titleKey))
            }
        }

        /// Whether a scrobble pulled from Last.fm is a play that is not stored
        /// yet, and records it when it is. The same second and title is the
        /// same play. So is the same second and artist as a play Flaccy
        /// recorded itself, which Last.fm may hand back under a corrected
        /// title; plays pulled from Last.fm can share a second with each other
        /// (bulk-imported histories do), so that rule never folds two of them
        /// together.
        public mutating func admit(timestamp: Int, keys: Keys) -> Bool {
            if playedHere.contains(Stamp(timestamp: timestamp, key: keys.artist)) {
                return false
            }
            return titles.insert(Stamp(timestamp: timestamp, key: keys.title)).inserted
        }
    }

    /// One counted spelling of a key.
    public struct Spelling<Key: Hashable>: Sendable where Key: Sendable {
        public let key: Key
        public let name: String
        public let plays: Int
        public let seconds: Int

        public init(key: Key, name: String, plays: Int, seconds: Int) {
            self.key = key
            self.name = name
            self.plays = plays
            self.seconds = seconds
        }
    }

    /// Counts gathered per spelling folded into one entry per key, named by
    /// the spelling heard most (ties go to the alphabetically first), ordered
    /// by plays descending then name.
    public static func foldSpellings<Key: Hashable>(
        _ rows: [Spelling<Key>]
    ) -> [(name: String, plays: Int, seconds: Int)] {
        var groups: [Key: SpellingGroup] = [:]
        for row in rows {
            var group = groups[row.key] ?? SpellingGroup(name: row.name, namePlays: 0, plays: 0, seconds: 0)
            group.plays += row.plays
            group.seconds += row.seconds
            if row.plays > group.namePlays || (row.plays == group.namePlays && row.name < group.name) {
                group.name = row.name
                group.namePlays = row.plays
            }
            groups[row.key] = group
        }
        return groups.values
            .map { (name: $0.name, plays: $0.plays, seconds: $0.seconds) }
            .sorted { $0.plays != $1.plays ? $0.plays > $1.plays : $0.name < $1.name }
    }

    private struct SpellingGroup {
        var name: String
        var namePlays: Int
        var plays: Int
        var seconds: Int
    }

    /// The next pull from Last.fm.
    public enum Step: Equatable, Sendable {
        /// One page of the first full pull, newest first, of scrobbles up to `to`.
        case backfill(page: Int, to: Int)
        /// Every scrobble from `from` on, the regular pull.
        case catchUp(from: Int)
        /// Every scrobble of the window Last.fm still accepts late ones into.
        case settle(from: Int)
    }

    /// Where the history sync stands for one Last.fm account. Persisted by
    /// each client.
    public struct SyncState: Codable, Equatable, Sendable {
        public var account: String = ""
        public var backfillComplete = false
        /// The instant the first full pull reads back from, fixed when it
        /// starts so its pages do not shift as new scrobbles arrive.
        public var backfillAnchor: Int?
        /// The next page of the first full pull.
        public var backfillPage = 1
        /// The newest scrobble time pulled so far.
        public var newestRemote: Int?
        public var lastSyncAt: Int?
        public var lastSettleAt: Int?

        public init() {}

        /// A fresh state for `account`, or this one when it is the same account.
        public func forAccount(_ account: String) -> SyncState {
            guard self.account != account else { return self }
            var fresh = SyncState()
            fresh.account = account
            return fresh
        }

        /// The state a client that imported history before the sync existed
        /// starts from. `legacyComplete` is its record of a finished import,
        /// `legacyPage` the page an unfinished one stopped at (pages have
        /// shifted since, so it resumes one page early), and `newestImported`
        /// the newest scrobble that import stored.
        public static func adopting(
            account: String, legacyComplete: Bool, legacyPage: Int, newestImported: Int?, now: Int
        ) -> SyncState {
            var state = SyncState().forAccount(account)
            if legacyComplete && legacyPage <= 1 {
                state.backfillComplete = true
                state.newestRemote = newestImported
            } else if legacyPage > 1 {
                state.backfillAnchor = now
                state.backfillPage = legacyPage - 1
            }
            return state
        }

        /// The pull to make now.
        public func nextStep(now: Int) -> Step {
            guard backfillComplete else {
                return .backfill(page: max(backfillPage, 1), to: backfillAnchor ?? now)
            }
            let settleDue = lastSettleAt.map { now - $0 >= ListenHistory.settleInterval } ?? true
            let windowStart = now - ListenHistory.lateScrobbleWindow
            if let newest = newestRemote {
                let from = max(newest - ListenHistory.catchUpOverlap, 0)
                if !settleDue || from < windowStart {
                    return .catchUp(from: from)
                }
            }
            return .settle(from: windowStart)
        }

        /// Whether an automatic trigger should sync now.
        public func automaticSyncDue(now: Int) -> Bool {
            guard let lastSyncAt else { return true }
            return now - lastSyncAt >= ListenHistory.automaticSyncSpacing || now < lastSyncAt
        }

        /// Records a finished page of the first full pull.
        public mutating func recordBackfillPage(page: Int, totalPages: Int, anchor: Int, newest: Int?, now: Int) {
            backfillAnchor = anchor
            noteNewest(newest)
            if page >= max(totalPages, 1) {
                backfillComplete = true
                backfillAnchor = nil
                backfillPage = 1
                newestRemote = max(newestRemote ?? anchor, min(anchor, now))
                lastSyncAt = now
            } else {
                backfillPage = page + 1
            }
        }

        /// Records a finished catch-up or settle pull.
        public mutating func recordPull(_ step: Step, newest: Int?, now: Int) {
            noteNewest(newest)
            if newestRemote == nil {
                newestRemote = now
            }
            lastSyncAt = now
            switch step {
            case .settle:
                lastSettleAt = now
            case .catchUp(let from) where from < now - ListenHistory.lateScrobbleWindow:
                lastSettleAt = now
            default:
                break
            }
        }

        private mutating func noteNewest(_ newest: Int?) {
            guard let newest else { return }
            newestRemote = max(newestRemote ?? newest, newest)
        }
    }
}
