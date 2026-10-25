import Foundation
import FlaccyEngine

nonisolated extension Track {

    static func from(record: TrackRecord, artwork: PlatformImage?) -> Track {
        let absoluteURL = LibraryPaths.root.appendingPathComponent(record.fileURL)
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
        let absoluteURL = LibraryPaths.root.appendingPathComponent(record.fileURL)
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
