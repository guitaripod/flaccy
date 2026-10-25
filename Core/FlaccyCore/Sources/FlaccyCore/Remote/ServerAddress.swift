import Foundation

/// Turns what a person types for a server into the base URL every Subsonic call hangs off.
///
/// A bare host gets `https://`, only `http` and `https` are accepted, and the
/// port and any path prefix are kept. A trailing `/`, a trailing `/rest` and any
/// query or fragment are dropped, because the client appends `/rest/<method>` itself.
///
/// Mirrored in Rust as `linux/shared/src/remote/server_address.rs`.
public enum ServerAddress {

    /// The normalized base URL, or nil when the input is empty, uses another scheme, or has no host.
    public static func normalize(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        components.path = strippedPath(components.path)
        return components.url
    }

    /// Drops trailing slashes, then one trailing `/rest`, then any slashes that remain.
    private static func strippedPath(_ path: String) -> String {
        var result = trimmingTrailingSlashes(path)
        if result.hasSuffix("/rest") {
            result.removeLast("/rest".count)
        }
        return trimmingTrailingSlashes(result)
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var result = path
        while result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}
