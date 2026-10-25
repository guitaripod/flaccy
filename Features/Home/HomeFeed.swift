import Foundation
import MidgarCore
import FlaccyCore
import FlaccyEngine

/// Everything Home shows, gathered once off the main actor and rendered by
/// the iPhone's `HomeViewController` and the Mac's `MacHomeViewController`.
nonisolated struct HomeFeed: Sendable {

    nonisolated struct Resume: Sendable {
        let context: PlaybackContext
        let point: ResumePoint
        let currentTrack: Track
        let album: Album?
    }

    nonisolated struct UpNext: Sendable {
        let mix: SuggestedPlaylist
        let albums: [Album]
    }

    nonisolated struct DayOne: Sendable {
        let songs: Int
        let albums: Int
        let hiRes: Int
        let coverAlbums: [Album]
    }

    /// One thing to go back to: an album, a playlist, a mix or a radio,
    /// with up to four albums for its cover.
    nonisolated struct Item: Sendable, Hashable {
        let context: PlaybackContext
        let coverAlbums: [Album]
        let trackCount: Int

        static func == (lhs: Item, rhs: Item) -> Bool { lhs.context == rhs.context }
        func hash(into hasher: inout Hasher) { hasher.combine(context) }
    }

    nonisolated struct Memory: Sendable {
        let pick: OnThisDayPick
        let album: Album
    }

    let facts: HomeAvailability
    let hero: HomeHero
    let blocks: [HomeBlock]
    let resume: Resume?
    let upNext: UpNext?
    let dayOne: DayOne?
    let jumpBackIn: [Item]
    let mixes: [SuggestedPlaylist]
    let recentlyAdded: [Album]
    let onThisDay: Memory?
    let week: WeekGlance?
    var promo: HomePromo? = nil
    var proofLines: [PaywallProof.Line] = []

    static let empty = HomeFeed(
        facts: HomeAvailability(
            libraryTrackCount: 0, hasListeningHistory: false, isPlaying: false, canResume: false,
            jumpBackInCount: 0, recentlyAddedCount: 0, hasOnThisDay: false, hasWeekPlays: false
        ),
        hero: .empty, blocks: [], resume: nil, upNext: nil, dayOne: nil, jumpBackIn: [], mixes: [],
        recentlyAdded: [], onThisDay: nil, week: nil
    )

    /// This feed with the promo card and the proof lines behind it.
    func with(promo: HomePromo?, proofLines: [PaywallProof.Line]) -> HomeFeed {
        var copy = self
        copy.promo = promo
        copy.proofLines = proofLines
        return copy
    }
}

/// What Home needs from the entitlement and the library to decide its one
/// promo card, frozen on the main actor beside the rest of the inputs.
nonisolated struct HomePromoInputs: Sendable {
    let phase: HomePromo.Phase
    let entitlementsLoaded: Bool
    let welcomeBackOpen: Bool
    let playsAreScrobbled: Bool
    let ownTrackCount: Int

    @MainActor
    static func current(tracks: [Track], manager: PurchaseManager = .shared) -> HomePromoInputs {
        let sampleNames = SampleMusicService.sampleFileNames
        let own = tracks.lazy.filter { !SampleMusicService.isSample($0.fileURL, among: sampleNames) }.count
        var welcomeBackOpen = false
        if case .available = manager.lapsedOfferState, manager.lapsedLifetimeOffer != nil { welcomeBackOpen = true }
        return HomePromoInputs(
            phase: HomePromo.Phase(manager.state),
            entitlementsLoaded: manager.hasLoadedEntitlements,
            welcomeBackOpen: welcomeBackOpen,
            playsAreScrobbled: LastFMService.shared.isAuthenticated,
            ownTrackCount: own
        )
    }
}

/// What the main actor hands the builder: the library, the player and the
/// person's own Home state, frozen at one moment.
nonisolated struct HomeFeedInputs: Sendable {
    let albums: [Album]
    let tracks: [Track]
    let isPlaying: Bool
    let queue: [Track]
    let currentIndex: Int
    let context: PlaybackContext
    let resumePoint: ResumePoint?
    let recents: [RecentContexts.Entry]
    let dismissed: [String: Date]
    let layout: HomeLayout
    let promo: HomePromoInputs
    let now: Date
    let calendar: Calendar

    @MainActor
    static func current(player: AudioPlaying = AudioPlayer.shared, library: LibraryProviding = Library.shared) -> HomeFeedInputs {
        HomeFeedInputs(
            albums: library.albums,
            tracks: library.allTracks,
            isPlaying: player.isPlaying,
            queue: player.queue,
            currentIndex: player.currentIndex,
            context: player.playbackContext,
            resumePoint: player.resumePoint,
            recents: RecentContextStore.shared.recents.entries,
            dismissed: RecentContextStore.shared.recents.dismissed,
            layout: HomeLayoutStore.shared.layout,
            promo: HomePromoInputs.current(tracks: library.allTracks),
            now: Date(),
            calendar: .current
        )
    }
}

/// Builds a `HomeFeed`. Pure apart from the database reads, and cheap on a
/// large history: the scrobble table is read by date ranges, never whole,
/// except where the existing suggestions already read it.
nonisolated enum HomeFeedBuilder {

    nonisolated static func build(_ inputs: HomeFeedInputs, database: DatabaseManager = .shared) -> HomeFeed {
        let promo = promoCard(inputs.promo, database: database)
        guard !inputs.tracks.isEmpty else { return HomeFeed.empty.with(promo: promo.card, proofLines: promo.proof) }
        let index = AlbumIndex(albums: inputs.albums)
        let hasHistory = ((try? database.scrobbleCount(submittedOnly: false)) ?? 0) > 0

        let resume = resumeCard(inputs, index: index)
        let canResume = resume.map { $0.point.isResumable(now: inputs.now) } ?? false
        let mixes = hasHistory ? SuggestedPlaylistService.build(pool: HideDuplicateSongsSetting.uniquePool(inputs.tracks)) : []

        let playingKey = inputs.queue.isEmpty ? nil : inputs.context.key
        let historyEntries = historyAlbums(database: database, index: index)
        let items = jumpBackIn(inputs, history: historyEntries, excluding: Set([playingKey].compactMap { $0 }), index: index, mixes: mixes, database: database)

        let recentlyAdded = recentlyAddedAlbums(inputs, database: database)
        let memory = onThisDay(inputs, database: database, index: index)
        let week = weekGlance(inputs, database: database)

        let facts = HomeAvailability(
            libraryTrackCount: inputs.tracks.count,
            hasListeningHistory: hasHistory,
            isPlaying: inputs.isPlaying,
            canResume: canResume,
            jumpBackInCount: items.count,
            recentlyAddedCount: recentlyAdded.count,
            hasOnThisDay: memory != nil,
            hasWeekPlays: week.hasPlays
        )
        let hero = HomeComposer.hero(for: facts)
        let upNext = hero == .upNext ? upNextCard(mixes: mixes, index: index) : nil
        let dayOne = hero == .dayOne ? dayOneCard(inputs, recentlyAdded: recentlyAdded) : nil

        return HomeFeed(
            facts: facts,
            hero: hero,
            blocks: HomeComposer.blocks(layout: inputs.layout, facts: facts),
            resume: hero == .resume ? resume : nil,
            upNext: upNext,
            dayOne: dayOne,
            jumpBackIn: items,
            mixes: mixes,
            recentlyAdded: recentlyAdded,
            onThisDay: memory,
            week: week.hasPlays ? week : nil,
            promo: promo.card,
            proofLines: promo.proof
        )
    }

    /// The one card Home spends on getting music in or on Flaccy Pro, through
    /// the shared `HomePromo` rule. The paywall's proof is only read for the
    /// phases that can show it, so a paid or brand-new library costs nothing.
    nonisolated private static func promoCard(
        _ inputs: HomePromoInputs, database: DatabaseManager
    ) -> (card: HomePromo?, proof: [PaywallProof.Line]) {
        var proof: [PaywallProof.Line] = []
        if inputs.ownTrackCount > 0, inputs.phase.hasProof {
            let snapshot = PurchaseManager.proofSnapshot(playsAreScrobbled: inputs.playsAreScrobbled, database: database)
            if snapshot.hasLibrary { proof = snapshot.lines() }
        }
        let card = HomePromo.card(for: HomePromo.Facts(
            phase: inputs.phase,
            entitlementsLoaded: inputs.entitlementsLoaded,
            ownTrackCount: inputs.ownTrackCount,
            welcomeBackOpen: inputs.welcomeBackOpen,
            proofLineCount: proof.count
        ))
        return (card, proof)
    }

    /// Library albums looked up by Home's album key, with a fallback on the
    /// title alone when exactly one album carries it (a history row names the
    /// performing artist, a compilation is filed under its credit).
    nonisolated struct AlbumIndex: Sendable {
        let byKey: [String: Album]
        let byTitle: [String: [Album]]

        init(albums: [Album]) {
            var byKey: [String: Album] = [:]
            var byTitle: [String: [Album]] = [:]
            for album in albums {
                byKey[HomeKeys.album(title: album.title, credit: album.artist)] = album
                byTitle[HomeKeys.fold(album.title), default: []].append(album)
            }
            self.byKey = byKey
            self.byTitle = byTitle
        }

        func album(title: String, artist: String) -> Album? {
            if let exact = byKey[HomeKeys.album(title: title, credit: artist)] { return exact }
            let candidates = byTitle[HomeKeys.fold(title)] ?? []
            if candidates.count == 1 { return candidates[0] }
            let folded = HomeKeys.fold(artist)
            return candidates.first { album in album.tracks.contains { HomeKeys.fold($0.artist) == folded } }
        }

        func album(forKey key: String) -> Album? {
            byKey[key]
        }
    }

    nonisolated private static func resumeCard(_ inputs: HomeFeedInputs, index: AlbumIndex) -> HomeFeed.Resume? {
        guard let point = inputs.resumePoint, inputs.queue.indices.contains(inputs.currentIndex) else { return nil }
        let track = inputs.queue[inputs.currentIndex]
        return HomeFeed.Resume(
            context: inputs.context,
            point: point,
            currentTrack: track,
            album: index.album(title: track.albumTitle, artist: track.credit)
        )
    }

    nonisolated private static func historyAlbums(database: DatabaseManager, index: AlbumIndex) -> [RecentContexts.Entry] {
        let rows = (try? database.lastPlayedByAlbum()) ?? []
        return rows
            .filter { $0.lastPlayed >= HomePlay.earliestDated }
            .sorted { $0.lastPlayed > $1.lastPlayed }
            .prefix(60)
            .compactMap { row in
                guard let album = index.album(title: row.albumTitle, artist: row.artist) else { return nil }
                return RecentContexts.Entry(context: albumContext(album), playedAt: row.lastPlayed)
            }
    }

    nonisolated static func albumContext(_ album: Album) -> PlaybackContext {
        PlaybackContext(
            kind: .album,
            id: HomeKeys.album(title: album.title, credit: album.artist),
            title: album.title,
            subtitle: album.artist
        )
    }

    nonisolated private static func jumpBackIn(
        _ inputs: HomeFeedInputs,
        history: [RecentContexts.Entry],
        excluding: Set<String>,
        index: AlbumIndex,
        mixes: [SuggestedPlaylist],
        database: DatabaseManager
    ) -> [HomeFeed.Item] {
        let picked = JumpBackIn.pick(
            recents: inputs.recents, history: history, excluding: excluding, dismissed: inputs.dismissed, limit: 24
        )
        var items: [HomeFeed.Item] = []
        for context in picked where items.count < HomeComposer.jumpBackInLimit {
            if let item = item(for: context, index: index, mixes: mixes, inputs: inputs, database: database) {
                items.append(item)
            }
        }
        return items
    }

    /// Resolves a context to something playable now, or nil when it no longer
    /// exists (an album that was removed, a mix that did not qualify today).
    nonisolated static func item(
        for context: PlaybackContext,
        index: AlbumIndex,
        mixes: [SuggestedPlaylist],
        inputs: HomeFeedInputs,
        database: DatabaseManager
    ) -> HomeFeed.Item? {
        switch context.kind {
        case .album:
            guard let album = index.album(forKey: context.id) else { return nil }
            return HomeFeed.Item(context: context, coverAlbums: [album], trackCount: album.tracks.count)
        case .playlist:
            guard let id = Int64(context.id) else { return nil }
            let tracks = playlistTracks(id: id, library: inputs.tracks, database: database)
            guard !tracks.isEmpty else { return nil }
            return HomeFeed.Item(context: context, coverAlbums: coverAlbums(tracks, index: index), trackCount: tracks.count)
        case .mix:
            guard let mix = mixes.first(where: { $0.id == context.id }) else { return nil }
            let refreshed = PlaybackContext(kind: .mix, id: mix.id, title: mix.title, subtitle: mix.subtitle)
            return HomeFeed.Item(context: refreshed, coverAlbums: coverAlbums(mix.tracks, index: index), trackCount: mix.tracks.count)
        case .radio:
            let seeds = radioSeedAlbums(context, inputs: inputs, index: index)
            return HomeFeed.Item(context: context, coverAlbums: seeds, trackCount: 0)
        case .queue:
            return nil
        }
    }

    nonisolated static func playlistTracks(id: Int64, library: [Track], database: DatabaseManager) -> [Track] {
        let records = (try? database.fetchPlaylistTracks(playlistId: id)) ?? []
        guard !records.isEmpty else { return [] }
        let byPath = Dictionary(library.map { ($0.fileURL.standardizedFileURL.path, $0) }, uniquingKeysWith: { first, _ in first })
        let root = LibraryPaths.root
        return records.compactMap { byPath[root.appendingPathComponent($0.trackFileURL).standardizedFileURL.path] }
    }

    /// The first four distinct albums of `tracks`, in order, for a mosaic.
    nonisolated static func coverAlbums(_ tracks: [Track], index: AlbumIndex) -> [Album] {
        var seen = Set<String>()
        var albums: [Album] = []
        for track in tracks where albums.count < 4 {
            guard let album = index.album(title: track.albumTitle, artist: track.credit),
                  seen.insert(album.id).inserted else { continue }
            albums.append(album)
        }
        return albums
    }

    nonisolated private static func radioSeedAlbums(_ context: PlaybackContext, inputs: HomeFeedInputs, index: AlbumIndex) -> [Album] {
        if context.id.hasPrefix("artist:") {
            let artist = String(context.id.dropFirst("artist:".count))
            let tracks = inputs.tracks.filter { HomeKeys.fold($0.artist) == artist || HomeKeys.fold($0.credit) == artist }
            return coverAlbums(tracks, index: index)
        }
        return Array(inputs.albums.prefix(4))
    }

    nonisolated private static func upNextCard(mixes: [SuggestedPlaylist], index: AlbumIndex) -> HomeFeed.UpNext? {
        guard let id = HomeComposer.heroMix(among: mixes.map(\.id)),
              let mix = mixes.first(where: { $0.id == id }) else { return nil }
        return HomeFeed.UpNext(mix: mix, albums: coverAlbums(mix.tracks, index: index))
    }

    nonisolated private static func dayOneCard(_ inputs: HomeFeedInputs, recentlyAdded: [Album]) -> HomeFeed.DayOne {
        let hiRes = inputs.albums.filter { album in
            album.tracks.contains { $0.isLossless && (($0.bitDepth ?? 0) > 16 || ($0.sampleRate ?? 0) > 48_000) }
        }.count
        return HomeFeed.DayOne(
            songs: inputs.tracks.count,
            albums: inputs.albums.count,
            hiRes: hiRes,
            coverAlbums: Array(recentlyAdded.prefix(4))
        )
    }

    /// Newest first by the newest track each album holds, through the same
    /// rule the Recently Added chip uses, capped for Home.
    nonisolated private static func recentlyAddedAlbums(_ inputs: HomeFeedInputs, database: DatabaseManager) -> [Album] {
        let added = Dictionary(
            ((try? database.fetchTrackDateAddedByPath()) ?? []).map { ($0.path, $0.dateAdded) },
            uniquingKeysWith: { first, _ in first }
        )
        let root = LibraryPaths.root.standardizedFileURL.path
        let entries: [(id: String, dateAdded: Date)] = inputs.albums.map { album in
            let newest = album.tracks.compactMap { track -> Date? in
                let path = track.fileURL.standardizedFileURL.path
                let relative = path.hasPrefix(root) ? String(path.dropFirst(root.count + 1)) : path
                return added[relative]
            }.max() ?? .distantPast
            return (id: album.id, dateAdded: newest)
        }
        let ids = LibraryFilterRules.recentlyAdded(entries, now: inputs.now, thresholds: .albums)
        let byID = Dictionary(inputs.albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.prefix(HomeComposer.recentlyAddedLimit).compactMap { byID[$0] }
    }

    nonisolated private static func onThisDay(_ inputs: HomeFeedInputs, database: DatabaseManager, index: AlbumIndex) -> HomeFeed.Memory? {
        let calendar = inputs.calendar
        var rows: [ScrobbleRecord] = []
        let today = calendar.dateComponents([.year, .month, .day], from: inputs.now)
        guard let thisYear = today.year else { return nil }
        let firstYear = calendar.component(.year, from: HomePlay.earliestDated)
        if firstYear < thisYear {
            for year in firstYear..<thisYear {
                var parts = today
                parts.year = year
                guard let start = calendar.date(from: parts),
                      calendar.component(.day, from: start) == today.day,
                      let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
                rows += (try? database.fetchScrobbleRows(from: start, to: end)) ?? []
            }
        }
        if let yearAgo = calendar.date(byAdding: .year, value: -1, to: inputs.now) {
            let anchor = calendar.startOfDay(for: yearAgo)
            if let start = calendar.date(byAdding: .day, value: -OnThisDay.weekSpanDays, to: anchor),
               let end = calendar.date(byAdding: .day, value: OnThisDay.weekSpanDays + 1, to: anchor) {
                rows += (try? database.fetchScrobbleRows(from: start, to: end)) ?? []
            }
        }
        var seen = Set<Int64>()
        let plays = rows.compactMap { row -> HomePlay? in
            if let id = row.id, !seen.insert(id).inserted { return nil }
            return HomePlay(album: row.albumTitle, artist: row.artist, at: row.timestamp, seconds: row.duration)
        }
        guard let pick = OnThisDay.pick(plays, now: inputs.now, calendar: calendar),
              let album = index.album(title: pick.album, artist: pick.artist) else { return nil }
        return HomeFeed.Memory(pick: pick, album: album)
    }

    nonisolated private static func weekGlance(_ inputs: HomeFeedInputs, database: DatabaseManager) -> WeekGlance {
        let start = inputs.now.addingTimeInterval(-2 * WeekGlance.window)
        let rows = (try? database.fetchScrobbleRows(from: start, to: inputs.now.addingTimeInterval(1))) ?? []
        let plays = rows.map { HomePlay(album: $0.albumTitle, artist: $0.artist, at: $0.timestamp, seconds: $0.duration) }
        return WeekGlance.compute(plays, now: inputs.now, calendar: inputs.calendar)
    }
}
