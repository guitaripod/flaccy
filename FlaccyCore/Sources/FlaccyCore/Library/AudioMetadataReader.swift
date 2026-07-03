import AVFoundation
import Foundation

/// Reads embedded metadata + duration from an audio file using AVFoundation.
/// Cross-platform (iOS + watchOS); artwork is returned as raw `Data`.
public enum AudioMetadataReader {

    public struct Result: Sendable {
        public let title: String?
        public let artist: String?
        public let albumTitle: String?
        public let trackNumber: Int
        public let duration: TimeInterval
        public let artworkData: Data?
    }

    public static func read(from url: URL) async -> Result {
        let asset = AVURLAsset(url: url)
        let duration: TimeInterval
        let metadata: [AVMetadataItem]

        do {
            let loaded = try await asset.load(.duration, .metadata)
            duration = CMTimeGetSeconds(loaded.0)
            metadata = loaded.1
        } catch {
            AppLogger.error("Metadata load failed for \(url.lastPathComponent): \(error.localizedDescription)", category: .content)
            return Result(title: nil, artist: nil, albumTitle: nil, trackNumber: 0, duration: 0, artworkData: nil)
        }

        async let titleTask = stringValue(for: .commonIdentifierTitle, in: metadata)
        async let artistTask = stringValue(for: .commonIdentifierArtist, in: metadata)
        async let albumTask = stringValue(for: .commonIdentifierAlbumName, in: metadata)
        async let trackTask = trackNumberValue(from: metadata)
        async let artworkTask = artworkData(from: metadata)

        return Result(
            title: await titleTask,
            artist: await artistTask,
            albumTitle: await albumTask,
            trackNumber: await trackTask,
            duration: duration.isNaN ? 0 : duration,
            artworkData: await artworkTask
        )
    }

    private static func stringValue(
        for identifier: AVMetadataIdentifier,
        in metadata: [AVMetadataItem]
    ) async -> String? {
        let items = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier)
        guard let item = items.first else { return nil }
        let value = try? await item.load(.stringValue)
        return value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trackNumberValue(from metadata: [AVMetadataItem]) async -> Int {
        for item in metadata {
            if let key = item.key as? String, key.uppercased() == "TRACKNUMBER",
               let value = try? await item.load(.stringValue),
               let number = Int(value.components(separatedBy: "/").first ?? value) {
                return number
            }
        }

        let identifiers: [AVMetadataIdentifier] = [.id3MetadataTrackNumber, .iTunesMetadataTrackNumber]
        for identifier in identifiers {
            let items = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier)
            if let item = items.first, let value = try? await item.load(.numberValue) {
                return value.intValue
            }
        }
        return 0
    }

    private static func artworkData(from metadata: [AVMetadataItem]) async -> Data? {
        let items = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork)
        guard let item = items.first else { return nil }
        return try? await item.load(.dataValue)
    }
}
