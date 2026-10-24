import Foundation

/// The sixteen built-in curves, as the ten gains a person would read off the
/// sliders. They are starting points tuned by ear, not taken from any other
/// player's tables. Mirrored in Rust as `linux/shared/src/equalizer/presets.rs`
/// and pinned by a test asserting the same numbers.
public enum EqualizerPresets {

    public struct Entry: Equatable, Sendable {
        public let key: String
        public let englishName: String
        public let targets: [Double]
    }

    public static let flatKey = "flat"

    public static let entries: [Entry] = [
        Entry(key: "flat", englishName: "Flat", targets: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        Entry(key: "bassBoost", englishName: "Bass Boost", targets: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        Entry(key: "bassReducer", englishName: "Bass Reducer", targets: [-6, -5, -3, -1, 0, 0, 0, 0, 0, 0]),
        Entry(key: "trebleBoost", englishName: "Treble Boost", targets: [0, 0, 0, 0, 0, 1, 3, 5, 6, 6]),
        Entry(key: "trebleReducer", englishName: "Treble Reducer", targets: [0, 0, 0, 0, 0, 0, -1, -3, -5, -6]),
        Entry(key: "vocal", englishName: "Vocal", targets: [0, 0, -2, -1, 2, 4, 3, 1, 0, 0]),
        Entry(key: "spokenWord", englishName: "Spoken Word", targets: [-4, -3, -1, 0, 3, 4, 4, 2, 0, -2]),
        Entry(key: "soften", englishName: "Soften", targets: [0, 0, 0, 0, 0, -1, -3, -4, -2, 0]),
        Entry(key: "loudness", englishName: "Loudness", targets: [5, 3, 0, 0, 0, 0, 0, 2, 4, 5]),
        Entry(key: "acoustic", englishName: "Acoustic", targets: [3, 3, 2, 1, 0, 1, 2, 3, 3, 2]),
        Entry(key: "classical", englishName: "Classical", targets: [0, 0, 0, 0, -1, -1, 0, 2, 3, 3]),
        Entry(key: "rock", englishName: "Rock", targets: [4, 3, 1, 0, -1, 0, 2, 3, 4, 4]),
        Entry(key: "electronic", englishName: "Electronic", targets: [5, 4, 1, 0, -2, 0, 1, 3, 4, 5]),
        Entry(key: "hipHop", englishName: "Hip-Hop", targets: [6, 5, 2, 1, -1, -1, 1, 0, 1, 2]),
        Entry(key: "jazz", englishName: "Jazz", targets: [3, 2, 1, 2, -1, -1, 0, 1, 2, 3]),
        Entry(key: "pop", englishName: "Pop", targets: [-1, 1, 3, 4, 3, 0, -1, 0, 1, 2]),
    ]

    public static let tuneKeys = ["bassBoost", "bassReducer", "trebleBoost", "trebleReducer", "vocal", "spokenWord", "soften", "loudness"]
    public static let genreKeys = ["acoustic", "classical", "rock", "electronic", "hipHop", "jazz", "pop"]

    public static func id(forKey key: String) -> String {
        "builtin.\(key)"
    }

    public static func key(forID id: String) -> String? {
        id.hasPrefix("builtin.") ? String(id.dropFirst("builtin.".count)) : nil
    }

    public static func profile(forKey key: String) -> EqualizerProfile? {
        entries.first { $0.key == key }.map {
            EqualizerProfile.graphic(id: id(forKey: $0.key), name: $0.englishName, targets: $0.targets)
        }
    }

    public static func profile(forID id: String) -> EqualizerProfile? {
        key(forID: id).flatMap(profile(forKey:))
    }

    public static var flat: EqualizerProfile {
        profile(forKey: flatKey)!
    }

    public static var all: [EqualizerProfile] {
        entries.compactMap { profile(forKey: $0.key) }
    }
}
