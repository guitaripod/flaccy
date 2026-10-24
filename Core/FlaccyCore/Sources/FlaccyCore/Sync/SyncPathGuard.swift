import Foundation

/// Decides whether a relative path received over the wire may be written
/// beneath the watch's Documents folder.
public enum SyncPathGuard {

    /// A safe path is relative, names a file, and stays inside the root:
    /// no `..` component, no leading slash, no NUL. Dots inside names
    /// (`Vol. 1`, `...And Justice`, `a..b`) are ordinary characters.
    public static func isSafe(_ relativePath: String) -> Bool {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasSuffix("/"),
              !relativePath.unicodeScalars.contains("\u{0}")
        else { return false }

        let components = canonicalSyncPath(relativePath).split(separator: "/", omittingEmptySubsequences: true)
        guard let last = components.last, last != "." else { return false }
        return !components.contains("..")
    }
}
