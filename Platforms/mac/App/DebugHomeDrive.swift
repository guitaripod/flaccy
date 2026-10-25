import MidgarCore
#if DEBUG
import AppKit
import FlaccyCore
import FlaccyEngine

/// Fixtures and the capture script for `--shot-home wide|narrow|playing|dayone|customize|empty`,
/// run next to `--seed-screenshots` (`empty` runs without it, on a library with
/// nothing in it, to capture the first-run card): a paused album queue at track 5 saved
/// last night, a few things to jump back into, plays on today's date in an
/// earlier year and across the last two weeks. `dayone` runs with no history
/// at all (`--no-history` stops the seeder from writing any).
enum DebugHomeDrive {

    static let argument = "--shot-home"
    static let resumeTrackIndex = 4
    static let resumeElapsed: Double = 95

    static var variant: String? {
        DebugDrive.value(after: argument)
    }

    static var wantsHistory: Bool {
        variant != nil && variant != "dayone" && variant != "empty"
    }

    /// Runs before the queue is restored at launch, so the restored queue is
    /// the one written here.
    static func seedIfRequested() {
        if variant == "empty" { OnboardingPanelView.isSuppressedForCapture = true }
        guard wantsHistory else { return }
        let database = DatabaseManager.shared
        guard let records = try? database.fetchAllTracks(), !records.isEmpty else { return }
        seedQueue(from: records)
        seedScrobbles(from: records)
    }

    /// The longest album with at least nine songs, nearest to nine, in track order.
    private static func resumeAlbum(in records: [TrackRecord]) -> [TrackRecord] {
        let albums = Dictionary(grouping: records) { "\($0.albumTitle)\u{0}\($0.artist)" }.values
        let nine = albums.filter { $0.count == 9 }.min { $0[0].albumTitle < $1[0].albumTitle }
        let chosen = nine ?? albums.max { $0.count < $1.count } ?? []
        return chosen.sorted { $0.trackNumber < $1.trackNumber }
    }

    private static func seedQueue(from records: [TrackRecord]) {
        let album = resumeAlbum(in: records)
        guard album.count > resumeTrackIndex else { return }
        let defaults = UserDefaults.standard
        let paths = album.map(\.fileURL)
        defaults.set(paths, forKey: "flaccy.queue.paths")
        defaults.set(resumeTrackIndex, forKey: "flaccy.queue.index")
        defaults.set(paths[resumeTrackIndex], forKey: "flaccy.queue.currentPath")
        defaults.set(resumeElapsed, forKey: "flaccy.queue.elapsed")
        defaults.set(false, forKey: "flaccy.queue.shuffle")
        defaults.removeObject(forKey: "flaccy.queue.originalPaths")
        defaults.set(lastNight().timeIntervalSince1970, forKey: "flaccy.queue.savedAt")
        let context = PlaybackContext(
            kind: .album,
            id: HomeKeys.album(title: album[0].albumTitle, credit: album[0].albumArtist ?? album[0].artist),
            title: album[0].albumTitle,
            subtitle: album[0].albumArtist ?? album[0].artist
        )
        if let data = try? JSONEncoder().encode(context) {
            defaults.set(data, forKey: "flaccy.queue.context")
        }
        MidgarLog.info("DebugHomeDrive: queued \(album[0].albumTitle) at track \(resumeTrackIndex + 1) of \(album.count)", category: .general)
    }

    private static func lastNight() -> Date {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        return calendar.date(bySettingHour: 22, minute: 40, second: 0, of: yesterday) ?? yesterday
    }

    private static func seedScrobbles(from records: [TrackRecord]) {
        let ordered = records.sorted { $0.fileURL < $1.fileURL }
        var rows = memoryPlays(from: ordered) + recentPlays(from: ordered)
        rows.sort { $0.timestamp < $1.timestamp }
        try? DatabaseManager.shared.insertScrobbles(rows)
        MidgarLog.info("DebugHomeDrive: seeded \(rows.count) scrobbles", category: .general)
    }

    private static func row(_ record: TrackRecord, at date: Date) -> ScrobbleRecord {
        ScrobbleRecord(
            trackTitle: record.title, artist: record.artist, albumTitle: record.albumTitle,
            timestamp: date, duration: Int(record.duration), submitted: true
        )
    }

    /// Nine evening plays of one album on today's month and day two years ago.
    private static func memoryPlays(from records: [TrackRecord]) -> [ScrobbleRecord] {
        let calendar = Calendar.current
        let now = Date()
        var parts = calendar.dateComponents([.month, .day], from: now)
        parts.year = calendar.component(.year, from: now) - 2
        parts.hour = 20
        guard let start = calendar.date(from: parts) else { return [] }
        let album = records.filter { $0.albumTitle == "Aurorae" }
        guard !album.isEmpty else { return [] }
        return (0..<9).map { index in
            row(album[index % album.count], at: start.addingTimeInterval(Double(index) * 900))
        }
    }

    /// Fourteen days of listening: 38 plays in the last seven, 22 in the seven
    /// before, today the busiest.
    private static func recentPlays(from records: [TrackRecord]) -> [ScrobbleRecord] {
        let now = Date()
        let perDay = [8, 5, 7, 5, 6, 3, 4, 3, 2, 5, 3, 4, 2, 3]
        var rows: [ScrobbleRecord] = []
        for (day, count) in perDay.enumerated() {
            for slot in 0..<count {
                let record = records[(day * 7 + slot * 5) % records.count]
                let age = Double(day) * 86_400 + Double(slot) * 2_700 + 600
                rows.append(row(record, at: now.addingTimeInterval(-age)))
            }
        }
        return rows
    }

    /// Waits for the library, then gives Jump Back In a playlist, a mix and a
    /// radio to show beside the albums the history already names.
    static func prepare() async {
        var attempts = 0
        while variant != "empty", Library.shared.albums.isEmpty, attempts < 60 {
            try? await Task.sleep(for: .milliseconds(500))
            attempts += 1
        }
        if let name = value(after: "--appearance") {
            NSApp.appearance = NSAppearance(named: name == "light" ? .aqua : .darkAqua)
        }
        guard wantsHistory else { return }
        DebugDrive.seedDemoPlaylists()
        let store = RecentContextStore.shared
        let now = Date()
        if let playlist = (try? DatabaseManager.shared.fetchAllPlaylists())?.first(where: { $0.name == "Night Drive" }),
           let context = playlist.playbackContext {
            store.record(context, at: now.addingTimeInterval(-3 * 3_600))
        }
        let pool = HideDuplicateSongsSetting.uniquePool(Library.shared.allTracks)
        if let mix = SuggestedPlaylistService.build(pool: pool).first {
            store.record(MacHomeActions.context(for: mix), at: now.addingTimeInterval(-5 * 3_600))
        }
        store.record(AudioPlayer.libraryRadioContext, at: now.addingTimeInterval(-9 * 3_600))
        store.record(AudioPlayer.artistRadioContext("Kestrel Vale"), at: now.addingTimeInterval(-27 * 3_600))
    }

    private static func value(after flag: String) -> String? {
        DebugDrive.value(after: flag)
    }

    /// Checks the launch-section choice and the customize sheet's working copy,
    /// logging PASS or FAIL for each expectation.
    static func exercise() {
        let resultsURL = URL(fileURLWithPath: NSTemporaryDirectory() + "home-exercise.txt")
        try? "".write(to: resultsURL, atomically: true, encoding: .utf8)
        func report(_ expectation: String, _ passed: Bool) {
            let line = "HomeExercise \(passed ? "PASS" : "FAIL"): \(expectation)"
            MidgarLog.info(line, category: .general)
            let existing = (try? String(contentsOf: resultsURL, encoding: .utf8)) ?? ""
            try? (existing + line + "\n").write(to: resultsURL, atomically: true, encoding: .utf8)
        }
        guard let defaults = UserDefaults(suiteName: "flaccy.home.exercise") else { return }
        defaults.removePersistentDomain(forName: "flaccy.home.exercise")
        report("a fresh install opens on Home", LaunchSectionSetting.section(in: defaults) == .home)
        LaunchSectionSetting.remember(.songs, in: defaults)
        report("Home stays the launch section while the choice is Home", LaunchSectionSetting.section(in: defaults) == .home)
        LaunchSectionSetting.setChoice(.whereYouLeftOff, in: defaults)
        report("Where you left off opens the remembered section", LaunchSectionSetting.section(in: defaults) == .songs)
        defaults.removeObject(forKey: LaunchSectionSetting.lastSectionKey)
        report("Where you left off with nothing remembered opens Home", LaunchSectionSetting.section(in: defaults) == .home)
        defaults.set("retired", forKey: LaunchSectionSetting.lastSectionKey)
        report("an unknown remembered section opens Home", LaunchSectionSetting.section(in: defaults) == .home)
        report("every section round-trips through its identifier", SidebarSection.allCases.allSatisfy {
            SidebarSection(identifier: $0.identifier) == $0
        })
        report("Home is the first sidebar section", SidebarSection.allCases.first == .home)
        defaults.removePersistentDomain(forName: "flaccy.home.exercise")

        let sheet = MacHomeCustomizeViewController(layout: .standard)
        _ = sheet.view
        sheet.move(from: 0, to: 2)
        report("dragging Continue down two places reorders the working copy",
               sheet.workingLayout.order.prefix(3).elementsEqual([.jumpBackIn, .madeForYou, .resume]))
        report("the saved layout is untouched until Done", HomeLayoutStore.shared.layout == HomeLayout.decode(
            UserDefaults.standard.string(forKey: "flaccy.home.layout")
        ))
        report("a reordered copy is no longer the default", !sheet.workingLayout.isStandard)
    }

    /// The whole script for one variant, ending in the capture.
    static func run(variant: String, window: NSWindow?) async {
        await prepare()
        if variant == "narrow" {
            DebugDrive.resize(window, to: "1000x700")
        }
        if variant == "playing" {
            DebugDrive.startHeroPlayback()
        }
        try? await Task.sleep(for: .seconds(4))
        if variant == "customize" {
            NotificationCenter.default.post(name: .flaccyCustomizeHome, object: nil)
            try? await Task.sleep(for: .seconds(2))
            DebugDrive.captureSheet(of: window, name: "flaccy-shot-home-customize")
            return
        }
        DebugDrive.reassertWindowSizeIfRequested(window)
        if variant == "narrow" { DebugDrive.resize(window, to: "1000x700") }
        try? await Task.sleep(for: .seconds(2))
        if let offset = value(after: "--home-scroll").flatMap(Double.init),
           let home: MacHomeViewController = DebugDrive.findController(in: window?.contentViewController) {
            home.scrollForCapture(to: CGFloat(offset))
            try? await Task.sleep(for: .seconds(1))
        }
        if let target = value(after: "--home-hover"), let content = window?.contentView {
            hover(target, in: content)
            try? await Task.sleep(for: .seconds(1))
        }
        DebugDrive.capture(window: window, name: "flaccy-shot-home-\(variant)")
    }

    /// Puts the pointer, as far as the view can tell, on the first row of Jump
    /// Back In (`jump`), the first Made for You card (`mix`) or the first
    /// Recently Added card (`recent`).
    private static func hover(_ target: String, in root: NSView) {
        switch target {
        case "jump":
            firstView(of: MacHomeJumpRow.self, in: root)?.setHovered(true)
        case "mix":
            firstView(of: MacHomeCard.self, in: root) { $0.side > 150 }?.setHovered(true)
        default:
            firstView(of: MacHomeCard.self, in: root) { $0.side < 150 }?.setHovered(true)
        }
    }

    private static func firstView<T: NSView>(of type: T.Type, in root: NSView, where matches: (T) -> Bool = { _ in true }) -> T? {
        if let view = root as? T, matches(view) { return view }
        for subview in root.subviews {
            if let found = firstView(of: type, in: subview, where: matches) { return found }
        }
        return nil
    }
}
#endif
