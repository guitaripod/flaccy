/// Playback repeat behavior, shared across platforms.
public enum RepeatMode: String, Sendable, CaseIterable, Codable {
    case off
    case all
    case one

    /// Cycles off → all → one → off.
    public var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}
