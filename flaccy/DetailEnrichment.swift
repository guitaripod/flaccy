import UIKit

/// Glass chips and pills for the album/artist detail headers, matching the
/// app's Liquid Glass language with a Reduce Transparency fallback.
enum DetailChip {

    /// A rounded glass capsule label used for genre tags.
    static func genre(_ text: String) -> UIView {
        pill(text: text, systemImage: nil, accessibilityPrefix: "Genre")
    }

    /// A glass pill carrying an optional leading SF Symbol, sized for header
    /// metadata such as quality badges and genre tags.
    static func pill(text: String, systemImage: String?, accessibilityPrefix: String) -> UIView {
        let label = UILabel()
        label.text = text
        label.font = .scaled(.caption1, size: 12, weight: .semibold)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let content: UIView
        if let systemImage {
            let icon = UIImageView(
                image: UIImage(
                    systemName: systemImage,
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                )
            )
            icon.tintColor = .white
            icon.contentMode = .center
            let row = UIStackView(arrangedSubviews: [icon, label])
            row.axis = .horizontal
            row.spacing = 4
            row.alignment = .center
            content = row
        } else {
            content = label
        }
        content.translatesAutoresizingMaskIntoConstraints = false

        let host = capsuleHost()
        let container = (host as? UIVisualEffectView)?.contentView ?? host
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            host.heightAnchor.constraint(equalToConstant: 30),
        ])
        host.isAccessibilityElement = true
        host.accessibilityLabel = "\(accessibilityPrefix): \(text)"
        return host
    }

    private static func capsuleHost() -> UIView {
        if #available(iOS 26.0, *), !UIAccessibility.isReduceTransparencyEnabled {
            return LiquidGlass.view(cornerRadius: 15)
        }
        let solid = UIView()
        solid.backgroundColor = UIColor.white.withAlphaComponent(0.14)
        solid.layer.cornerRadius = 15
        solid.layer.cornerCurve = .continuous
        solid.clipsToBounds = true
        return solid
    }

    /// A horizontally scrolling row of chips built from the given strings, or a
    /// hidden empty view when there are none.
    static func chipsRow(_ chips: [String]) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.clipsToBounds = false
        let stack = UIStackView(arrangedSubviews: chips.map { genre($0) })
        stack.axis = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        scroll.heightAnchor.constraint(equalToConstant: 30).isActive = true
        scroll.isHidden = chips.isEmpty
        return scroll
    }

    /// The album's peak lossless-first quality badge, derived from the track
    /// with the highest sample rate then bit depth, e.g. "FLAC · 24/96".
    static func albumQualitySummary(tracks: [Track]) -> String? {
        let best = tracks.max { lhs, rhs in
            (lhs.sampleRate ?? 0, lhs.bitDepth ?? 0) < (rhs.sampleRate ?? 0, rhs.bitDepth ?? 0)
        }
        return best?.qualityBadge
    }
}

/// Process-lifetime in-memory memoization for Last.fm detail enrichment so
/// revisiting an album or artist within a session never re-hits the network.
actor DetailEnrichmentCache {

    static let shared = DetailEnrichmentCache()

    private var albumPlayCounts: [String: Int] = [:]
    private var artistTags: [String: [String]] = [:]
    private var popularTracks: [String: [(name: String, playCount: Int, rank: Int)]] = [:]
    private var similarAlbums: [String: [Album]] = [:]

    func albumPlayCount(artist: String, album: String) async -> Int {
        let key = "\(artist.lowercased())\u{0}\(album.lowercased())"
        if let cached = albumPlayCounts[key] { return cached }
        let info = await LastFMService.shared.fetchAlbumInfo(artist: artist, album: album)
        let count = info?.userPlayCount ?? 0
        albumPlayCounts[key] = count
        return count
    }

    func topTags(artist: String) async -> [String] {
        let key = artist.lowercased()
        if let cached = artistTags[key] { return cached }
        let tags = Array(await LastFMService.shared.fetchArtistTopTags(artist: artist).prefix(6))
        artistTags[key] = tags
        return tags
    }

    func topTracks(artist: String, limit: Int) async -> [(name: String, playCount: Int, rank: Int)] {
        let key = artist.lowercased()
        if let cached = popularTracks[key] { return cached }
        let tracks = await LastFMService.shared.fetchArtistTopTracks(artist: artist, limit: limit)
        popularTracks[key] = tracks
        return tracks
    }

    func similarInLibrary(artist: String) async -> [Album] {
        let key = artist.lowercased()
        if let cached = similarAlbums[key] { return cached }
        let albums = await SimilarArtistService.shared.similarInLibrary(toArtist: artist)
        similarAlbums[key] = albums
        return albums
    }
}
