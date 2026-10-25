import Foundation
import FlaccyCore

/// The albums, playlists, mixes and radios started on this device, newest
/// first, kept for Home's Jump Back In. Linux keeps the same list in its own
/// config (`home::RecentContexts`).
@MainActor
final class RecentContextStore {

    static let shared = RecentContextStore()
    static let didChange = Notification.Name("com.midgarcorp.flaccy.RecentContextsDidChange")

    private let defaultsKey = "flaccy.home.recentContexts"
    private let defaults: UserDefaults
    private(set) var recents: RecentContexts

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.recents = defaults.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode(RecentContexts.self, from: $0) } ?? RecentContexts()
    }

    func record(_ context: PlaybackContext, at date: Date = Date()) {
        let updated = recents.recording(context, at: date)
        guard updated != recents else { return }
        recents = updated
        persist()
    }

    func remove(key: String) {
        recents = recents.removing(key: key)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(recents) {
            defaults.set(data, forKey: defaultsKey)
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
