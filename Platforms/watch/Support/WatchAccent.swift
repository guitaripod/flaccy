import FlaccyCore
import Foundation
import Observation

/// The accent and the theme picked in the phone's Settings, kept on the wrist
/// so they hold between launches. A view that reads them through `WatchTheme`
/// redraws when the phone sends others.
@MainActor
@Observable
final class WatchAccent {

    static let shared = WatchAccent()

    private static let lookKey = "flaccy.theme.watchLook"

    private(set) var choice: AccentChoice
    /// What the watch wears of the phone's theme; nothing until a phone that
    /// knows about themes has said, which leaves the watch's own look.
    private(set) var look: ThemeWatchLook?

    private init() {
        choice = AccentChoice(id: UserDefaults.standard.string(forKey: AccentChoice.defaultsKey))
        look = ThemeWatchLook(encoded: UserDefaults.standard.data(forKey: WatchAccent.lookKey))
        #if DEBUG && targetEnvironment(simulator)
        look = WatchAccent.launchLook ?? look
        #endif
    }

    #if DEBUG && targetEnvironment(simulator)
    /// `FLACCY_THEME=pack[/scheme]` dresses a simulator launch as the phone
    /// would, for captures without a paired phone.
    private static var launchLook: ThemeWatchLook? {
        guard let theme = ProcessInfo.processInfo.environment["FLACCY_THEME"], !theme.isEmpty else { return nil }
        let parts = theme.split(separator: "/").map(String.init)
        let pack = ThemeLibrary().pack(id: parts[0])
        return ThemeWatchLook(look: ThemeLook(pack: pack, choice: .init(pack: pack.id, scheme: parts.count > 1 ? parts[1] : "")))
    }
    #endif

    func adopt(id: String) {
        let next = AccentChoice(id: id)
        guard next != choice else { return }
        choice = next
        UserDefaults.standard.set(next.rawValue, forKey: AccentChoice.defaultsKey)
    }

    func adopt(look next: ThemeWatchLook) {
        guard next != look else { return }
        look = next
        UserDefaults.standard.set(next.encoded, forKey: WatchAccent.lookKey)
    }
}
