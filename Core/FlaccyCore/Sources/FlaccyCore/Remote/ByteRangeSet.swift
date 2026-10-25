import Foundation

/// The byte ranges of a remote file that are already on disk. Ranges are half-open,
/// kept sorted, and merged whenever they overlap or touch, so a file is complete
/// exactly when one range covers all of it.
///
/// Stored as an array of `[start, end]` pairs.
///
/// Mirrored in Rust as `linux/shared/src/remote/byte_range_set.rs`.
public struct ByteRangeSet: Equatable, Sendable, Codable {

    public private(set) var ranges: [Range<Int64>]

    public init() {
        ranges = []
    }

    /// Adds a range, merging it with every range it overlaps or touches. An empty range changes nothing.
    public mutating func insert(_ range: Range<Int64>) {
        guard !range.isEmpty else { return }
        var merged = range
        var kept: [Range<Int64>] = []
        for existing in ranges {
            if existing.upperBound < merged.lowerBound || existing.lowerBound > merged.upperBound {
                kept.append(existing)
            } else {
                merged = min(existing.lowerBound, merged.lowerBound)..<max(existing.upperBound, merged.upperBound)
            }
        }
        kept.append(merged)
        ranges = kept.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// The parts of `range` that are not yet present, in ascending order.
    public func missing(in range: Range<Int64>) -> [Range<Int64>] {
        guard !range.isEmpty else { return [] }
        var gaps: [Range<Int64>] = []
        var cursor = range.lowerBound
        for existing in ranges where existing.upperBound > cursor && existing.lowerBound < range.upperBound {
            if existing.lowerBound > cursor {
                gaps.append(cursor..<existing.lowerBound)
            }
            cursor = max(cursor, existing.upperBound)
        }
        if cursor < range.upperBound {
            gaps.append(cursor..<range.upperBound)
        }
        return gaps
    }

    /// Whether every byte of `range` is present; an empty range is trivially present.
    public func contains(_ range: Range<Int64>) -> Bool {
        missing(in: range).isEmpty
    }

    /// The number of bytes present across all ranges.
    public var coveredBytes: Int64 {
        ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    /// Whether the whole file of `fileSize` bytes is present.
    public func isComplete(fileSize: Int64) -> Bool {
        fileSize >= 0 && contains(0..<fileSize)
    }

    /// Reads `[[start, end], ...]`; a pair that is not two ordered numbers fails the decode.
    public init(from decoder: Decoder) throws {
        let pairs = try decoder.singleValueContainer().decode([[Int64]].self)
        var set = ByteRangeSet()
        for pair in pairs {
            guard pair.count == 2, pair[0] <= pair[1] else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid byte range")
                )
            }
            set.insert(pair[0]..<pair[1])
        }
        ranges = set.ranges
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(ranges.map { [$0.lowerBound, $0.upperBound] })
    }
}
