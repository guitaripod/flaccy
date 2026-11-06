import Foundation

/// The color the app tints its controls, highlights and progress with, chosen
/// in Settings. Blue is the system blue every release before it shipped with;
/// the others carry the Linux client's theme ids and its seed hues (Linux has
/// Adaptive where Apple has Blue). Each comes as a pair: `light` holds at least
/// 4:1 against white, `dark` at least 4.5:1 against the dark grouped background
/// and 3:1 under a white label, the system blue's own margins.
public enum AccentChoice: String, CaseIterable, Sendable {
    case blue
    case rosewater
    case aurora
    case nocturne
    case verdant
    case sunset
    case mono

    public static let defaultsKey = "flaccy.accent"

    /// The choice stored under `id`, or Blue for anything unknown, so an id a
    /// later release adds reads as the default on an older one.
    public init(id: String?) {
        self = id.flatMap(AccentChoice.init(rawValue:)) ?? .blue
    }

    /// 0xRRGGBB for light backgrounds.
    public var light: UInt32 {
        switch self {
        case .blue: 0x007AFF
        case .rosewater: 0xE11D48
        case .aurora: 0x0F766E
        case .nocturne: 0x4F46E5
        case .verdant: 0x047857
        case .sunset: 0xC2410C
        case .mono: 0x52525B
        }
    }

    /// 0xRRGGBB for dark backgrounds.
    public var dark: UInt32 {
        switch self {
        case .blue: 0x0A84FF
        case .rosewater: 0xFF4D6D
        case .aurora: 0x0D9F92
        case .nocturne: 0x7C83FF
        case .verdant: 0x0FA772
        case .sunset: 0xEA6A12
        case .mono: 0x8E8E96
        }
    }
}
