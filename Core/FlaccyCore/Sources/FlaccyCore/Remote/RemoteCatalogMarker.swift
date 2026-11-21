import Foundation

/// Whether a server's library changed since the last catalog sync, told by one `getScanStatus` call instead of
/// listing every song.
///
/// A sync remembers the marker it read just before it listed the songs; a later marker that differs means songs
/// arrived, left or changed there. `lastScan` decides when the server reports it, the song count otherwise, and a
/// server that reports neither is left to the periodic sync.
///
/// Mirrored in Rust as `linux/shared/src/remote/catalog_marker.rs`.
public struct RemoteCatalogMarker: Equatable, Sendable {
    public let lastScan: String?
    public let count: Int64?

    public init(lastScan: String?, count: Int64?) {
        self.lastScan = lastScan
        self.count = count
    }

    /// The marker in a `getScanStatus` answer; a blank `lastScan` counts as absent.
    public init(status: SubsonicResponse.ScanStatus) {
        let trimmed = status.lastScan?.trimmingCharacters(in: .whitespaces)
        self.init(lastScan: trimmed?.isEmpty == false ? trimmed : nil, count: status.count)
    }

    /// Whether the library behind `current` differs from the one `remembered` was read from. With nothing
    /// remembered the answer is yes, so the first probe after an update syncs once.
    public static func changed(remembered: RemoteCatalogMarker?, current: RemoteCatalogMarker) -> Bool {
        guard let remembered else { return true }
        if current.lastScan != nil { return remembered.lastScan != current.lastScan }
        return current.count != nil && remembered.count != current.count
    }

    /// One line for storage: the count, a tab, then `lastScan`.
    public var encoded: String {
        "\(count.map(String.init) ?? "")\t\(lastScan ?? "")"
    }

    /// The marker `encoded` wrote, nil for text it could not have written.
    public init?(encoded text: String) {
        guard let tab = text.firstIndex(of: "\t") else { return nil }
        let countText = text[..<tab]
        let lastScanText = String(text[text.index(after: tab)...])
        let count: Int64?
        if countText.isEmpty {
            count = nil
        } else {
            guard let parsed = Int64(countText) else { return nil }
            count = parsed
        }
        self.init(lastScan: lastScanText.isEmpty ? nil : lastScanText, count: count)
    }
}
