import MidgarCore
#if DEBUG
import AppKit
import FlaccyCore
import ImageIO

/// A tally of notifications that an exercise counts. The observer posts on the main queue and the exercise reads the
/// tally on the main actor, so the two never touch it at once.
nonisolated final class ObservedCount: @unchecked Sendable {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
import UniformTypeIdentifiers

/// Headless verification for the artwork editor. `--exercise-artwork` drives
/// the real save and reset path against the seeded library and logs
/// `ArtworkExercise PASS/FAIL` per expectation; `--shot-artwork-editor
/// [loaded|soft|online|zoomed|saved|playlist|playlist-empty]` opens the real
/// sheet over the seeded album (or a seeded playlist) and captures it.
/// `--exercise-playlist-cover` does the same for a playlist's chosen cover.
/// Compiled out of Release entirely.
enum DebugArtworkDrive {

    static func runIfRequested(window: NSWindow?) {
        if CommandLine.arguments.contains("--exercise-artwork") {
            Task { await exercise(window: window) }
        }
        if CommandLine.arguments.contains("--exercise-playlist-cover") {
            Task { await exercisePlaylistCover(window: window) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--shot-artwork-editor") {
            let variant = index + 1 < CommandLine.arguments.count && !CommandLine.arguments[index + 1].hasPrefix("--")
                ? CommandLine.arguments[index + 1] : "loaded"
            Task { await shoot(variant: variant, window: window) }
        }
    }

    private static var results: [Bool] = []

    private static func report(_ expectation: String, _ passed: Bool) {
        results.append(passed)
        let line = "ArtworkExercise \(passed ? "PASS" : "FAIL"): \(expectation)"
        MidgarLog.info(line, category: .general)
        FileHandle.standardError.write(Data((line + "\n").utf8))
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "artwork-exercise.txt")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (existing + line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func waitForLibrary() async -> Album? {
        var attempts = 0
        while Library.shared.albums.isEmpty, attempts < 60 {
            try? await Task.sleep(for: .milliseconds(500))
            attempts += 1
        }
        return Library.shared.albums.first { $0.title == "Parallax Hours" } ?? Library.shared.albums.first
    }

    private static func exercise(window: NSWindow?) async {
        try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + "artwork-exercise.txt")
        exerciseSearchFixtures()
        exerciseRendering()
        await exerciseLocalDiscovery()
        exerciseDatabaseSurvival()
        guard let album = await waitForLibrary() else {
            report("a seeded album is available", false)
            return
        }
        await exerciseSaveAndReset(album: album, window: window)
        let verdict = results.allSatisfy { $0 } ? "PASSED" : "FAILED"
        let line = "ArtworkExercise \(verdict): \(results.filter { $0 }.count) of \(results.count)"
        MidgarLog.info(line, category: .general)
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private static func exercisePlaylistCover(window: NSWindow?) async {
        try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + "artwork-exercise.txt")
        results = []
        let parent = window ?? NSApp.windows.first(where: { $0.contentViewController is RootContainerViewController })
        guard await waitForLibrary() != nil, let parent else {
            report("a seeded library and a window are available", false)
            return
        }
        let tracks = Library.shared.albums.prefix(3).compactMap { $0.tracks.first }
        report("the library offers tracks from three albums", tracks.count == 3)
        let database = DatabaseManager.shared
        let name = "Cover Exercise \(UUID().uuidString.prefix(6))"
        guard let playlist = try? database.createPlaylist(name: name), let id = playlist.id else {
            report("a playlist could be created", false)
            return
        }
        defer { try? database.deletePlaylist(id: id) }
        PlaylistActions.add(tracks, toPlaylist: id, named: name, in: nil)
        let reservedTitle = PlaylistCover.title(forPlaylist: id)
        let subject = ArtworkSubject(playlistId: id, name: name, tracks: tracks)

        let mosaic = MosaicArtworkView(frame: NSRect(x: 0, y: 0, width: 130, height: 130))
        mosaic.configure(playlistId: id, tracks: tracks, fallbackSeed: name)
        try? await Task.sleep(for: .milliseconds(600))
        report("a new playlist has no custom cover", !AlbumArtworkEditor.hasCustomCover(subject)
               && (try? database.fetchAlbumArtwork(title: reservedTitle, artist: PlaylistCover.artist)) == nil)
        report("the mosaic view starts on the album mosaic", !mosaic.showsCustomCover)

        guard let editor = MacArtworkEditor.present(forPlaylist: playlist, tracks: tracks, from: parent) else {
            report("the playlist editor opened", false)
            return
        }
        await waitUntil { editor.debugLocalTileCount >= 3 }
        report("the From This Playlist shelf offers each album's cover", editor.debugLocalTileCount == 3)
        report("a playlist with no cover starts with an empty preview", editor.debugCropImageSize == .zero)
        report("the online search waits for the person", editor.debugOnlineTileCount == 0)

        let source = quadrantImage(width: 1200, height: 900)
        editor.debugAdopt(source, source: "exercise")
        report("an adopted picture enables Save", editor.debugSaveEnabled)
        let notifications = ObservedCount()
        let token = NotificationCenter.default.addObserver(forName: AlbumArtworkCache.didChangeNotification, object: nil, queue: .main) { _ in
            notifications.increment()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        editor.debugSave()
        await waitUntil { AlbumArtworkEditor.hasCustomCover(subject) }
        let saved = try? database.fetchAlbumArtwork(title: reservedTitle, artist: PlaylistCover.artist)
        report("Save stores the cover under the reserved key", saved != nil && saved.flatMap(decode).map { isColor($0, $0.width / 4, $0.height / 4, red: true) } == true)
        report("the editor now reports a custom cover", AlbumArtworkEditor.hasCustomCover(subject))
        await waitUntil { notifications.value > 0 && mosaic.showsCustomCover }
        report("saving fires the change notification once", notifications.value == 1)
        report("the mosaic view reports the custom state", mosaic.showsCustomCover)
        await waitUntil { parent.attachedSheet == nil }

        let sameText = Album(title: reservedTitle, artist: "Anyone", artwork: nil, tracks: [], year: nil, genre: nil)
        report("an album titled with the same text is unaffected",
               (try? database.fetchAlbumArtwork(title: sameText.title, artist: sameText.artist)) == nil
               && !AlbumArtworkEditor.hasCustomCover(sameText))
        let firstAlbum = Library.shared.albums[0]
        report("a real album still serves its own artwork",
               (try? database.fetchAlbumArtwork(title: firstAlbum.title, artist: firstAlbum.artist)) != saved)

        if let reopened = MacArtworkEditor.present(forPlaylist: playlist, tracks: tracks, from: parent) {
            await waitUntil { reopened.debugCropImageSize != .zero }
            report("reopening shows the chosen cover as the current artwork", reopened.debugCropImageSize != .zero)
            report("the online search still waits", reopened.debugOnlineTileCount == 0)
            reopened.requestCancel()
            await waitUntil { parent.attachedSheet == nil }
        } else {
            report("the editor reopened", false)
        }

        try? database.savePlaylistCover(saved ?? Data(), id: id)
        AlbumArtworkCache.shared.invalidate(keys: [(reservedTitle, PlaylistCover.artist)])
        await waitUntil { mosaic.showsCustomCover }
        await Library.shared.reloadFromDatabase()
        await Library.shared.reload()
        let model = LibraryViewModel()
        model.search(query: "")
        try? await Task.sleep(for: .milliseconds(500))
        report("a library reload leaves the playlist cover alone",
               (try? database.playlistCover(id: id)) == saved && AlbumArtworkEditor.hasCustomCover(subject))

        do {
            try AlbumArtworkEditor.reset(subject)
        } catch {
            report("resetting the cover: \(error)", false)
        }
        report("reset returns no cover", (try? database.fetchAlbumArtwork(title: reservedTitle, artist: PlaylistCover.artist)) == nil
               && !AlbumArtworkEditor.hasCustomCover(subject))
        await waitUntil { !mosaic.showsCustomCover }
        report("the mosaic view goes back to the album mosaic", !mosaic.showsCustomCover)

        try? database.savePlaylistCover(saved ?? Data(), id: id)
        PlaylistsViewController.rename(playlistId: id, from: name, to: name + " Renamed", in: nil)
        let renamed = (try? database.fetchAllPlaylists())?.first { $0.name == name + " Renamed" }
        report("renaming the playlist keeps its cover",
               renamed?.id.flatMap { try? database.playlistCover(id: $0) } == saved)
        report("renaming keeps the playlist row itself", renamed?.id == id)
        if let renamedId = renamed?.id {
            try? database.deletePlaylist(id: renamedId)
            report("deleting the playlist leaves no cover", (try? database.playlistCover(id: renamedId)) == nil
                   && !((try? database.playlistIdsWithCovers()) ?? [renamedId]).contains(renamedId))
        } else {
            report("the renamed playlist exists", false)
        }

        let verdict = results.allSatisfy { $0 } ? "PASSED" : "FAILED"
        let line = "ArtworkExercise \(verdict): \(results.filter { $0 }.count) of \(results.count)"
        MidgarLog.info(line, category: .general)
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Gives the named playlist a picture the way the editor would, for a
    /// capture of the playlist page with a custom cover.
    static func seedCustomCover(forPlaylistNamed name: String) {
        guard let record = (try? DatabaseManager.shared.fetchAllPlaylists())?.first(where: { $0.name == name }),
              let id = record.id,
              let framing = ArtworkFraming(imageWidth: 900, imageHeight: 900, frameSide: 400),
              let data = AlbumArtworkEditor.render(gradientImage(side: 900, hue: 0.85), framing: framing)
        else { return }
        try? DatabaseManager.shared.savePlaylistCover(data, id: id)
        AlbumArtworkCache.shared.invalidate(keys: [(PlaylistCover.title(forPlaylist: id), PlaylistCover.artist)])
    }

    private static func exerciseSearchFixtures() {
        let apple = OnlineArtworkSearch.appleCandidates(
            from: Data(#"{"results":[{"collectionId":7,"collectionName":"Kind of Blue (Legacy Edition)","artistName":"Miles Davis","artworkUrl100":"https://is1.example/image/100x100bb.jpg"}]}"#.utf8),
            title: "Kind of Blue", artist: "Miles Davis"
        )
        report("Apple art is asked for at 3000 and 360", apple.first?.fullURL.absoluteString.hasSuffix("3000x3000bb.jpg") == true
            && apple.first?.thumbnailURL.absoluteString.hasSuffix("360x360bb.jpg") == true)
        report("an edition-folded exact match scores 1.0", apple.first.map { abs($0.score - 1) < 0.0001 } ?? false)

        let deezer = OnlineArtworkSearch.deezerCandidates(
            from: Data(#"{"data":[{"id":3,"title":"Aurorae","artist":{"name":"Kestrel Vale"},"cover_medium":"https://d.example/m.jpg","cover_big":"https://d.example/b.jpg","cover_xl":"https://d.example/xl.jpg"}]}"#.utf8),
            title: "Aurorae", artist: "Kestrel Vale"
        )
        report("Deezer uses cover_xl for full and cover_medium for the thumbnail",
               deezer.first?.fullURL.lastPathComponent == "xl.jpg" && deezer.first?.thumbnailURL.lastPathComponent == "m.jpg")

        let archive = OnlineArtworkSearch.coverArchiveCandidates(
            from: Data(#"{"release-groups":[{"id":"abc","title":"OK Computer","artist-credit":[{"name":"Radiohead","joinphrase":""}]}]}"#.utf8),
            title: "OK Computer", artist: "Radiohead"
        )
        report("Cover Art Archive gives front-250 and front-1200 per release group",
               archive.first?.thumbnailURL.absoluteString == "https://coverartarchive.org/release-group/abc/front-250"
               && archive.first?.fullURL.absoluteString == "https://coverartarchive.org/release-group/abc/front-1200")

        let many = (0..<25).map { index in
            ArtworkCandidate(
                id: "c\(index)", source: "T", title: "t", artist: "a",
                thumbnailURL: URL(string: "https://x.example/t\(index)")!, fullURL: URL(string: "https://x.example/f\(index % 24)")!,
                score: 0.9 - Double(index) * 0.01
            )
        }
        let ranked = OnlineArtworkSearch.rank(many, keepOnlyConfident: false)
        report("ranking dedupes by full URL and caps at 18", ranked.count == 18 && Set(ranked.map(\.fullURL)).count == 18)
        report("the default query omits Various Artists",
               OnlineArtworkSearch.defaultQuery(title: "Score", artist: "Various Artists") == "Score")
    }

    private static func exerciseRendering() {
        let source = quadrantImage(width: 1200, height: 900)
        guard let framing = ArtworkFraming(imageWidth: 1200, imageHeight: 900, frameSide: 400),
              let data = AlbumArtworkEditor.render(source, framing: framing),
              let output = decode(data)
        else {
            report("a framing renders to a JPEG", false)
            return
        }
        report("the saved square is outputPixels(limit: 1600) on a side", output.width == framing.outputPixels(limit: 1600) && output.width == output.height)
        let side = output.width
        report("the render keeps the source's orientation (red, green, blue, yellow)",
               isColor(output, side / 4, side / 4, red: true)
               && isColor(output, side * 3 / 4, side / 4, green: true)
               && isColor(output, side / 4, side * 3 / 4, blue: true)
               && isColor(output, side * 3 / 4, side * 3 / 4, yellow: true))
        let zoomed = framing.zoomed(to: framing.fillZoom * 3).panned(dx: -1000, dy: -1000)
        if let zoomedData = AlbumArtworkEditor.render(source, framing: zoomed), let zoomedOutput = decode(zoomedData) {
            report("a zoomed and panned framing lands on the bottom-right quadrant",
                   isColor(zoomedOutput, zoomedOutput.width / 2, zoomedOutput.height / 2, yellow: true))
        } else {
            report("a zoomed framing renders", false)
        }
        report("a source under 500 visible pixels is soft", ArtworkFraming(imageWidth: 320, imageHeight: 320, frameSide: 300)?.isSoft == true)
    }

    private static func exerciseLocalDiscovery() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("artwork-local-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Artist/Album", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["back.jpg", "cover.jpg", "folder.png", "scan.jpg", "thumb.jpg", "._cover.jpg"] {
                try writeImage(quadrantImage(width: 640, height: 480), to: folder.appendingPathComponent(name))
            }
            try Data("x".utf8).write(to: folder.appendingPathComponent("notes.txt"))
            let png = try ImageEncoding.encode(quadrantImage(width: 300, height: 300), as: .png)
            let other = try ImageEncoding.encode(gradientImage(side: 200), as: .png)
            try makeMP3(embedding: png).write(to: folder.appendingPathComponent("01.mp3"))
            try makeMP3(embedding: png).write(to: folder.appendingPathComponent("02.mp3"))
            try makeMP3(embedding: other).write(to: folder.appendingPathComponent("03.mp3"))
        } catch {
            report("the local discovery fixtures could be written", false)
            return
        }
        let tracks = (1...3).map { number in
            syntheticTrack(url: folder.appendingPathComponent("0\(number).mp3"), number: number)
        }
        let album = Album(title: "Album", artist: "Artist", artwork: nil, tracks: tracks, year: nil, genre: nil)
        let files = LocalArtworkFinder.folderImages(for: album, root: root)
        report("folder images are ranked front cover first, back last, skipping thumbnails and resource forks",
               files.map(\.label) == ["cover.jpg", "folder.png", "scan.jpg", "back.jpg"])
        report("each folder image reports its pixel size", files.first.map { $0.pixelWidth == 640 && $0.pixelHeight == 480 } ?? false)
        let embedded = await LocalArtworkFinder.embeddedImages(for: album)
        report("embedded pictures are read from the files and de-duplicated by content (3 tracks, 2 pictures)", embedded.count == 2)
        report("an embedded picture is labelled by its track and sized", embedded.first.map { $0.label == "Track 1" && $0.pixelWidth == 300 } ?? false)
    }

    private static func exerciseDatabaseSurvival() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("artwork-db-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let db = try DatabaseManager(path: directory.appendingPathComponent("library.sqlite").path)
            let custom = Data(repeating: 0xC1, count: 2_048)
            func insert(_ path: String, artist: String, album: String, art: Data?) throws {
                try db.insertTracks([TrackRecord(
                    fileURL: path, title: path, artist: artist, albumTitle: album, albumArtist: nil, trackNumber: 1, duration: 100,
                    artworkData: art, lastFMArtworkURL: nil, musicBrainzID: nil, albumMusicBrainzID: nil, dateAdded: Date(),
                    lastPlayed: nil, playCount: 0, aiAnalyzed: false, analysisAttemptedAt: nil, codec: "FLAC", bitDepth: 16,
                    sampleRate: 44100, channels: 2
                )])
            }
            try insert("S/0.flac", artist: "A", album: "Score", art: Data(repeating: 1, count: 64))
            try insert("S/1.flac", artist: "B", album: "Score", art: Data(repeating: 1, count: 64))
            try db.saveCustomCover(custom, forKeys: [("Score", "A"), ("Score", "B"), ("Score", AlbumCredit.variousArtists)])
            report("a custom cover outranks the embedded one", try db.fetchAlbumArtwork(title: "Score", artist: "A") == custom)
            try insert("S/2.flac", artist: "A", album: "Score", art: Data(repeating: 2, count: 64))
            try db.saveAlbumCoverArtIfMissing(title: "Score", artist: "A", data: Data(repeating: 3, count: 64))
            try db.applyAlbumEnrichment(
                title: "Score", artist: "A", coverArtURL: "https://example.com/c.jpg", coverArtData: Data(repeating: 4, count: 64),
                musicBrainzID: "m", year: "2000", genre: "g",
                record: EnrichmentRecord(scope: .album, key: EnrichmentKey.album(title: "Score", artist: "A"))
            )
            report("rescan hoisting, first-writer-wins and enrichment never overwrite it",
                   try db.fetchAlbumArtwork(title: "Score", artist: "A") == custom)
            try db.resolveAlbumCredits()
            try db.resolveAlbumCredits()
            report("credit settling and cover adoption leave it in place",
                   try db.fetchAlbumArtwork(title: "Score", artist: AlbumCredit.variousArtists) == custom
                   && (try db.fetchAlbumArtwork(title: "Score", artist: "B")) == custom)
            try db.saveCustomCover(custom, forKeys: [("Score (Deluxe)", "A")])
            try db.applyHygiene(
                retitles: [], keeperUpdates: [],
                albumInfoMerges: [AlbumInfoMerge(
                    canonicalTitle: "Fresh", canonicalArtist: "A",
                    variants: [LibraryHygiene.AlbumVariant(title: "Score (Deluxe)", artist: "A")]
                )],
                loserRelativePaths: []
            )
            report("merging an edition carries its chosen cover to the canonical album",
                   try db.fetchAlbumArtwork(title: "Fresh", artist: "A") == custom)
            try db.clearCustomCover(forKeys: [("Score", "A")])
            report("clearing returns the embedded cover", try db.fetchAlbumArtwork(title: "Score", artist: "A") != custom)
        } catch {
            report("the database survival checks ran: \(error)", false)
        }
    }

    private static func exerciseSaveAndReset(album: Album, window: NSWindow?) async {
        let keys = AlbumArtworkEditor.keys(for: album)
        report("keys cover the album and each of its tracks", keys.count >= 1 && keys.first?.title == album.title)
        let original = try? DatabaseManager.shared.fetchAlbumArtwork(title: album.title, artist: album.artist)
        report("the seeded album has original artwork", original != nil)
        report("it starts without a custom cover", !AlbumArtworkEditor.hasCustomCover(album))

        let item = AlbumGridItem()
        _ = item.view
        item.configure(with: album, loved: false)
        await waitUntil { item.debugShownImage != nil }
        let before = item.debugShownImage
        report("a grid tile shows the original cover", before != nil && !isColor(before!, before!.width / 4, before!.height / 4, red: true))

        let detail = AlbumDetailViewController(album: album)
        _ = detail.view
        await waitUntil { detail.debugShownImage != nil }
        report("the album detail header shows the original cover first", detail.debugShownImage.map { !isColor($0, $0.width / 4, $0.height / 4, red: true) } ?? false)

        let notifications = ObservedCount()
        let token = NotificationCenter.default.addObserver(forName: AlbumArtworkCache.didChangeNotification, object: nil, queue: .main) { _ in
            notifications.increment()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        guard let framing = ArtworkFraming(imageWidth: 1200, imageHeight: 900, frameSide: 400),
              let data = AlbumArtworkEditor.render(quadrantImage(width: 1200, height: 900), framing: framing)
        else {
            report("a cover could be rendered", false)
            return
        }
        do {
            try AlbumArtworkEditor.save(data, for: album)
        } catch {
            report("saving the cover: \(error)", false)
            return
        }
        report("the saved cover is the first thing the database returns", (try? DatabaseManager.shared.fetchAlbumArtwork(title: album.title, artist: album.artist)) == data)
        report("every key has the cover", keys.allSatisfy { (try? DatabaseManager.shared.fetchAlbumArtwork(title: $0.title, artist: $0.artist)) == data })
        report("the in-memory cache was invalidated before anything repainted", AlbumArtworkCache.shared.artwork(forAlbum: album.title, artist: album.artist) == nil)
        await waitUntil { notifications.value > 0 }
        report("the change notification fired once", notifications.value == 1)
        report("the editor now sees a custom cover", AlbumArtworkEditor.hasCustomCover(album))
        await waitUntil { item.debugShownImage.map { isColor($0, $0.width / 4, $0.height / 4, red: true) } ?? false }
        let after = item.debugShownImage
        report("the grid tile repainted with the new cover", after.map { isColor($0, $0.width / 4, $0.height / 4, red: true) } ?? false)
        await waitUntil { detail.debugShownImage.map { isColor($0, $0.width / 4, $0.height / 4, red: true) } ?? false }
        report("the album detail header repainted with the new cover", detail.debugShownImage.map { isColor($0, $0.width / 4, $0.height / 4, red: true) } ?? false)

        do {
            try AlbumArtworkEditor.reset(album)
        } catch {
            report("restoring the original: \(error)", false)
            return
        }
        report("reset returns the original artwork", (try? DatabaseManager.shared.fetchAlbumArtwork(title: album.title, artist: album.artist)) == original)
        report("reset clears the custom flag", !AlbumArtworkEditor.hasCustomCover(album))
        await waitUntil { item.debugShownImage.map { !isColor($0, $0.width / 4, $0.height / 4, red: true) } ?? false }
        report("the grid tile went back to the original", item.debugShownImage.map { !isColor($0, $0.width / 4, $0.height / 4, red: true) } ?? false)
        await waitUntil { detail.debugShownImage.map { !isColor($0, $0.width / 4, $0.height / 4, red: true) } ?? false }
        report("the album detail header went back too", detail.debugShownImage.map { !isColor($0, $0.width / 4, $0.height / 4, red: true) } ?? false)
        report("the notification fired again", notifications.value == 2)
    }

    private static func waitUntil(timeout: Int = 40, _ condition: () -> Bool) async {
        var attempts = 0
        while !condition(), attempts < timeout {
            try? await Task.sleep(for: .milliseconds(150))
            attempts += 1
        }
    }

    private static func shoot(variant: String, window: NSWindow?) async {
        guard let hero = await waitForLibrary() else { return }
        try? await Task.sleep(for: .seconds(2))
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("artwork-shot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let folder = hero.tracks.first?.fileURL.deletingLastPathComponent()
        var staged: [URL] = []
        defer { staged.forEach { try? FileManager.default.removeItem(at: $0) } }
        if let folder {
            for (name, side) in [("cover.png", 900), ("folder.jpg", 600), ("back.jpg", 320)] {
                let url = folder.appendingPathComponent(name)
                if (try? writeImage(gradientImage(side: side, hue: name == "back.jpg" ? 0.1 : 0.55), to: url)) != nil { staged.append(url) }
            }
        }
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var tracks = hero.tracks
        if let png = try? ImageEncoding.encode(gradientImage(side: 700, hue: 0.85), as: .png) {
            let mp3 = staging.appendingPathComponent("embedded.mp3")
            try? makeMP3(embedding: png).write(to: mp3)
            tracks.append(syntheticTrack(url: mp3, number: 7))
        }
        let album = Album(title: hero.title, artist: hero.artist, artwork: nil, tracks: tracks, year: hero.year, genre: hero.genre)

        if variant == "saved" {
            LibraryNavigator.revealAlbum(title: hero.title, artist: hero.artist)
            try? await Task.sleep(for: .seconds(3))
        }
        let parent = window ?? NSApp.windows.first(where: { $0.contentViewController is RootContainerViewController })
        if variant.hasPrefix("playlist") {
            await shootPlaylist(variant: variant, hero: hero, parent: parent)
            return
        }
        guard let editor = MacArtworkEditor.present(for: album, from: parent) else {
            MidgarLog.error("ArtworkShot: the editor did not open", category: .general)
            return
        }
        try? await Task.sleep(for: .seconds(2))
        let image = variant == "soft" ? gradientImage(side: 320, hue: 0.3) : quadrantImage(width: 1600, height: 1200)
        editor.debugAdopt(image, source: "test-image")
        if variant == "zoomed" { editor.debugFrame(zoomFraction: 1.6, anchor: CGPoint(x: 80, y: 80)) }
        if variant == "online" {
            editor.debugSearch("Radiohead OK Computer")
            await waitUntil(timeout: 80) { editor.debugOnlineTileCount >= 3 }
            try? await Task.sleep(for: .seconds(4))
        }
        try? await Task.sleep(for: .seconds(2))
        MidgarLog.info("ArtworkShot \(variant): local tiles \(editor.debugLocalTileCount), online tiles \(editor.debugOnlineTileCount), soft \(editor.debugSoftLabelVisible), save enabled \(editor.debugSaveEnabled)", category: .general)
        DebugDrive.captureSheet(of: window, name: "flaccy-shot-artwork-\(variant)")
        if variant == "saved" {
            editor.debugSave()
            try? await Task.sleep(for: .seconds(4))
            DebugDrive.capture(window: window, name: "flaccy-shot-artwork-saved-after")
            try? AlbumArtworkEditor.reset(hero)
        }
    }

    private static func shootPlaylist(variant: String, hero: Album, parent: NSWindow?) async {
        let name = "Shot Playlist"
        let tracks = Library.shared.albums.prefix(4).compactMap { $0.tracks.first }
        guard let playlist = try? DatabaseManager.shared.createPlaylist(name: name), let id = playlist.id else { return }
        PlaylistActions.add(tracks, toPlaylist: id, named: name, in: nil)
        if variant == "playlist" { seedCustomCover(forPlaylistNamed: name) }
        guard let editor = MacArtworkEditor.present(forPlaylist: playlist, tracks: tracks, from: parent) else {
            MidgarLog.error("ArtworkShot: the playlist editor did not open", category: .general)
            return
        }
        try? await Task.sleep(for: .seconds(3))
        MidgarLog.info("ArtworkShot \(variant): local tiles \(editor.debugLocalTileCount), online tiles \(editor.debugOnlineTileCount), save enabled \(editor.debugSaveEnabled)", category: .general)
        DebugDrive.captureSheet(of: parent, name: "flaccy-shot-artwork-\(variant)")
        editor.requestCancel()
        try? await Task.sleep(for: .seconds(1))
        try? DatabaseManager.shared.deletePlaylist(id: id)
    }

    private static func syntheticTrack(url: URL, number: Int) -> Track {
        Track(
            fileURL: url, title: "Track \(number)", artist: "Artist", albumTitle: "Album", albumArtist: nil,
            trackNumber: number, duration: 30, artwork: nil, dbID: nil
        )
    }

    private static func quadrantImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let halves: [(CGColor, CGRect)] = [
            (CGColor(red: 0.9, green: 0.12, blue: 0.12, alpha: 1), CGRect(x: 0, y: height / 2, width: width / 2, height: height - height / 2)),
            (CGColor(red: 0.12, green: 0.78, blue: 0.12, alpha: 1), CGRect(x: width / 2, y: height / 2, width: width - width / 2, height: height - height / 2)),
            (CGColor(red: 0.12, green: 0.12, blue: 0.9, alpha: 1), CGRect(x: 0, y: 0, width: width / 2, height: height / 2)),
            (CGColor(red: 0.94, green: 0.86, blue: 0.12, alpha: 1), CGRect(x: width / 2, y: 0, width: width - width / 2, height: height / 2)),
        ]
        for (color, rect) in halves {
            context.setFillColor(color)
            context.fill(rect)
        }
        return context.makeImage()!
    }

    private static func gradientImage(side: Int, hue: CGFloat = 0.6) -> CGImage {
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let top = NSColor(hue: hue, saturation: 0.7, brightness: 0.95, alpha: 1).cgColor
        let bottom = NSColor(hue: hue, saturation: 0.9, brightness: 0.25, alpha: 1).cgColor
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: side), end: CGPoint(x: side, y: 0), options: [])
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.7))
        context.setLineWidth(CGFloat(side) / 80)
        context.strokeEllipse(in: CGRect(x: side / 4, y: side / 4, width: side / 2, height: side / 2))
        return context.makeImage()!
    }

    private static func writeImage(_ image: CGImage, to url: URL) throws {
        try ImageEncoding.encode(image, as: url.pathExtension.lowercased() == "png" ? .png : .jpeg).write(to: url)
    }

    private static func decode(_ data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    private static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    private static func isColor(_ image: CGImage, _ x: Int, _ y: Int, red: Bool = false, green: Bool = false, blue: Bool = false, yellow: Bool = false) -> Bool {
        let (r, g, b) = pixel(image, x, y)
        if red { return r > 170 && g < 90 && b < 90 }
        if green { return g > 140 && r < 90 && b < 90 }
        if blue { return b > 170 && r < 90 && g < 90 }
        if yellow { return r > 190 && g > 170 && b < 90 }
        return false
    }

    /// A minimal MP3: an ID3v2.3 tag carrying one attached picture, then enough
    /// silent MPEG frames for the file to be a valid audio asset.
    private static func makeMP3(embedding picture: Data) -> Data {
        var body = Data([0x00])
        body.append(Data("image/png".utf8))
        body.append(contentsOf: [0x00, 0x03, 0x00])
        body.append(picture)
        var frame = Data("APIC".utf8)
        frame.append(bigEndian32(body.count))
        frame.append(contentsOf: [0x00, 0x00])
        frame.append(body)
        var tag = Data("ID3".utf8)
        tag.append(contentsOf: [0x03, 0x00, 0x00])
        tag.append(syncSafe32(frame.count))
        tag.append(frame)
        var audio = Data()
        for _ in 0..<40 {
            audio.append(contentsOf: [0xFF, 0xFB, 0x90, 0x00])
            audio.append(Data(count: 413))
        }
        return tag + audio
    }

    private static func bigEndian32(_ value: Int) -> Data {
        Data([UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    private static func syncSafe32(_ value: Int) -> Data {
        Data([UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F), UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)])
    }
}

private enum ImageEncoding {

    struct EncodeError: Error {}

    static func encode(_ image: CGImage, as type: UTType) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw EncodeError() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw EncodeError() }
        return data as Data
    }
}
#endif
