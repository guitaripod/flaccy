import Foundation

/// The form a song on a server is downloaded in: the original file, or AAC at the bit rate
/// AirPods Pro receive over Bluetooth (256 kbps), or half that for the most songs per gigabyte.
///
/// Mirrored by `linux/shared/src/remote/download_quality.rs`.
public enum RemoteDownloadQuality: String, CaseIterable, Sendable {
    case original
    case aac256
    case aac128

    public static let defaultQuality: RemoteDownloadQuality = .aac256

    /// The server type a Flaccy Server reports in `ping`.
    public static let flaccyServerType = "flaccy-server"

    /// The quality a stored name stands for, the default for a name this version does not know.
    public init(storedName: String?) {
        self = storedName.flatMap(RemoteDownloadQuality.init(rawValue:)) ?? Self.defaultQuality
    }

    public var kbps: Int? {
        switch self {
        case .original: nil
        case .aac256: 256
        case .aac128: 128
        }
    }

    /// The `stream` parameters that ask a server for this quality, nil for the original file.
    /// A Flaccy Server sends a whole m4a, whose edit list keeps songs gapless; other servers
    /// are asked for `aac`, the conversion OpenSubsonic servers commonly offer.
    public func streamParameters(serverType: String?) -> [(String, String)]? {
        guard let kbps else { return nil }
        let format = serverType == Self.flaccyServerType ? "mp4" : "aac"
        return [("format", format), ("maxBitRate", String(kbps))]
    }

    /// The suffix a converted download is stored under, from the response's media type, or nil
    /// when the server sent something other than AAC (it kept the original or converted to
    /// another format), which is then kept as the server's own file.
    public static func convertedSuffix(contentType: String?) -> String? {
        let type = (contentType ?? "").split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        } ?? ""
        switch type {
        case "audio/mp4", "audio/m4a", "audio/x-m4a": return "m4a"
        case "audio/aac", "audio/aacp", "audio/x-aac": return "aac"
        default: return nil
        }
    }
}
