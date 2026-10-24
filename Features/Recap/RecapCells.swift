import ImageIO
import MidgarCore
import UIKit

/// A remote-artwork lookup for a Recap chart entry that has no local match and no
/// artwork URL of its own. Resolved once against Last.fm, then cached.
nonisolated enum RecapArtworkQuery: Sendable, Hashable {
    case album(artist: String, album: String)
    case track(artist: String, track: String)

    var cacheKey: String {
        switch self {
        case let .album(artist, album): "album\u{0}\(artist)\u{0}\(album)"
        case let .track(artist, track): "track\u{0}\(artist)\u{0}\(track)"
        }
    }
}

/// Shared number formatting: grouped counts and a compact minutes-to-hours label.
nonisolated enum RecapFormat {
    static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    static func count(_ value: Int) -> String {
        decimalFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func compact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: String(localized: "%.1fM"), Double(value) / 1_000_000) }
        if value >= 10_000 { return String(format: String(localized: "%.0fK"), Double(value) / 1_000) }
        if value >= 1_000 { return String(format: String(localized: "%.1fK"), Double(value) / 1_000) }
        return "\(value)"
    }
}

func recapCard(cornerRadius: CGFloat = 22) -> UIView {
    let card = UIView()
    if UIAccessibility.isReduceTransparencyEnabled {
        card.backgroundColor = UIColor.white.withAlphaComponent(0.1)
    } else {
        card.backgroundColor = UIColor.white.withAlphaComponent(0.06)
    }
    card.layer.cornerRadius = cornerRadius
    card.layer.cornerCurve = .continuous
    card.layer.borderWidth = 0.5
    card.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
    return card
}
