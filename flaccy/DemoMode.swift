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

    static let version = 9
    private static let versionKey = "flaccy.demo.version"

    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static func eraseIfStale(_ db: DatabaseManager) {
        guard UserDefaults.standard.integer(forKey: versionKey) != version else { return }
        do {
            try db.eraseDemoContent()
            eraseDemoFiles()
            AppLogger.info("Demo: stale content erased for version \(version)", category: .database)
        } catch {
            AppLogger.error("Demo: erase failed: \(error.localizedDescription)", category: .database)
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
        UserDefaults.standard.set(version, forKey: versionKey)
        AppLogger.info("Demo: supplements seeded (version \(version))", category: .content)
    }

    private static func path(_ albumTitle: String, _ number: Int) -> String? {
        guard let album = ScreenshotSeeder.catalog.first(where: { $0.title == albumTitle }),
              let track = album.tracks.first(where: { $0.number == number })
        else { return nil }
        return ScreenshotSeeder.relativePath(album: album, track: track)
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
                instrumental: false, fetchedAt: Date()
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
            AppLogger.error("Demo: wantlist seed failed: \(error.localizedDescription)", category: .database)
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
/// pick which record a detail screen shows.
@MainActor
enum DemoRouter {

    static func runIfRequested(
        window: UIWindow, nav: UINavigationController, player: PlayerContainerViewController
    ) {
        guard CommandLine.arguments.contains(ScreenshotSeeder.launchArgument),
              let route = DemoMode.environment["FLACCY_ROUTE"], !route.isEmpty else { return }
        Task {
            await waitForLibrary()
            try? await Task.sleep(for: .seconds(0.4))
            perform(route, window: window, nav: nav, player: player)
            if DemoMode.environment["FLACCY_PLAYING"] == "1" {
                try? await Task.sleep(for: .seconds(0.6))
                if !AudioPlayer.shared.isPlaying { AudioPlayer.shared.togglePlayPause() }
            }
        }
    }

    private static func waitForLibrary() async {
        for _ in 0..<200 {
            let queueReady = DemoMode.environment["FLACCY_NO_QUEUE"] == "1" || AudioPlayer.shared.currentTrack != nil
            if Library.shared.albums.count >= ScreenshotSeeder.catalog.count, queueReady { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func perform(
        _ route: String, window: UIWindow, nav: UINavigationController, player: PlayerContainerViewController
    ) {
        let env = DemoMode.environment
        let library = nav.viewControllers.first as? LibraryViewController
        switch route {
        case "songs": library?.demoSelect(segment: .songs)
        case "artists": library?.demoSelect(segment: .artists)
        case "playlists": library?.demoSelect(segment: .playlists)
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
        case "charts": nav.pushViewController(ChartsViewController(), animated: false)
        case "wantlist": nav.pushViewController(WantlistViewController(), animated: false)
        case "year":
            let year = Int(env["FLACCY_YEAR"] ?? "") ?? 2025
            present(YearInMusicViewController(year: year), from: nav)
        case "settings": presentSettings(pushing: nil, from: nav)
        case "listening-guide": presentSettings(pushing: ListeningGuideViewController(), from: nav)
        case "recap-notifications": presentSettings(pushing: RecapNotificationsViewController(), from: nav)
        case "watch-sync": presentSettings(pushing: WatchSyncViewController(), from: nav)
        case "enrichment": presentSettings(pushing: EnrichmentReportViewController(), from: nav)
        case "now-playing":
            player.expand()
            if (window.rootViewController as? RootContainerViewController)?.isSplit == true,
               let track = AudioPlayer.shared.currentTrack,
               let album = Library.shared.albums.first(where: { $0.title == track.albumTitle && $0.artist == track.artist }) {
                nav.pushViewController(AlbumDetailViewController(album: album), animated: false)
            }
        case "queue": player.expandShowingQueue()
        case "lyrics": player.expandShowingLyrics()
        case "paywall": PaywallViewController.presentSheet(from: nav)
        case "streaming":
            presentSheet(UINavigationController(rootViewController: StreamingLinksViewController(result: DemoMode.fakeSonglink)), from: nav)
        case "computer-guide":
            presentSheet(UINavigationController(rootViewController: ComputerTransferGuideViewController()), from: nav)
        default: break
        }
    }

    private static func present(_ controller: UIViewController, from nav: UINavigationController) {
        nav.present(controller, animated: false)
    }

    private static func presentSheet(_ controller: UINavigationController, from nav: UINavigationController) {
        controller.modalPresentationStyle = .pageSheet
        nav.present(controller, animated: false)
    }

    private static func presentSettings(pushing next: UIViewController?, from nav: UINavigationController) {
        let settings = UINavigationController(rootViewController: SettingsViewController())
        if let next { settings.pushViewController(next, animated: false) }
        presentSheet(settings, from: nav)
    }
}
#endif
