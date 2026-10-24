import Foundation

/// The identity of a track across the phone and the watch.
///
/// A track is the same song whatever it is encoded as, so the extension is not
/// part of its identity: a FLAC on the phone and the AAC made from it on the
/// watch share one stem, and the watch holds at most one file per stem.
public enum SyncStem {

    public static let encodedExtension = "m4a"

    /// The canonical relative path without a recognised audio extension.
    public static func of(_ path: String) -> String {
        let canonical = canonicalSyncPath(path)
        let url = URL(fileURLWithPath: canonical)
        guard LibraryScanner.supportedExtensions.contains(url.pathExtension.lowercased()) else { return canonical }
        return String(canonical.dropLast(url.pathExtension.count + 1))
    }

    /// Where a track lands on the watch: its own path when sent as is, the
    /// stem plus the encoded extension when it was transcoded.
    public static func destinationPath(forSource path: String, encoded: Bool) -> String {
        let canonical = canonicalSyncPath(path)
        return encoded ? "\(of(canonical)).\(encodedExtension)" : canonical
    }

    public static func kind(ofExtension fileExtension: String) -> AudioSourceKind {
        switch fileExtension.lowercased() {
        case "flac", "alac", "wav", "aiff", "aif", "caf": .lossless
        case "mp3", "aac": .lossy
        default: .unknown
        }
    }
}
