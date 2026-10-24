import Foundation

nonisolated enum HideDuplicateSongsSetting {
    static let key = "hideDuplicateSongs"
    static let didChange = Notification.Name("HideDuplicateSongsDidChange")

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    static func set(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
        NotificationCenter.default.post(name: Library.didUpdateNotification, object: nil)
    }

    /// A pool for stations and suggestions with each song once, so a queue
    /// built from it never plays the same recording twice. Tracks in
    /// `preferring` always survive as the copy of their song, which lets the
    /// caller then exclude them without a hidden twin slipping back in.
    nonisolated static func uniquePool(_ pool: [Track], preferring preferred: [Track] = []) -> [Track] {
        guard isEnabled else { return pool }
        let preferredURLs = Set(preferred.map(\.fileURL))
        return LibraryHygiene.collapsingDuplicateSongs(pool) { preferredURLs.contains($0.fileURL) ? 1 : 0 }.tracks
    }
}
