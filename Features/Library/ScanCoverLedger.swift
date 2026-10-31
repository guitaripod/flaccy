import Foundation

/// The albums whose cover one scan has already read out of a file.
///
/// The database keeps a single cover per album and strips every other
/// track's picture on insert, so decoding and re-encoding the same embedded
/// image for each of an album's tracks was most of a scan's work on a library
/// with large covers. A track only reads its picture while its album still
/// lacks one; tracks of the same album read at the same moment may both
/// decode it, which costs a little and loses nothing.
nonisolated final class ScanCoverLedger: @unchecked Sendable {

    private let lock = NSLock()
    private var covered = Set<String>()

    func needsCover(albumTitle: String, artist: String) -> Bool {
        let key = Self.key(albumTitle: albumTitle, artist: artist)
        return lock.withLock { !covered.contains(key) }
    }

    func noteCovered(albumTitle: String, artist: String) {
        let key = Self.key(albumTitle: albumTitle, artist: artist)
        _ = lock.withLock { covered.insert(key) }
    }

    /// The same title and artist pair `albumInfo` stores a hoisted cover under.
    private static func key(albumTitle: String, artist: String) -> String {
        "\(albumTitle)\u{0}\(artist)"
    }
}
