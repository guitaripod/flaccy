import Foundation

/// The wording of the line under the Songs table: how many songs are in view
/// and how long they run, or the same for the rows the person has selected.
enum SongsStatusFormat {

    static func summary(count: Int, seconds: TimeInterval) -> String {
        count == 1
            ? String(localized: "1 song · \(duration(seconds))")
            : String(localized: "\(grouped(count)) songs · \(duration(seconds))")
    }

    static func selection(count: Int, seconds: TimeInterval) -> String {
        String(localized: "\(grouped(count)) selected · \(duration(seconds))")
    }

    /// Whole days and hours once past a day, whole hours and minutes once past
    /// an hour, minutes below that; every unit is truncated, never rounded up,
    /// so the line never claims more listening than the list holds.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        if total >= 86_400 {
            return String(localized: "\(total / 86_400) d \(total % 86_400 / 3_600) hr")
        }
        if total >= 3_600 {
            return String(localized: "\(total / 3_600) hr \(total % 3_600 / 60) min")
        }
        return String(localized: "\(total / 60) min")
    }

    private static func grouped(_ count: Int) -> String {
        RecapFormat.count(count)
    }
}
