import FlaccyCore
import Foundation
import MidgarCore

/// Hides what must never reach a log from a line of text: the password token, its salt, a
/// plain password and an API key, wherever they appear as query parameters.
nonisolated enum RemoteLogRedaction {

    static let placeholder = "<redacted>"

    private static let secretParameters = "t|s|p|apiKey|password"

    /// The text with the value of every secret query parameter replaced by a placeholder.
    static func redact(_ text: String) -> String {
        guard let pattern = try? NSRegularExpression(
            pattern: "((?:^|[?&;\\s])(?:\(secretParameters))=)[^&#\\s\"'<>]*",
            options: [.caseInsensitive]
        ) else { return placeholder }
        let range = NSRange(text.startIndex..., in: text)
        return pattern.stringByReplacingMatches(
            in: text, options: [], range: range, withTemplate: "$1\(placeholder)"
        )
    }
}

/// The one way the remote library writes to the log: every line passes the redaction first,
/// so a URL or an error that carries credentials cannot leak them.
nonisolated enum RemoteLog {

    static func info(_ message: String) {
        MidgarLog.info(RemoteLogRedaction.redact(message), category: .remote)
    }

    static func notice(_ message: String) {
        MidgarLog.notice(RemoteLogRedaction.redact(message), category: .remote)
    }

    static func error(_ message: String) {
        MidgarLog.error(RemoteLogRedaction.redact(message), category: .remote)
    }
}
