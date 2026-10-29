import Foundation

/// The enrollment code `flaccy-server enroll` prints, as a person types it: any case, spaces or dashes anywhere, `O` for `0`,
/// `I` or `L` for `1`. The server's alphabet is Crockford base32, which has none of those letters.
public enum EnrollmentCode {

    public static let groupSize = 4

    /// The code as the server expects it: upper case, no separators, look-alike letters read as the digits they stand for.
    public static func normalized(_ typed: String) -> String {
        var result = ""
        for typedCharacter in typed where typedCharacter.isASCII && (typedCharacter.isLetter || typedCharacter.isNumber) {
            let character = Character(typedCharacter.uppercased())
            switch character {
            case "O": result.append("0")
            case "I", "L": result.append("1")
            default: result.append(character)
            }
        }
        return result
    }

    /// The code grouped for the field as it fills: `ABCD-EFGH-JKMN`.
    public static func grouped(_ typed: String) -> String {
        let code = normalized(typed)
        var groups: [String] = []
        var index = code.startIndex
        while index < code.endIndex {
            let end = code.index(index, offsetBy: groupSize, limitedBy: code.endIndex) ?? code.endIndex
            groups.append(String(code[index..<end]))
            index = end
        }
        return groups.joined(separator: "-")
    }
}
