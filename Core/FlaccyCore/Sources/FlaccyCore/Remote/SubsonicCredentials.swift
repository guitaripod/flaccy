import Foundation

/// How a client proves who it is to a Subsonic server: an OpenSubsonic API key, or a
/// username with its password, sent as a salted MD5 token so the password itself never
/// appears in a URL.
public enum SubsonicCredentials: Equatable, Sendable, Codable {
    case apiKey(String)
    case password(username: String, password: String)
}
