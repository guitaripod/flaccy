import AppKit
import UserNotifications

enum RecapNotificationFrequency: String, CaseIterable {
    case off
    case weekly
    case monthly

    var displayName: String {
        switch self {
        case .off: "Off"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        }
    }
}

/// macOS port of the iOS RecapNotificationScheduler (which is UIKit-bound via
/// its story renderer): identical UserDefaults keys and scheduling semantics,
/// with the story attachment rendered through the CoreGraphics
/// StoryCardRenderer instead of a UIKit view.
final class MacRecapNotificationScheduler {

    static let shared = MacRecapNotificationScheduler()

    static let destinationUserInfoKey = "recap.destination"
    static let yearInMusicDestination = "yearInMusic"

    private static let frequencyKey = "recap.notificationFrequency"
    private static let hourKey = "recap.notificationHour"
    private static let minuteKey = "recap.notificationMinute"
    private static let weekdayKey = "recap.notificationWeekday"
    private static let monthDayKey = "recap.notificationMonthDay"
    private static let lastRefreshKey = "recap.lastScheduleRefresh"
    private static let periodicIdentifier = "recap.periodic"
    private static let yearlyIdentifier = "recap.yearly"
    private static let refreshInterval: TimeInterval = 6 * 3600

    private let center = UNUserNotificationCenter.current()

    private init() {}

    var frequency: RecapNotificationFrequency {
        RecapNotificationFrequency(rawValue: UserDefaults.standard.string(forKey: Self.frequencyKey) ?? "") ?? .off
    }

    var deliveryHour: Int {
        get { UserDefaults.standard.object(forKey: Self.hourKey) as? Int ?? 19 }
        set { UserDefaults.standard.set(newValue, forKey: Self.hourKey) }
    }

    var deliveryMinute: Int {
        get { UserDefaults.standard.object(forKey: Self.minuteKey) as? Int ?? 0 }
        set { UserDefaults.standard.set(newValue, forKey: Self.minuteKey) }
    }

    var weeklyWeekday: Int {
        get { UserDefaults.standard.object(forKey: Self.weekdayKey) as? Int ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: Self.weekdayKey) }
    }

    var monthlyDay: Int {
        get { UserDefaults.standard.object(forKey: Self.monthDayKey) as? Int ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: Self.monthDayKey) }
    }

    func nextDeliveryDate() -> Date? {
        nextPeriodicDate(frequency: frequency)
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Persists the chosen cadence, requesting permission when turning on.
    /// Returns false when permission is denied.
    func setFrequency(_ frequency: RecapNotificationFrequency) async -> Bool {
        UserDefaults.standard.set(frequency.rawValue, forKey: Self.frequencyKey)
        guard frequency != .off else {
            center.removePendingNotificationRequests(withIdentifiers: [Self.periodicIdentifier, Self.yearlyIdentifier])
            AppLogger.info("Recap notifications turned off", category: .general)
            return true
        }
        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            AppLogger.error("Notification authorization failed: \(error.localizedDescription)", category: .general)
            granted = false
        }
        guard granted else {
            AppLogger.warning("Recap notifications enabled but permission denied", category: .general)
            return false
        }
        await refreshSchedule(force: true)
        return true
    }

    /// Rebuilds pending notifications with current stats; debounced so routine
    /// activations cost a single settings check.
    func refreshSchedule(force: Bool = false) async {
        let frequency = frequency
        guard frequency != .off else {
            center.removePendingNotificationRequests(withIdentifiers: [Self.periodicIdentifier, Self.yearlyIdentifier])
            return
        }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        if !force,
           let lastRefresh = UserDefaults.standard.object(forKey: Self.lastRefreshKey) as? Date,
           Date().timeIntervalSince(lastRefresh) < Self.refreshInterval,
           await hasPendingRequests() {
            return
        }

        center.removePendingNotificationRequests(withIdentifiers: [Self.periodicIdentifier, Self.yearlyIdentifier])
        let yearData = await computeYearData()
        let storyPNG = makeStoryPNG(data: yearData)
        await schedulePeriodic(frequency: frequency, storyPNG: storyPNG)
        await scheduleYearly(storyPNG: storyPNG)
        UserDefaults.standard.set(Date(), forKey: Self.lastRefreshKey)
    }

    /// The full-year scrobble fetch and aggregation run off the main actor;
    /// only the cheap library-duration snapshot is gathered here.
    private func computeYearData() async -> YearInMusicData {
        let year = Calendar.current.component(.year, from: Date())
        var durations: [String: Int] = [:]
        for track in Library.shared.allTracks where track.duration > 0 {
            durations[LastFMStatsService.trackKey(track.title, track.artist)] = Int(track.duration)
        }
        let snapshot = durations
        return await Task.detached(priority: .utility) {
            YearInMusicService.shared.compute(year: year, libraryDurations: snapshot)
        }.value
    }

    private func hasPendingRequests() async -> Bool {
        let pending = await center.pendingNotificationRequests()
        return pending.contains { $0.identifier == Self.periodicIdentifier || $0.identifier == Self.yearlyIdentifier }
    }

    private func schedulePeriodic(frequency: RecapNotificationFrequency, storyPNG: Data?) async {
        guard frequency != .off, let fireDate = nextPeriodicDate(frequency: frequency) else { return }
        let content = UNMutableNotificationContent()
        switch frequency {
        case .monthly:
            content.title = "Your Monthly Recap 🎧"
            content.body = await teaserBody(period: .month, fallback: "A whole month of listening, wrapped up and ready.")
        case .weekly, .off:
            content.title = "Your Weekly Recap 🎧"
            content.body = await teaserBody(period: .week, fallback: "Seven days of listening, wrapped up and ready.")
        }
        content.sound = .default
        content.userInfo = [Self.destinationUserInfoKey: Self.yearInMusicDestination]
        if let attachment = makeStoryAttachment(pngData: storyPNG) {
            content.attachments = [attachment]
        }
        await schedule(content: content, identifier: Self.periodicIdentifier, at: fireDate)
    }

    private func scheduleYearly(storyPNG: Data?) async {
        guard let fireDate = nextYearlyDeliveryDate() else { return }
        let year = Calendar.current.component(.year, from: fireDate)
        let content = UNMutableNotificationContent()
        content.title = "Your \(year) Year in Music is here ✨"
        content.body = "Minutes, top artists, obsessions — your whole year, ready to share."
        content.sound = .default
        content.userInfo = [Self.destinationUserInfoKey: Self.yearInMusicDestination]
        if let attachment = makeStoryAttachment(pngData: storyPNG) {
            content.attachments = [attachment]
        }
        await schedule(content: content, identifier: Self.yearlyIdentifier, at: fireDate)
    }

    private func nextYearlyDeliveryDate() -> Date? {
        let calendar = Calendar.current
        let now = Date()
        var components = DateComponents(month: 12, day: 1, hour: 17)
        components.year = calendar.component(.year, from: now)
        guard var fireDate = calendar.date(from: components) else { return nil }
        if fireDate <= now {
            components.year = (components.year ?? 0) + 1
            guard let next = calendar.date(from: components) else { return nil }
            fireDate = next
        }
        return fireDate
    }

    private func teaserBody(period: ChartPeriod, fallback: String) async -> String {
        let cutoff = period.cutoffDate
        let rows = await Task.detached(priority: .utility) {
            (try? DatabaseManager.shared.fetchScrobbleRows(from: cutoff, to: Date())) ?? []
        }.value
        var counts: [String: Int] = [:]
        for row in rows { counts[row.artist, default: 0] += 1 }
        guard let topArtist = counts.max(by: { $0.value < $1.value })?.key else { return fallback }
        return "\(topArtist) has been on repeat — \(RecapFormat.count(rows.count)) plays and counting. See your recap."
    }

    /// Renders the shared story card once per refresh; the periodic and
    /// yearly requests each get their own file copy because the notification
    /// store takes ownership of an attachment's file.
    private func makeStoryPNG(data: YearInMusicData) -> Data? {
        guard data.hasContent else { return nil }
        let artwork = StoryArtwork.resolve(for: data)
        let seed = data.topArtists.first.map { "\($0.name)\(data.year)" } ?? "flaccy\(data.year)"
        let theme = StoryTheme.all(seedPalette: ArtworkPaletteExtractor.fallbackPalette(seed: seed))[0]
        guard let image = StoryCardRenderer.makeImage(
            slide: .overview, data: data, artwork: artwork, theme: theme, scale: 2
        ) else { return nil }
        return image.pngData()
    }

    private func makeStoryAttachment(pngData: Data?) -> UNNotificationAttachment? {
        guard let pngData else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recap-notification-\(UUID().uuidString)")
            .appendingPathExtension("png")
        do {
            try pngData.write(to: url)
            return try UNNotificationAttachment(identifier: "recap.story", url: url)
        } catch {
            AppLogger.error("Recap notification attachment failed: \(error.localizedDescription)", category: .general)
            return nil
        }
    }

    private func nextPeriodicDate(frequency: RecapNotificationFrequency) -> Date? {
        let calendar = Calendar.current
        let now = Date()
        switch frequency {
        case .weekly:
            let components = DateComponents(hour: deliveryHour, minute: deliveryMinute, weekday: weeklyWeekday)
            return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
        case .monthly:
            let components = DateComponents(day: monthlyDay, hour: deliveryHour, minute: deliveryMinute)
            return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
        case .off:
            return nil
        }
    }

    private func schedule(content: UNNotificationContent, identifier: String, at date: Date) async {
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        do {
            try await center.add(request)
            AppLogger.info("Scheduled \(identifier) notification for \(date)", category: .general)
        } catch {
            AppLogger.error("Scheduling \(identifier) failed: \(error.localizedDescription)", category: .general)
        }
    }
}
