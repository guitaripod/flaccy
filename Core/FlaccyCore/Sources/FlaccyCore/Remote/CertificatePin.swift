import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// A Flaccy Server that shares on the local network answers over TLS with a self-signed certificate. Clients trust it by
/// its key, never by a certificate authority: the pin is the SHA-256 of the uncompressed public key point, written as
/// unpadded base64url. The server can issue new certificates for the same key without breaking a pin.
///
/// Mirrored in Rust as `linux/library/src/remote/certificate_pin.rs`.
public enum CertificatePin {

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    #if canImport(CryptoKit)
    /// The pin of a raw public key: what `SecKeyCopyExternalRepresentation` gives for the server's EC key.
    public static func pin(ofPublicKey raw: Data) -> String {
        base64url(Data(SHA256.hash(data: raw)))
    }
    #endif

    /// Whether two pins name the same key; surrounding whitespace is ignored and an empty pin matches nothing.
    public static func matches(_ expected: String, _ actual: String) -> Bool {
        let trimmed = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed == actual.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Unpadded base64url, as the pin is written.
    public static func base64url(_ bytes: Data) -> String {
        var text = ""
        let values = [UInt8](bytes)
        var index = 0
        while index < values.count {
            let chunk = values[index..<min(index + 3, values.count)]
            var value: UInt32 = 0
            for (offset, byte) in chunk.enumerated() {
                value |= UInt32(byte) << (16 - 8 * offset)
            }
            for symbol in 0...chunk.count {
                text.append(alphabet[Int((value >> (18 - 6 * symbol)) & 0x3f)])
            }
            index += 3
        }
        return text
    }
}
