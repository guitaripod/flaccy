import Foundation

/// One control in the player's action row. Raw values are persisted as text,
/// so they never change.
nonisolated enum PlayerAction: String, CaseIterable, Sendable {
    case shuffle
    case repeatMode = "repeat"
    case airplay
    case sleepTimer
    case share
    case lyrics
    case queue
}

/// The person's order of the player's action row. A saved order that misses an
/// action gains it at the end, duplicates keep their first place and unknown
/// identifiers are dropped, so a control added by a later version still shows.
nonisolated struct PlayerActionOrder: Equatable, Sendable {

    static let standard = PlayerActionOrder(actions: PlayerAction.allCases)

    private(set) var actions: [PlayerAction]

    init(actions: [PlayerAction]) {
        self.actions = Self.completed(actions)
    }

    /// Moves the action at `source` to `destination`, clamping both so a drag
    /// past either end lands on it.
    func moving(from source: Int, to destination: Int) -> PlayerActionOrder {
        guard actions.indices.contains(source) else { return self }
        var reordered = actions
        let action = reordered.remove(at: source)
        reordered.insert(action, at: min(max(destination, 0), reordered.count))
        return PlayerActionOrder(actions: reordered)
    }

    var encoded: String {
        actions.map(\.rawValue).joined(separator: ",")
    }

    static func decode(_ text: String?) -> PlayerActionOrder {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .standard
        }
        return PlayerActionOrder(actions: text.split(separator: ",").compactMap {
            PlayerAction(rawValue: $0.trimmingCharacters(in: .whitespaces))
        })
    }

    private static func completed(_ actions: [PlayerAction]) -> [PlayerAction] {
        var seen = Set<PlayerAction>()
        return (actions + PlayerAction.allCases).filter { seen.insert($0).inserted }
    }
}

/// Persists the row's arrangement as `PlayerActionOrder.encoded`, the same
/// kind of text Home keeps for its sections.
@MainActor
final class PlayerActionOrderStore {

    static let shared = PlayerActionOrderStore()

    private let defaultsKey = "flaccy.player.actionOrder"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var order: PlayerActionOrder {
        get { PlayerActionOrder.decode(defaults.string(forKey: defaultsKey)) }
        set {
            guard newValue != order else { return }
            defaults.set(newValue.encoded, forKey: defaultsKey)
        }
    }

    func restoreDefault() {
        order = .standard
    }
}
