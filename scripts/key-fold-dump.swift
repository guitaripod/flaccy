import Foundation

func normalize(_ value: String) -> String {
    let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    var result = String.UnicodeScalarView()
    for scalar in folded.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
        result.append(scalar)
    }
    return String(result)
}

var output = ""
for value in UInt32(0)...UInt32(0x10FFFF) {
    guard let scalar = Unicode.Scalar(value) else { continue }
    let result = normalize(String(scalar))
    if result.isEmpty { continue }
    let hex = result.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: ",")
    output += "\(String(value, radix: 16)) \(hex)\n"
}
FileHandle.standardOutput.write(output.data(using: .utf8)!)
