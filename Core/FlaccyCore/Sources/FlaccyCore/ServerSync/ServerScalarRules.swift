import Foundation

/// Which scalar keys and values Flaccy Server accepts (PROTOCOL.md section 4).
public enum ServerScalarRules {

    public static let maxValueBytes = 64 * 1024
    public static let maxPreferenceBytes = 4 * 1024

    private static let freePrefixes: Set<String> = ["pref", "eq", "want", "lastfm", "offline"]
    private static let songKeyPrefixes: Set<String> = ["lyr", "meta"]

    public static func isValidKey(_ key: String) -> Bool {
        guard let slash = key.firstIndex(of: "/") else { return false }
        let prefix = String(key[..<slash])
        let rest = String(key[key.index(after: slash)...])
        guard !rest.isEmpty else { return false }
        if freePrefixes.contains(prefix) { return true }
        return songKeyPrefixes.contains(prefix) && isSongKey(rest)
    }

    public static func isValid(key: String, value: ServerJSON) -> Bool {
        guard isValidKey(key), let size = value.text?.utf8.count, size <= maxValueBytes else { return false }
        let prefix = key.prefix { $0 != "/" }
        switch prefix {
        case "lyr":
            guard case .int(let milliseconds) = value else { return false }
            return milliseconds >= 0
        case "meta":
            if case .object = value { return true }
            return false
        case "pref":
            return size <= maxPreferenceBytes
        default:
            return true
        }
    }

    public static func isSongKey(_ text: String) -> Bool {
        text.utf8.count == 32 && text.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    public static func lyricsKey(songKey: String) -> String {
        "lyr/\(songKey)"
    }
}
