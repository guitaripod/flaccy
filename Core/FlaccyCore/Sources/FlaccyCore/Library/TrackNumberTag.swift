import Foundation

/// Reads a song's place on its release from the shapes the tag formats store
/// it in. Vorbis comments and ID3 frames hold text such as `7` or `7/12`; an
/// MP4 `trkn` atom holds binary. AVFoundation offers no number for either of
/// the last two, so a reader that asks it for one files every MP3 and M4A at 0.
public enum TrackNumberTag {

    /// The position a text tag names (`7`, `07`, ` 7 / 12 `), or 0 when the
    /// text does not start with a positive number.
    public static func number(fromText text: String) -> Int {
        let position = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let trimmed = position.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value > 0 else { return 0 }
        return value
    }

    /// The position an MP4 `trkn` atom's payload names: two reserved bytes,
    /// then the position and the total as big-endian 16-bit numbers.
    public static func number(fromMP4Pair data: Data) -> Int {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return 0 }
        return Int(bytes[2]) << 8 | Int(bytes[3])
    }
}
