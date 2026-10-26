import Foundation

/// UUIDv7 ids, lowercase and hyphenated, for the playlists, entries, devices and instances a client mints.
public enum ServerSyncIDs {

    public static func uuidV7(nowMs: Int64, using generator: inout some RandomNumberGenerator) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let millis = UInt64(max(nowMs, 0)) & 0xFFFF_FFFF_FFFF
        for index in 0..<6 {
            bytes[index] = UInt8((millis >> UInt64(8 * (5 - index))) & 0xFF)
        }
        for index in 6..<16 {
            bytes[index] = UInt8.random(in: 0...255, using: &generator)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x70
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return parts.map(String.init).joined(separator: "-")
    }

    public static func uuidV7(nowMs: Int64) -> String {
        var generator = SystemRandomNumberGenerator()
        return uuidV7(nowMs: nowMs, using: &generator)
    }

    public static func isUUID(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return text.utf8.allSatisfy { $0 == 45 || ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }
}
