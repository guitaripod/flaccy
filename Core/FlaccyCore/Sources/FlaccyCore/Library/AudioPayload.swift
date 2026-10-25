import Foundation

/// Picks the bytes that identify a file's audio, so the same audio is recognised
/// after its tags are rewritten. FLAC carries an MD5 of its decoded samples in
/// its STREAMINFO block; every other container is hashed over its audio payload
/// with the tag blocks around it left out.
///
/// Mirrored in Rust as `linux/shared/src/audio_payload.rs`; both halves are
/// pinned by tests asserting the same locations for the same bytes.
public enum AudioPayload {

    public enum Location: Equatable, Sendable {
        case flacMD5(String)
        case ranges([Range<Int64>])
    }

    /// `read(offset, length)` returns up to `length` bytes starting at `offset`,
    /// fewer only at the end of the file. Formats are recognised by their magic
    /// bytes, never by extension, and anything unreadable falls back to the whole
    /// file so a damaged file is still identified by its content.
    public static func locate(fileSize: Int64, read: (Int64, Int) -> [UInt8]) -> Location {
        guard fileSize > 0 else { return .ranges([]) }
        return withoutActuallyEscaping(read) { escapable in
            Probe(fileSize: fileSize, read: escapable).locate()
        }
    }

    private struct Probe {
        let fileSize: Int64
        let read: (Int64, Int) -> [UInt8]

        var wholeFile: Location {
            .ranges([0..<fileSize])
        }

        func locate() -> Location {
            guard let start = skippingID3v2() else { return wholeFile }
            if has("fLaC", at: start) {
                return flac(at: start)
            }
            if has("RIFF", at: start), has("WAVE", at: start + 8) {
                return chunk(named: "data", from: start + 12, bigEndian: false)
            }
            if has("FORM", at: start), has("AIFF", at: start + 8) || has("AIFC", at: start + 8) {
                return chunk(named: "SSND", from: start + 12, bigEndian: true)
            }
            if has("ftyp", at: start + 4) {
                return mp4(from: start)
            }
            return unknown(from: start)
        }

        /// Skips every leading ID3v2 tag, honouring the footer flag, and reports
        /// nil when the tags run past the end of the file or a header is cut off.
        func skippingID3v2() -> Int64? {
            var start: Int64 = 0
            while has("ID3", at: start) {
                guard let header = bytes(at: start, count: 10) else { return nil }
                let footer: Int64 = (header[5] & 0x10) != 0 ? 10 : 0
                start += 10 + syncsafe(header[6..<10]) + footer
                guard start <= fileSize else { return nil }
            }
            return start
        }

        func flac(at start: Int64) -> Location {
            var offset = start + 4
            var streamMD5: [UInt8]?
            while true {
                guard let header = bytes(at: offset, count: 4) else { return wholeFile }
                let isLast = (header[0] & 0x80) != 0
                let type = header[0] & 0x7F
                let length = Int64(unsigned(header[1..<4], bigEndian: true))
                let dataStart = offset + 4
                guard dataStart + length <= fileSize else { return wholeFile }
                if streamMD5 == nil, type == 0, length >= 34 {
                    streamMD5 = bytes(at: dataStart + 18, count: 16)
                }
                let audioStart = dataStart + length
                if isLast {
                    guard let digest = streamMD5, digest.contains(where: { $0 != 0 }) else {
                        return .ranges([audioStart..<fileSize])
                    }
                    return .flacMD5(hex(digest))
                }
                offset = audioStart
            }
        }

        /// Walks the chunks from `first` for the first chunk named `target`.
        /// RIFF and AIFF share this walk; each chunk is padded to an even length.
        func chunk(named target: String, from first: Int64, bigEndian: Bool) -> Location {
            var offset = first
            while let header = bytes(at: offset, count: 8) {
                let size = Int64(unsigned(header[4..<8], bigEndian: bigEndian))
                let payloadStart = offset + 8
                if header[0..<4].elementsEqual(target.utf8) {
                    return .ranges([payloadStart..<min(payloadStart + size, fileSize)])
                }
                offset = payloadStart + size + (size & 1)
            }
            return wholeFile
        }

        func mp4(from start: Int64) -> Location {
            guard let ranges = mdatRanges(from: start), !ranges.isEmpty else { return wholeFile }
            return .ranges(ranges)
        }

        /// Every top-level `mdat` payload, in file order. A box header cut short
        /// by the end of the file ends the scan and keeps what was found; a box
        /// whose size is smaller than its own header makes the layout unreadable,
        /// reported as nil.
        func mdatRanges(from first: Int64) -> [Range<Int64>]? {
            var offset = first
            var ranges: [Range<Int64>] = []
            while offset < fileSize {
                guard let header = bytes(at: offset, count: 8) else { break }
                let declaresLargeSize = unsigned(header[0..<4], bigEndian: true) == 1
                if declaresLargeSize, bytes(at: offset, count: 16) == nil { break }
                guard let box = boxExtent(at: offset) else { return nil }
                if has("mdat", at: offset + 4) {
                    ranges.append((offset + box.header)..<box.end)
                }
                offset = box.end
            }
            return ranges
        }

        /// The header length and the clamped end of the box at `offset`. Size 0
        /// runs to the end of the file, size 1 reads a 64-bit size, and a size
        /// smaller than its own header is unreadable.
        func boxExtent(at offset: Int64) -> (header: Int64, end: Int64)? {
            guard let header = bytes(at: offset, count: 8) else { return nil }
            let size = unsigned(header[0..<4], bigEndian: true)
            if size == 0 {
                return (8, fileSize)
            }
            if size == 1 {
                guard let large = bytes(at: offset, count: 16) else { return nil }
                let largeSize = unsigned(large[8..<16], bigEndian: true)
                guard largeSize >= 16 else { return nil }
                let end = largeSize > UInt64(fileSize - offset) ? fileSize : offset + Int64(largeSize)
                return (16, end)
            }
            guard size >= 8 else { return nil }
            return (8, min(offset + Int64(size), fileSize))
        }

        /// Without a recognised container the audio is the span between the
        /// ID3v2 tag and any ID3v1 (`TAG`) or APEv2 trailers.
        func unknown(from start: Int64) -> Location {
            var end = fileSize
            if end - start >= 128, has("TAG", at: end - 128) {
                end -= 128
            }
            if end - start >= 32, has("APETAGEX", at: end - 32) {
                guard let size = littleEndian32(at: end - 20), let flags = littleEndian32(at: end - 12) else {
                    return wholeFile
                }
                let footer: Int64 = (flags & 0x8000_0000) != 0 ? 32 : 0
                end = max(0, end - size - footer)
            }
            guard end > start else { return wholeFile }
            return .ranges([start..<end])
        }

        func hex(_ digest: [UInt8]) -> String {
            digest.reduce(into: "") { $0 += ($1 < 16 ? "0" : "") + String($1, radix: 16) }
        }

        func syncsafe(_ bytes: ArraySlice<UInt8>) -> Int64 {
            bytes.reduce(Int64(0)) { $0 << 7 | Int64($1 & 0x7F) }
        }

        func littleEndian32(at offset: Int64) -> Int64? {
            bytes(at: offset, count: 4).map { Int64(unsigned($0, bigEndian: false)) }
        }

        func has(_ text: String, at offset: Int64) -> Bool {
            bytes(at: offset, count: text.utf8.count)?.elementsEqual(text.utf8) ?? false
        }

        /// Exactly `count` bytes at `offset`, or nil when the span is not wholly
        /// inside the file or the reader comes back short.
        func bytes(at offset: Int64, count: Int) -> [UInt8]? {
            guard offset >= 0, offset + Int64(count) <= fileSize else { return nil }
            let result = read(offset, count)
            return result.count == count ? result : nil
        }

        func unsigned<Bytes: Sequence<UInt8>>(_ values: Bytes, bigEndian: Bool) -> UInt64 {
            let ordered = bigEndian ? Array(values) : Array(values.reversed())
            return ordered.reduce(0) { $0 << 8 | UInt64($1) }
        }
    }
}
