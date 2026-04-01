import UIKit

nonisolated struct Track: Sendable, Hashable, Identifiable {

    var id: URL { fileURL }

    let fileURL: URL
    let title: String
    let artist: String
    let albumTitle: String
    let trackNumber: Int
    let duration: TimeInterval
    let artwork: UIImage?
    let dbID: Int64?

    static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.fileURL == rhs.fileURL
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(fileURL)
    }

    static func from(record: TrackRecord, artwork: UIImage?) -> Track {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL
        let absoluteURL = docsDir.appendingPathComponent(record.fileURL)
        return Track(
            fileURL: absoluteURL,
            title: record.title,
            artist: record.artist,
            albumTitle: record.albumTitle,
            trackNumber: record.trackNumber,
            duration: record.duration,
            artwork: artwork,
            dbID: record.id
        )
    }
}
