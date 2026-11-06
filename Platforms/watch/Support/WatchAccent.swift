import FlaccyCore
import Foundation
import Observation

/// The accent picked in the phone's Settings, kept on the wrist so it holds
/// between launches. A view that reads it through `WatchTheme` redraws when the
/// phone sends another.
@MainActor
@Observable
final class WatchAccent {

    static let shared = WatchAccent()

    private(set) var choice: AccentChoice

    private init() {
        choice = AccentChoice(id: UserDefaults.standard.string(forKey: AccentChoice.defaultsKey))
    }

    func adopt(id: String) {
        let next = AccentChoice(id: id)
        guard next != choice else { return }
        choice = next
        UserDefaults.standard.set(next.rawValue, forKey: AccentChoice.defaultsKey)
    }
}
