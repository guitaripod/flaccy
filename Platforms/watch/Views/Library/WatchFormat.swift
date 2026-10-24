import FlaccyCore
import Foundation

/// The wrist's numbers as words: sizes, counts and runtimes, spelled once so
/// the library, the storage screen and VoiceOver can never disagree.
enum WatchFormat {

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    private static let runtimeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    static func bytes(_ count: Int64) -> String {
        byteFormatter.string(fromByteCount: max(0, count))
    }

    static func songs(_ count: Int) -> String {
        count == 1 ? String(localized: "1 song") : String(localized: "\(count) songs")
    }

    static func albums(_ count: Int) -> String {
        count == 1 ? String(localized: "1 album") : String(localized: "\(count) albums")
    }

    static func artists(_ count: Int) -> String {
        count == 1 ? String(localized: "1 artist") : String(localized: "\(count) artists")
    }

    static func runtime(_ interval: TimeInterval) -> String {
        let minutes = max(1, (interval / 60).rounded())
        return runtimeFormatter.string(from: minutes * 60) ?? ""
    }

    static func inventory(albums: Int, songs songCount: Int) -> String {
        "\(Self.albums(albums)) · \(songs(songCount))"
    }
}
