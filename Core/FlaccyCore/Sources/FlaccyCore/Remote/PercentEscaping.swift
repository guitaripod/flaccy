import Foundation

/// Percent-encoding over the unreserved set `A-Z a-z 0-9 - . _ ~`, shared by Subsonic
/// query strings and remote track paths so both halves of the app escape the same bytes.
enum PercentEscaping {

    /// Escapes every UTF-8 byte outside the unreserved set as `%XX` with uppercase hex digits.
    static func escape(_ text: String) -> String {
        var escaped = ""
        for byte in text.utf8 {
            if isUnreserved(byte) {
                escaped.append(Character(Unicode.Scalar(byte)))
            } else {
                escaped.append("%")
                escaped.append(hexDigit(byte >> 4))
                escaped.append(hexDigit(byte & 0x0F))
            }
        }
        return escaped
    }

    /// Reverses `%XX` escapes; nil when the escapes do not decode to valid UTF-8.
    static func unescape(_ text: String) -> String? {
        text.removingPercentEncoding
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
            return true
        default:
            return false
        }
    }

    private static func hexDigit(_ nibble: UInt8) -> Character {
        Character(Unicode.Scalar(nibble < 10 ? UInt8(ascii: "0") + nibble : UInt8(ascii: "A") + nibble - 10))
    }
}
