import Foundation

/// Whether the iPad keeps Now Playing as a column beside the library when the
/// window has room for it. Shown unless the person hides it; hidden, the mini
/// player returns and Now Playing opens over the library as on the iPhone.
enum PlayerColumnSetting {

    static let didChange = Notification.Name("PlayerColumnSettingDidChange")

    private static let hiddenKey = "playerColumn.hidden"

    static var isShown: Bool {
        !UserDefaults.standard.bool(forKey: hiddenKey)
    }

    static func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        UserDefaults.standard.set(!shown, forKey: hiddenKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
