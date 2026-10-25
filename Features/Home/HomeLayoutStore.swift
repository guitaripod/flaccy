import Foundation
import FlaccyCore

/// The person's Home arrangement, persisted as `HomeLayout.encoded` so the
/// text is the same one Linux keeps in its config.
@MainActor
final class HomeLayoutStore {

    static let shared = HomeLayoutStore()
    static let didChange = Notification.Name("com.midgarcorp.flaccy.HomeLayoutDidChange")

    private let defaultsKey = "flaccy.home.layout"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var layout: HomeLayout {
        get { HomeLayout.decode(defaults.string(forKey: defaultsKey)) }
        set {
            guard newValue != layout else { return }
            defaults.set(newValue.encoded, forKey: defaultsKey)
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    func restoreDefault() {
        layout = .standard
    }
}
