import CryptoKit
import FlaccyCore
import Foundation

/// Reads the two facts a scan keeps about a song's file: the cheap signature
/// that says whether it moved, and the fingerprint of its audio that says
/// whether the song itself changed. `AudioPayload` picks the bytes, so a tag
/// edit leaves the fingerprint alone and a re-export does not.
nonisolated enum AudioFingerprinter {

    private static let chunkSize = 1_024 * 1_024

    /// Byte size and modification time in milliseconds, nil when the file cannot be statted.
    static func signature(of url: URL) -> FileSignature? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let modified = values.contentModificationDate
        else { return nil }
        return FileSignature(
            size: Int64(size),
            modifiedMilliseconds: Int64((modified.timeIntervalSince1970 * 1_000).rounded(.down))
        )
    }

    /// `flac:` plus the STREAMINFO MD5 when the file carries one, otherwise
    /// `sha256:` plus the hash of its audio payload, streamed in 1 MiB chunks.
    /// Nil when the file cannot be read or holds no audio bytes at all.
    static func fingerprint(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return nil }
        let reader = RangeReader(handle: handle)
        let location = AudioPayload.locate(fileSize: Int64(fileSize)) { offset, length in
            reader.read(at: offset, length: length)
        }
        switch location {
        case .flacMD5:
            return TrackRevision.fingerprint(of: location, sha256Hex: nil)
        case .ranges(let ranges):
            return TrackRevision.fingerprint(of: location, sha256Hex: sha256Hex(of: ranges, reader: reader))
        }
    }

    private static func sha256Hex(of ranges: [Range<Int64>], reader: RangeReader) -> String? {
        var hasher = SHA256()
        var hashed: Int64 = 0
        for range in ranges {
            var offset = range.lowerBound
            while offset < range.upperBound {
                let length = Int(min(Int64(chunkSize), range.upperBound - offset))
                let chunk = reader.read(at: offset, length: length)
                guard chunk.count == length else { return nil }
                hasher.update(data: chunk)
                offset += Int64(length)
                hashed += Int64(length)
            }
        }
        guard hashed > 0 else { return nil }
        return hasher.finalize().reduce(into: "") { $0 += String(format: "%02x", $1) }
    }

    /// Seeks and reads on one handle; the callers read one file from one thread.
    private final class RangeReader {
        private let handle: FileHandle

        init(handle: FileHandle) {
            self.handle = handle
        }

        func read(at offset: Int64, length: Int) -> [UInt8] {
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
                  let data = try? handle.read(upToCount: length)
            else { return [] }
            return [UInt8](data)
        }
    }
}
