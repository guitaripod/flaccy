import Foundation

enum GroupAlbumEditionsSetting {
    static let key = "groupAlbumEditions"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    static func set(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key)
        Task { await Library.shared.reloadFromDatabase() }
    }
}
