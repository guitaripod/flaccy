import Foundation

/// The library by the numbers, for the overview at the top of Library settings.
public struct LibraryOverviewTotals: Sendable {
    public var tracks = 0
    public var lossless = 0
    public var hiRes = 0
    public var seconds: Double = 0
    public var localBytes: Int64 = 0
    public var serverTracks = 0
    public var codecs: [(codec: String, tracks: Int)] = []

    public init() {}

    /// The share of songs in lossless formats, 0 for an empty library.
    public var losslessShare: Double {
        tracks == 0 ? 0 : Double(lossless) / Double(tracks)
    }
}
