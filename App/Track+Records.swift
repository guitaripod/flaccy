import Foundation
import FlaccyCore
import FlaccyEngine

nonisolated extension Track {

    /// Where a stored path points: a song on a server becomes its `flaccy-remote` URL, any other
    /// path is resolved under the library folder.
    static func fileURL(forStoredPath path: String) -> URL {
        if let song = RemoteTrackPath(path: path) { return song.assetURL }
        return LibraryPaths.root.appendingPathComponent(path)
    }

    static func from(record: TrackRecord, artwork: PlatformImage?) -> Track {
        let absoluteURL = fileURL(forStoredPath: record.fileURL)
        return Track(
            fileURL: absoluteURL,
            title: record.title,
            artist: record.artist,
            albumTitle: record.albumTitle,
            albumArtist: record.albumArtist,
            trackNumber: record.trackNumber,
            duration: record.duration,
            artwork: artwork,
            dbID: record.id,
            codec: record.codec,
            bitDepth: record.bitDepth,
            sampleRate: record.sampleRate,
            channels: record.channels,
            loved: record.loved,
            playCount: record.playCount,
            revision: record.revision,
            revisedAt: record.revisedAt,
            fileModifiedMs: record.fileModifiedMs
        )
    }

    static func from(light record: LightTrackRecord, artwork: PlatformImage?) -> Track {
        let absoluteURL = fileURL(forStoredPath: record.fileURL)
        return Track(
            fileURL: absoluteURL,
            title: record.title,
            artist: record.artist,
            albumTitle: record.albumTitle,
            albumArtist: record.albumArtist,
            trackNumber: record.trackNumber,
            duration: record.duration,
            artwork: artwork,
            dbID: record.id,
            codec: record.codec,
            bitDepth: record.bitDepth,
            sampleRate: record.sampleRate,
            channels: record.channels,
            loved: record.loved,
            playCount: record.playCount,
            revision: record.revision,
            revisedAt: record.revisedAt,
            fileModifiedMs: record.fileModifiedMs
        )
    }
}
