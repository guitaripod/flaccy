import MidgarCore
#if DEBUG && os(iOS) && targetEnvironment(simulator)
import FlaccyCore
import UIKit

/// Everything the screenshot demo adds on top of `ScreenshotSeeder`'s fictional
/// library, so that every screen the app has is full, different from its
/// neighbours and identical on every launch: playlists, a persisted queue,
/// lyrics, a wantlist with its own art, settled and given-up metadata work.
/// Reachable only on the Simulator in DEBUG builds, and only with
/// `--seed-screenshots`; `DemoRouter` turns `FLACCY_ROUTE` into one screen.
enum DemoMode {

    static let version = 11
    private static let versionKey = "flaccy.demo.version"

    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    private static let historyModeKey = "flaccy.demo.historyMode"

    static var isDayOne: Bool { environment["FLACCY_ROUTE"] == "home-dayone" }
    static var isEmptyLibrary: Bool { environment["FLACCY_ROUTE"] == "home-empty" }
    static var isHomeRoute: Bool { environment["FLACCY_ROUTE"]?.hasPrefix("home") == true }

    /// The empty-history Home needs a library nobody has played, the first-run
    /// Home needs no library at all, and every other route needs the played
    /// one, so switching between them reseeds.
    private static func switchedHistoryMode() -> Bool {
        let mode = isEmptyLibrary ? "empty" : (isDayOne ? "dayOne" : "played")
        let previous = UserDefaults.standard.string(forKey: historyModeKey)
        UserDefaults.standard.set(mode, forKey: historyModeKey)
        return previous != mode
    }

    static func eraseIfStale(_ db: DatabaseManager) {
        let switched = switchedHistoryMode()
        guard UserDefaults.standard.integer(forKey: versionKey) != version || switched else { return }
        do {
            try db.eraseDemoContent()
            eraseDemoFiles()
            MidgarLog.info("Demo: stale content erased for version \(version)", category: .database)
        } catch {
            MidgarLog.error("Demo: erase failed: \(error.localizedDescription)", category: .database)
        }
    }

    private static let genreTags: [String: [String]] = [
        "Progressive": ["progressive", "art rock", "cinematic", "night drive", "atmospheric"],
        "Ambient": ["ambient", "drone", "field recording", "slow", "winter"],
        "Indie": ["indie", "lo-fi", "bedroom pop", "jangle", "city pop"],
        "Post-Rock": ["post-rock", "instrumental", "crescendo", "wide open", "melancholic"],
        "Soul": ["soul", "neo soul", "warm", "late night", "vocal"],
        "Electronic": ["electronic", "downtempo", "synth", "glitch", "night"],
        "Folk": ["folk", "acoustic", "storytelling", "autumn", "hushed"],
        "Dream Pop": ["dream pop", "shoegaze", "hazy", "ethereal", "reverb"],
        "Jazz": ["jazz", "modal", "trio", "after hours", "improvised"],
        "Nordic": ["nordic", "folk electronica", "cold", "spacious", "northern lights"],
        "Classical": ["classical", "chamber", "contemporary", "études", "strings"],
    ]

    /// Fills the in-memory and disk caches that would otherwise be answered by
    /// the network: artist portraits (the seeded cover art of their first
    /// album), genre tags, popular songs and similar artists. Run on every
    /// launch because the detail cache lives in memory.
    static func primeCaches() {
        for artist in Set(ScreenshotSeeder.catalog.map(\.artist)) {
            guard let album = ScreenshotSeeder.catalog.first(where: { $0.artist == artist }) else { continue }
            storePortrait(artist: artist, from: album)
        }
        for spec in wantedSpecs where spec.kind == .artist {
            storePortrait(artist: spec.artist, from: portraitSource(for: spec.artist))
        }
        Task {
            for _ in 0..<80 {
                if Library.shared.albums.count >= ScreenshotSeeder.catalog.count { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            await seedDetailCache()
        }
    }

    private static func portraitSource(for artist: String) -> ScreenshotSeeder.DemoAlbum {
        let hash = artist.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }
        let base = UIColor(hue: CGFloat(hash) / 360, saturation: 0.55, brightness: 0.34, alpha: 1)
        let dark = UIColor(hue: CGFloat(hash) / 360, saturation: 0.6, brightness: 0.1, alpha: 1)
        let accent = UIColor(hue: CGFloat(hash) / 360, saturation: 0.35, brightness: 0.95, alpha: 1)
        return ScreenshotSeeder.DemoAlbum(
            artist: artist, title: artist, year: "", genre: "", bitDepth: 16, sampleRate: 44100,
            top: base.cgColor, bottom: dark.cgColor, accent: accent.cgColor, motif: hash % 10, tracks: []
        )
    }

    private static func storePortrait(artist: String, from album: ScreenshotSeeder.DemoAlbum) {
        guard let data = CoverArtRenderer.render(album) else { return }
        ImageCache.shared.store(data: data, forKey: "artist-photo|\(artist.lowercased())")
    }

    private static func seedDetailCache() async {
        var tags: [String: [String]] = [:]
        var popular: [String: [(name: String, playCount: Int, rank: Int)]] = [:]
        var similar: [String: [Album]] = [:]
        let artists = Array(Set(ScreenshotSeeder.catalog.map(\.artist))).sorted()
        let albums = Library.shared.albums
        for artist in artists {
            let owned = ScreenshotSeeder.catalog.filter { $0.artist == artist }
            tags[artist.lowercased()] = genreTags[owned.first?.genre ?? ""] ?? ["electronic"]
            let ranked = owned.flatMap { album in album.tracks.map { (album, $0) } }
                .sorted { ScreenshotSeeder.playCount(album: $0.0, track: $0.1) > ScreenshotSeeder.playCount(album: $1.0, track: $1.1) }
            popular[artist.lowercased()] = ranked.prefix(5).enumerated().map {
                (name: $0.element.1.title, playCount: ScreenshotSeeder.playCount(album: $0.element.0, track: $0.element.1) * 37, rank: $0.offset + 1)
            }
            let genre = owned.first?.genre
            similar[artist.lowercased()] = albums
                .filter { $0.artist != artist && $0.genre == genre }
                .sorted { $0.title < $1.title }
                .prefix(4).map { $0 }
        }
        await DetailEnrichmentCache.shared.seedDemo(tags: tags, popular: popular, similar: similar)
    }

    /// Removes the audio files an earlier demo version wrote, so a renamed or
    /// dropped album cannot come back from disk as a stray artist.
    private static func eraseDemoFiles() {
        let fileManager = FileManager.default
        let root = LibraryPaths.root
        for item in (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            try? fileManager.removeItem(at: item)
        }
    }

    static func seedSupplements(db: DatabaseManager) {
        seedPlaylists(db: db)
        seedLyrics(db: db)
        seedWantlist(db: db)
        seedEnrichment(db: db)
        seedHomeHistory(db: db)
        UserDefaults.standard.set(version, forKey: versionKey)
        MidgarLog.info("Demo: supplements seeded (version \(version))", category: .content)
    }

    private static func path(_ albumTitle: String, _ number: Int) -> String? {
        guard let album = ScreenshotSeeder.catalog.first(where: { $0.title == albumTitle }),
              let track = album.tracks.first(where: { $0.number == number })
        else { return nil }
        return ScreenshotSeeder.relativePath(album: album, track: track)
    }

    private static let homeQueueAlbum = "Parallax Hours"
    private static let homeQueueIndex = 4
    private static let homeQueueElapsed = 130.0

    /// Yesterday at 10:30 pm, so the Continue card reads "last night".
    private static func lastNight(now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        return calendar.date(bySettingHour: 22, minute: 30, second: 0, of: yesterday) ?? yesterday
    }

    /// An album queue paused at track 5 of 9 with about 18 minutes left,
    /// saved last night, which is what Home restores into its Continue card.
    private static func applyHomeQueue() {
        let defaults = UserDefaults.standard
        guard let album = ScreenshotSeeder.catalog.first(where: { $0.title == homeQueueAlbum }) else { return }
        let paths = album.tracks.map { ScreenshotSeeder.relativePath(album: album, track: $0) }
        defaults.set(paths, forKey: "flaccy.queue.paths")
        defaults.set(homeQueueIndex, forKey: "flaccy.queue.index")
        defaults.set(paths[homeQueueIndex], forKey: "flaccy.queue.currentPath")
        defaults.set(homeQueueElapsed, forKey: "flaccy.queue.elapsed")
        defaults.set(false, forKey: "flaccy.queue.shuffle")
        defaults.set(0, forKey: "flaccy.queue.repeat")
        defaults.removeObject(forKey: "flaccy.queue.originalPaths")
        let context = PlaybackContext(
            kind: .album,
            id: HomeKeys.album(title: album.title, credit: album.artist),
            title: album.title,
            subtitle: album.artist
        )
        if let data = try? JSONEncoder().encode(context) { defaults.set(data, forKey: "flaccy.queue.context") }
        defaults.set(lastNight().timeIntervalSince1970, forKey: "flaccy.queue.savedAt")
    }

    private static func clearHomeQueue() {
        for key in ["paths", "index", "currentPath", "elapsed", "shuffle", "repeat", "originalPaths", "context", "savedAt"] {
            UserDefaults.standard.removeObject(forKey: "flaccy.queue.\(key)")
        }
    }

    /// Albums, a playlist, a mix and a radio the person "started" recently,
    /// written where `RecentContextStore` reads them.
    private static func seedRecentContexts(db: DatabaseManager) {
        let now = Date()
        func album(_ title: String) -> PlaybackContext? {
            guard let found = ScreenshotSeeder.catalog.first(where: { $0.title == title }) else { return nil }
            return PlaybackContext(
                kind: .album, id: HomeKeys.album(title: found.title, credit: found.artist),
                title: found.title, subtitle: found.artist
            )
        }
        var contexts: [PlaybackContext] = []
        if let context = album("Cassini") { contexts.append(context) }
        if let playlist = ((try? db.fetchAllPlaylists()) ?? []).first(where: { $0.name == "Night Drive" }), let id = playlist.id {
            contexts.append(PlaybackContext(kind: .playlist, id: String(id), title: playlist.name, subtitle: ""))
        }
        contexts.append(PlaybackContext(kind: .mix, id: "heavy-rotation", title: "Heavy Rotation", subtitle: ""))
        for title in ["Aurorae", "Midnatt", "Tidal Glass", "Velvet Arithmetic"] {
            if let context = album(title) { contexts.append(context) }
        }
        contexts.append(AudioPlayer.libraryRadioContext)
        let entries = contexts.enumerated().map { offset, context in
            RecentContexts.Entry(context: context, playedAt: now.addingTimeInterval(-Double(offset + 1) * 5400))
        }
        if let data = try? JSONEncoder().encode(RecentContexts(entries: entries)) {
            UserDefaults.standard.set(data, forKey: "flaccy.home.recentContexts")
        }
    }

    private static let currentWeekPlays = [3, 5, 2, 6, 4, 7, 5]
    private static let previousWeekPlays = [2, 3, 4, 1, 3, 2, 3]

    /// Plays on today's month and day a year ago (the On This Day card) and a
    /// busy-then-busier fortnight (the This Week card).
    private static func seedHomeHistory(db: DatabaseManager) {
        guard !isDayOne else {
            UserDefaults.standard.removeObject(forKey: "flaccy.home.recentContexts")
            return
        }
        seedRecentContexts(db: db)
        let calendar = Calendar.current
        let now = Date()
        var records: [ScrobbleRecord] = []

        func scrobble(_ album: ScreenshotSeeder.DemoAlbum, _ track: ScreenshotSeeder.DemoTrack, at date: Date) {
            records.append(ScrobbleRecord(
                trackTitle: track.title, artist: album.artist, albumTitle: album.title,
                timestamp: date, duration: Int(track.duration), submitted: true
            ))
        }

        if let memory = ScreenshotSeeder.catalog.first(where: { $0.title == "Aurorae" }),
           let yearAgo = calendar.date(byAdding: .year, value: -1, to: now) {
            for (offset, track) in (memory.tracks + memory.tracks.prefix(2)).enumerated() {
                let evening = calendar.date(bySettingHour: 19, minute: 5 + offset * 6, second: 0, of: yearAgo) ?? yearAgo
                scrobble(memory, track, at: evening)
            }
        }

        let albums = ScreenshotSeeder.catalog
        var cursor = 0
        func spread(_ counts: [Int], startingDaysAgo: Int) {
            for (index, count) in counts.enumerated() {
                let daysAgo = startingDaysAgo - index
                guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: now) else { continue }
                for play in 0..<count {
                    let album = albums[cursor % albums.count]
                    let track = album.tracks[(cursor / albums.count + play) % album.tracks.count]
                    cursor += 1
                    let hour = 8 + (play * 3 + index) % 12
                    let stamp = calendar.date(bySettingHour: hour, minute: (play * 11) % 60, second: 0, of: day) ?? day
                    if stamp < now { scrobble(album, track, at: stamp) }
                }
            }
        }
        spread(previousWeekPlays, startingDaysAgo: 13)
        spread(currentWeekPlays, startingDaysAgo: 6)
        try? db.insertScrobbles(records)
    }

    private static let queueSpec: [(String, Int)] = [
        ("Parallax Hours", 1), ("Aurorae", 1), ("Parallax Hours", 2), ("Parallax Hours", 3),
        ("Cassini", 2), ("Midnatt", 1), ("Tidal Glass", 1), ("Field Lines", 1), ("Ravine", 2),
        ("Southern Cross", 1), ("Ember & Ash", 1), ("Almagest", 1), ("Nightglow", 2), ("Statuary", 2),
    ]

    /// Persists the queue the player restores on launch, every launch, so Now
    /// Playing, Queue and Lyrics always open on the same paused moment unless
    /// `FLACCY_QUEUE_INDEX` / `FLACCY_ELAPSED` move it.
    static func applyPlaybackState() {
        if isDayOne || isEmptyLibrary {
            clearHomeQueue()
            return
        }
        if isHomeRoute {
            applyHomeQueue()
            return
        }
        for key in ["context", "savedAt"] {
            UserDefaults.standard.removeObject(forKey: "flaccy.queue.\(key)")
        }
        if environment["FLACCY_NO_QUEUE"] == "1" {
            for key in ["paths", "index", "currentPath", "elapsed", "shuffle", "repeat", "originalPaths"] {
                UserDefaults.standard.removeObject(forKey: "flaccy.queue.\(key)")
            }
            return
        }
        let paths = queueSpec.compactMap { path($0.0, $0.1) }
        let index = Int(environment["FLACCY_QUEUE_INDEX"] ?? "") ?? 2
        let elapsed = Double(environment["FLACCY_ELAPSED"] ?? "") ?? 47
        let defaults = UserDefaults.standard
        defaults.set(paths, forKey: "flaccy.queue.paths")
        defaults.set(index, forKey: "flaccy.queue.index")
        defaults.set(paths.indices.contains(index) ? paths[index] : paths.first, forKey: "flaccy.queue.currentPath")
        defaults.set(elapsed, forKey: "flaccy.queue.elapsed")
        defaults.set(false, forKey: "flaccy.queue.shuffle")
        defaults.set(0, forKey: "flaccy.queue.repeat")
        defaults.removeObject(forKey: "flaccy.queue.originalPaths")
    }

    private static let playlistSpec: [(String, [(String, Int)])] = [
        ("Night Drive", [("Parallax Hours", 2), ("Cassini", 2), ("Signal Bloom", 2), ("Nightglow", 2), ("Midnatt", 1),
                         ("Almagest", 1), ("Vantablack Sun", 1), ("Radio Silence", 1), ("Field Lines", 1)]),
        ("Rain on the Roof", [("Aurorae", 1), ("Tidal Glass", 1), ("Overwinter", 1), ("Longshore Drift", 1),
                              ("Aurorae", 3), ("Tidal Glass", 3), ("Overwinter", 3)]),
        ("Deep Focus", [("Almagest", 2), ("Signal Bloom", 1), ("Statuary", 1), ("Ravine", 1), ("Vantablack Sun", 2),
                        ("Field Lines", 4), ("Almagest", 4), ("Ledger of Small Hours", 1)]),
        ("Sunday Slow", [("Ember & Ash", 1), ("Velvet Arithmetic", 1), ("Saltwater Gospel", 1), ("Lantern Year", 2),
                         ("Southern Cross", 1), ("Tradewinds", 1), ("Ember & Ash", 5), ("Velvet Arithmetic", 5),
                         ("Greenhouse Hymns", 1), ("Saltwater Gospel", 3), ("Tradewinds", 3)]),
    ]

    private static func seedPlaylists(db: DatabaseManager) {
        for (name, tracks) in playlistSpec {
            guard let playlist = try? db.createPlaylist(name: name), let id = playlist.id else { continue }
            for (album, number) in tracks {
                guard let relative = path(album, number) else { continue }
                try? db.addTrackToPlaylist(playlistId: id, trackFileURL: relative)
            }
        }
    }

    private static func seedLyrics(db: DatabaseManager) {
        let lyrics: [(String, String, String)] = [
            ("Glass Horizon", "Kestrel Vale", """
            [00:09.00]The morning is a pane of glass
            [00:14.20]We stand behind it, breathing slow
            [00:19.80]Everything the light forgot
            [00:25.10]Comes back as colour, soft and low
            [00:32.00]Hold the horizon like a sleeping bird
            [00:37.40]Do not startle it with words
            [00:43.00]Cold blue edge of a coming day
            [00:48.60]Let it open, let it stay
            """),
            ("Saturn Blue", "Virelle", """
            [00:12.00]Rings of ice and radio static
            [00:17.50]Sing me back to where we met
            [00:23.00]Every orbit is a letter
            [00:28.40]That the dark has not sent yet
            [00:35.00]Saturn blue, Saturn blue
            [00:40.50]I was never far from you
            [00:46.00]Spinning slow and spinning wide
            [00:51.50]With the whole sky on our side
            """),
        ]
        for (title, artist, synced) in lyrics {
            try? db.saveLyrics(LyricsRecord(
                trackTitle: title, artist: artist, syncedLyrics: synced, plainLyrics: nil,
                instrumental: false, fetchedAt: Date(), revision: LyricsResolution.revision
            ))
        }
    }

    private struct WantedSpec {
        let kind: WantlistKind
        let source: WantlistSource
        let title: String
        let artist: String
        let reason: String
        let plays: Int
        let motif: Int
        let top: UInt32
        let bottom: UInt32
        let accent: UInt32
    }

    private static let wantedSpecs: [WantedSpec] = [
        WantedSpec(kind: .album, source: .history, title: "Lowlight Atlas", artist: "Meridian Wolde",
                   reason: "64 plays on Last.fm", plays: 64, motif: 4, top: 0x2B1A46, bottom: 0x0C0714, accent: 0xFF6B9D),
        WantedSpec(kind: .album, source: .history, title: "Harbour Arithmetic", artist: "Kestrel Vale",
                   reason: "41 plays on Last.fm · you own 2 of its tracks", plays: 41, motif: 8, top: 0x0E3B4A, bottom: 0x061318, accent: 0x6FE3C8),
        WantedSpec(kind: .album, source: .history, title: "Brass Weather", artist: "Monsoon Atlas",
                   reason: "37 plays on Last.fm", plays: 37, motif: 1, top: 0x123A2E, bottom: 0x05120D, accent: 0x8FE6C0),
        WantedSpec(kind: .album, source: .history, title: "Ninth Lantern", artist: "Ashgrove",
                   reason: "29 plays on Last.fm", plays: 29, motif: 7, top: 0x3A2E14, bottom: 0x110D06, accent: 0xE6C36F),
        WantedSpec(kind: .album, source: .history, title: "Paper Moons", artist: "Novaeu",
                   reason: "22 plays on Last.fm", plays: 22, motif: 6, top: 0x4A2C12, bottom: 0x140A05, accent: 0xFFB24A),
        WantedSpec(kind: .album, source: .history, title: "Glasswork", artist: "Halden Reef",
                   reason: "18 plays on Last.fm", plays: 18, motif: 2, top: 0x0C333A, bottom: 0x041114, accent: 0x63E0D0),
        WantedSpec(kind: .track, source: .history, title: "Lowlight", artist: "Meridian Wolde",
                   reason: "33 plays on Last.fm", plays: 33, motif: 0, top: 0, bottom: 0, accent: 0),
        WantedSpec(kind: .track, source: .history, title: "Brass Weather", artist: "Monsoon Atlas",
                   reason: "27 plays on Last.fm", plays: 27, motif: 0, top: 0, bottom: 0, accent: 0),
        WantedSpec(kind: .track, source: .loved, title: "Winter Orchard", artist: "Ashgrove",
                   reason: "Loved on Last.fm", plays: 0, motif: 0, top: 0, bottom: 0, accent: 0),
        WantedSpec(kind: .track, source: .history, title: "Static Orchard", artist: "Cobalt Fields",
                   reason: "19 plays on Last.fm", plays: 19, motif: 0, top: 0, bottom: 0, accent: 0),
        WantedSpec(kind: .track, source: .loved, title: "Low Country Waltz", artist: "Odessa Grey",
                   reason: "Loved on Last.fm", plays: 0, motif: 0, top: 0, bottom: 0, accent: 0),
        WantedSpec(kind: .artist, source: .discovery, title: "Pale Meridian", artist: "Pale Meridian",
                   reason: "Because you play Meridian Wolde", plays: 0, motif: 0, top: 0, bottom: 0, accent: 0),
        WantedSpec(kind: .artist, source: .discovery, title: "Northern Ledger", artist: "Northern Ledger",
                   reason: "Because you play Kestrel Vale", plays: 0, motif: 0, top: 0, bottom: 0, accent: 0),
        WantedSpec(kind: .artist, source: .discovery, title: "Sable Harbour", artist: "Sable Harbour",
                   reason: "Because you play Solveig", plays: 0, motif: 0, top: 0, bottom: 0, accent: 0),
        WantedSpec(kind: .artist, source: .discovery, title: "Iris Quarry", artist: "Iris Quarry",
                   reason: "Because you play Virelle", plays: 0, motif: 0, top: 0, bottom: 0, accent: 0),
        WantedSpec(kind: .album, source: .discovery, title: "Salt Atlas", artist: "Pale Meridian",
                   reason: "Because you play Meridian Wolde", plays: 0, motif: 3, top: 0x1F2C2E, bottom: 0x080D0E, accent: 0x9AE6B4),
        WantedSpec(kind: .album, source: .discovery, title: "Evening Cartography", artist: "Northern Ledger",
                   reason: "Because you play Kestrel Vale", plays: 0, motif: 9, top: 0x1A2740, bottom: 0x070A12, accent: 0x7FB8FF),
        WantedSpec(kind: .album, source: .discovery, title: "Harbour Lights", artist: "Sable Harbour",
                   reason: "Because you play Solveig", plays: 0, motif: 5, top: 0x431A28, bottom: 0x13070B, accent: 0xFF93A8),
    ]

    private static func coverURL(_ title: String, _ artist: String) -> String {
        "demo://cover/\(title)/\(artist)".replacingOccurrences(of: " ", with: "-")
    }

    private static func storeCover(_ spec: WantedSpec, url: String) {
        let album = ScreenshotSeeder.DemoAlbum(
            artist: spec.artist, title: spec.title, year: "", genre: "", bitDepth: 16, sampleRate: 44100,
            top: ScreenshotSeeder.rgb(spec.top), bottom: ScreenshotSeeder.rgb(spec.bottom),
            accent: ScreenshotSeeder.rgb(spec.accent), motif: spec.motif, tracks: []
        )
        guard let data = CoverArtRenderer.render(album) else { return }
        ImageCache.shared.store(data: data, forKey: url)
    }

    private static func seedWantlist(db: DatabaseManager) {
        let now = Date()
        var records: [WantlistRecord] = []
        for (offset, spec) in wantedSpecs.enumerated() {
            let hasCover = spec.kind == .album
            let url = hasCover ? coverURL(spec.title, spec.artist) : nil
            if let url { storeCover(spec, url: url) }
            records.append(WantlistRecord(
                normKey: "\(spec.kind.rawValue)|\(spec.source.rawValue)|\(spec.title)|\(spec.artist)",
                kind: spec.kind.rawValue, title: spec.title, artist: spec.artist, imageURL: url,
                state: WantlistState.wanted.rawValue, source: spec.source.rawValue,
                score: Double(1000 - offset * 10), reason: spec.reason, playCount: spec.plays,
                addedAt: now, resolvedAt: nil, acknowledged: true
            ))
        }
        do {
            try db.mergeWantlistSuggestions(records)
        } catch {
            MidgarLog.error("Demo: wantlist seed failed: \(error.localizedDescription)", category: .database)
        }

        let releases: [(String, String, Int, Int, UInt32, UInt32, UInt32)] = [
            ("Hibernal Signals", "Kestrel Vale", 4, 4, 0x0E3B4A, 0x061318, 0x6FE3C8),
            ("Perihelion", "Virelle", 11, 6, 0x2E1550, 0x0B0518, 0xC79BFF),
            ("Havsbris", "Solveig", 19, 9, 0x1A2740, 0x070A12, 0x7FB8FF),
            ("Candle Season", "Marisol Vane", 33, 5, 0x45162A, 0x14060C, 0xFF8FA3),
            ("Tide Table", "Halden Reef", 52, 8, 0x0C333A, 0x041114, 0x63E0D0),
        ]
        var newReleases: [NewReleaseRecord] = []
        for (title, artist, daysAgo, motif, top, bottom, accent) in releases {
            let url = coverURL(title, artist)
            let spec = WantedSpec(
                kind: .album, source: .history, title: title, artist: artist, reason: "", plays: 0,
                motif: motif, top: top, bottom: bottom, accent: accent
            )
            storeCover(spec, url: url)
            newReleases.append(NewReleaseRecord(
                id: nil, artist: artist, albumTitle: title,
                releaseDate: now.addingTimeInterval(-Double(daysAgo) * 86_400),
                imageURL: url, storeURL: nil, fetchedAt: now
            ))
        }
        try? db.replaceNewReleases(newReleases)
    }

    private static func seedEnrichment(db: DatabaseManager) {
        let settled: EnrichmentFields = [.cover, .year, .genre]
        let givenUp: Set<String> = ["Ravine|The Hollowmen", "Lantern Year|Ashgrove", "Statuary|Novaeu"]
        let now = Date()
        for album in ScreenshotSeeder.catalog {
            let key = EnrichmentKey.album(title: album.title, artist: album.artist)
            let exhausted = givenUp.contains("\(album.title)|\(album.artist)")
            try? db.upsertEnrichmentRecord(EnrichmentRecord(
                scope: .album, key: key, version: EnrichmentScope.album.currentVersion,
                status: exhausted ? .exhausted : .satisfied, fields: exhausted ? [.cover] : settled,
                attempts: exhausted ? 4 : 1, lastAttemptAt: now, nextEligibleAt: nil,
                lastFailure: exhausted ? .notFound : nil
            ))
        }
        for artist in Set(ScreenshotSeeder.catalog.map(\.artist)) {
            let exhausted = artist == "Corvid and Crane"
            try? db.upsertEnrichmentRecord(EnrichmentRecord(
                scope: .artist, key: EnrichmentKey.artist(artist), version: EnrichmentScope.artist.currentVersion,
                status: exhausted ? .exhausted : .satisfied, fields: exhausted ? [] : [.artistBio],
                attempts: exhausted ? 4 : 1, lastAttemptAt: now, nextEligibleAt: nil,
                lastFailure: exhausted ? .notFound : nil
            ))
        }
    }

    static var fakeSonglink: SonglinkResult {
        func link(_ key: String, _ name: String, _ icon: String, _ tint: UInt) -> PlatformLink {
            PlatformLink(
                key: key, displayName: name, url: URL(string: "https://example.com/\(key)")!,
                iconName: icon, tintColorHex: tint
            )
        }
        return SonglinkResult(
            pageURL: URL(string: "https://example.com/slow-machine")!,
            platformLinks: [
                link("appleMusic", "Apple Music", "music.note", 0xFC3C44),
                link("youtubeMusic", "YouTube Music", "play.rectangle.fill", 0xFF0000),
                link("tidal", "Tidal", "waveform.circle", 0x000000),
                link("deezer", "Deezer", "beats.headphones", 0xA238FF),
                link("soundcloud", "SoundCloud", "cloud", 0xFF5500),
            ],
            title: ScreenshotSeeder.heroTrack, artist: ScreenshotSeeder.heroArtist
        )
    }
}

/// Turns `FLACCY_ROUTE` into one screen, so every screen is one launch flag.
/// Optional `FLACCY_ALBUM`, `FLACCY_ARTIST`, `FLACCY_PLAYLIST` and `FLACCY_YEAR`
/// pick which record a detail screen shows. Routes that existed before the tab
/// bar still land on the same screen, inside the tab that owns it; no route at
/// all leaves the app on Home, where it now launches.
@MainActor
enum DemoRouter {

    static func runIfRequested(
        window: UIWindow, tabs: AppTabBarController, player: PlayerContainerViewController
    ) {
        guard CommandLine.arguments.contains(ScreenshotSeeder.launchArgument),
              let route = DemoMode.environment["FLACCY_ROUTE"], !route.isEmpty else { return }
        Task {
            if DemoMode.environment["FLACCY_LANDSCAPE"] == "1" {
                window.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) // duo-audit:ignore DEBUG-only demo flag that rotates the scene for captures
            }
            await waitForLibrary()
            try? await Task.sleep(for: .seconds(0.4))
            if DemoMode.environment["FLACCY_EQ"] == "1" {
                let engine = EqualizerEngine.shared
                engine.isDemoSignal = true
                engine.seedDemo(
                    activeProfileID: EqualizerPresets.id(forKey: "bassBoost"),
                    pretendOutput: EqualizerOutput(id: "wired.headphones", name: "Headphones", kind: .headphones)
                )
            }
            perform(route, window: window, tabs: tabs, player: player)
            if let scroll = Double(DemoMode.environment["FLACCY_HOME_SCROLL"] ?? "") {
                try? await Task.sleep(for: .seconds(1.2))
                tabs.home.demoScroll(fraction: CGFloat(scroll))
            }
            if DemoMode.environment["FLACCY_PLAYING"] == "1" || route == "home-playing" {
                try? await Task.sleep(for: .seconds(0.6))
                if !AudioPlayer.shared.isPlaying { AudioPlayer.shared.togglePlayPause() }
            }
        }
    }

    private static func waitForLibrary() async {
        for _ in 0..<200 {
            let queueReady = DemoMode.environment["FLACCY_NO_QUEUE"] == "1" || AudioPlayer.shared.currentTrack != nil
            if DemoMode.isEmptyLibrary { return }
            if Library.shared.albums.count >= ScreenshotSeeder.catalog.count, queueReady { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func destination(for route: String) -> AppTabBarController.Destination {
        switch route {
        case "home", "home-playing", "home-edit", "home-dayone", "home-empty": .home
        case "charts": .recap
        case "search": .search
        default: .library
        }
    }

    private static func perform(
        _ route: String, window: UIWindow, tabs: AppTabBarController, player: PlayerContainerViewController
    ) {
        let env = DemoMode.environment
        let nav = tabs.libraryNavigation
        tabs.show(destination(for: route))
        switch route {
        case "home", "home-playing", "home-dayone", "home-empty", "charts": break
        case "home-edit": tabs.home.presentEditHome()
        case "library":
            tabs.library.select(segment: .albums)
            tabs.library.viewModel.setFilter(.all)
        case "search":
            tabs.search.demoSearch(query: env["FLACCY_QUERY"] ?? "a")
        case "songs": tabs.library.select(segment: .songs)
        case "artists": tabs.library.select(segment: .artists)
        case "playlists": tabs.library.select(segment: .playlists)
        case "album":
            let title = env["FLACCY_ALBUM"] ?? ScreenshotSeeder.heroAlbum
            guard let album = Library.shared.albums.first(where: { $0.title == title }) else { return }
            nav.pushViewController(AlbumDetailViewController(album: album), animated: false)
        case "artist":
            let name = env["FLACCY_ARTIST"] ?? ScreenshotSeeder.heroArtist
            let albums = Library.shared.albums.filter { $0.artist == name }
            nav.pushViewController(ArtistDetailViewController(artistName: name, albums: albums), animated: false)
        case "playlist":
            let name = env["FLACCY_PLAYLIST"] ?? "Night Drive"
            guard let playlist = ((try? DatabaseManager.shared.fetchAllPlaylists()) ?? []).first(where: { $0.name == name }),
                  let id = playlist.id else { return }
            nav.pushViewController(PlaylistDetailViewController(playlistId: id, playlistName: name), animated: false)
        case "wantlist": nav.pushViewController(WantlistViewController(), animated: false)
        case "year":
            let year = Int(env["FLACCY_YEAR"] ?? "") ?? 2025
            present(YearInMusicViewController(year: year), from: tabs)
        case "settings": presentSettings(pushing: nil, from: tabs)
        case "listening-guide": presentSettings(pushing: ListeningGuideViewController(), from: tabs)
        case "recap-notifications": presentSettings(pushing: RecapNotificationsViewController(), from: tabs)
        case "watch-sync": presentSettings(pushing: WatchSyncViewController(), from: tabs)
        case "enrichment": presentSettings(pushing: EnrichmentReportViewController(), from: tabs)
        case "now-playing":
            player.expand()
            if (window.rootViewController as? RootContainerViewController)?.isSplit == true,
               let track = AudioPlayer.shared.currentTrack,
               let album = Library.shared.albums.first(where: { $0.title == track.albumTitle && $0.artist == track.artist }) {
                nav.pushViewController(AlbumDetailViewController(album: album), animated: false)
            }
        case "now-playing-edit":
            player.expand()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                player.beginActionRowEditing()
            }
        case "queue": player.expandShowingQueue()
        case "lyrics": player.expandShowingLyrics()
        case "lyric-share":
            player.expandShowingLyrics()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard let session = LyricShareSession.forCurrentTrack() else { return }
                LyricShareViewController.present(session, from: player)
            }
        case "paywall": PaywallViewController.presentSheet(from: tabs)
        case "equalizer", "equalizer-advanced", "equalizer-presets", "equalizer-outputs", "equalizer-import", "equalizer-preview", "equalizer-preview-cancel":
            player.expand()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { presentEqualizer(route, from: tabs) }
        case "streaming":
            presentSheet(UINavigationController(rootViewController: StreamingLinksViewController(result: DemoMode.fakeSonglink)), from: tabs)
        case "computer-guide":
            presentSheet(UINavigationController(rootViewController: ComputerTransferGuideViewController()), from: tabs)
        default: break
        }
    }

    /// Seeds a fictional listening history for the equalizer and shows one of its screens
    /// over whatever is on top, the way a person would open it from Now Playing.
    private static func presentEqualizer(_ route: String, from presenter: UIViewController) {
        let engine = EqualizerEngine.shared
        engine.start()
        engine.isDemoSignal = true
        let isPreview = route.hasPrefix("equalizer-preview")
        let isSimple = route == "equalizer" || isPreview
        engine.seedDemo(
            activeProfileID: isPreview ? EqualizerPresets.id(forKey: "rock") : (isSimple ? EqualizerPresets.id(forKey: "bassBoost") : "demo.warm"),
            pretendOutput: isSimple
                ? EqualizerOutput(id: "wired.headphones", name: "Headphones", kind: .headphones)
                : EqualizerOutput(id: "bluetooth.demo", name: "AirPods Pro", kind: .bluetooth)
        )
        let controller = EqualizerViewController.makePresented()
        var top: UIViewController = presenter
        while let presented = top.presentedViewController { top = presented }
        top.present(controller, animated: false)
        let accent = EqualizerTheme.fallbackAccent
        switch route {
        case "equalizer-presets": controller.pushViewController(EqualizerPresetsViewController(startingOn: .presets, accent: accent), animated: false)
        case "equalizer-outputs": controller.pushViewController(EqualizerPresetsViewController(startingOn: .outputs, accent: accent), animated: false)
        case "equalizer-import": controller.pushViewController(EqualizerImportViewController(accent: accent, initialText: EqualizerShots.importSample), animated: false)
        case "equalizer-preview", "equalizer-preview-cancel":
            let screen = controller.viewControllers.first as? EqualizerViewController
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                screen?.showAuditionForScreenshot(presetKey: "bassBoost", cancelling: route == "equalizer-preview-cancel")
            }
        default: break
        }
    }

    private static func present(_ controller: UIViewController, from presenter: UIViewController) {
        presenter.present(controller, animated: false)
    }

    private static func presentSheet(_ controller: UINavigationController, from presenter: UIViewController) {
        controller.modalPresentationStyle = .pageSheet
        presenter.present(controller, animated: false)
    }

    private static func presentSettings(pushing next: UIViewController?, from presenter: UIViewController) {
        let settings = UINavigationController(rootViewController: SettingsViewController())
        if let next { settings.pushViewController(next, animated: false) }
        presentSheet(settings, from: presenter)
    }
}
#endif
