import Foundation

/// Builds the URL of one Subsonic REST call. Every client builds the same string for the
/// same inputs, so a call logged or cached on one side can be reproduced on the other.
///
/// The query is the method's own parameters in the order given, then the credentials,
/// then `v`, `c` and `f=json`. Names and values are percent-encoded with the unreserved set.
///
/// Mirrored in Rust as `linux/shared/src/remote/subsonic_request.rs`.
public enum SubsonicRequest {

    public static let apiVersion = "1.16.1"
    public static let clientName = "flaccy"

    /// The REST URL for `method` under `base`. The caller supplies the salt and the MD5 function
    /// so this stays free of any crypto framework; a password token is `md5Hex(password + salt)`.
    public static func url(
        base: URL,
        method: String,
        parameters: [(String, String)],
        credentials: SubsonicCredentials,
        salt: String,
        md5Hex: (String) -> String
    ) -> URL {
        var query = parameters.map { encoded($0.0) + "=" + encoded($0.1) }
        query.append(contentsOf: authentication(credentials: credentials, salt: salt, md5Hex: md5Hex))
        query.append("v=" + apiVersion)
        query.append("c=" + clientName)
        query.append("f=json")
        let string = trimmedBase(base) + "/rest/" + encoded(method) + "?" + query.joined(separator: "&")
        guard let url = URL(string: string) else {
            preconditionFailure("Subsonic request built an invalid URL: \(string)")
        }
        return url
    }

    private static func authentication(
        credentials: SubsonicCredentials,
        salt: String,
        md5Hex: (String) -> String
    ) -> [String] {
        switch credentials {
        case .apiKey(let key):
            return ["apiKey=" + encoded(key)]
        case .password(let username, let password):
            return [
                "u=" + encoded(username),
                "t=" + encoded(md5Hex(password + salt)),
                "s=" + encoded(salt),
            ]
        }
    }

    private static func trimmedBase(_ base: URL) -> String {
        var string = base.absoluteString
        while string.hasSuffix("/") {
            string.removeLast()
        }
        return string
    }

    private static func encoded(_ text: String) -> String {
        PercentEscaping.escape(text)
    }
}
