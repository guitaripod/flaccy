import FlaccyCore
import UIKit

/// One row of the Search tab: a small cover (round for an artist), a title and
/// a quiet second line.
final class SearchResultCell: UICollectionViewCell {

    static let reuseID = "SearchResultCell"

    private let coverView = AsyncImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        coverView.translatesAutoresizingMaskIntoConstraints = false
        coverView.layer.cornerCurve = .continuous

        titleLabel.font = .scaled(.body, size: 16, weight: .medium)
        titleLabel.adjustsFontForContentSizeCategory = true
        detailLabel.font = .scaled(.footnote, size: 13, weight: .regular)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel

        let text = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        text.axis = .vertical
        text.spacing = 1

        let row = UIStackView(arrangedSubviews: [coverView, text])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)

        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(separator)

        NSLayoutConstraint.activate([
            coverView.widthAnchor.constraint(equalToConstant: 48),
            coverView.heightAnchor.constraint(equalToConstant: 48),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            separator.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        coverView.token = UUID()
        coverView.image = nil
    }

    func configure(with item: SearchItem) {
        titleLabel.text = item.title
        detailLabel.text = item.detail
        coverView.layer.cornerRadius = item.isRoundCover ? 24 : 8
        coverView.setAlbum(
            title: item.coverTitle,
            artist: item.coverArtist,
            remoteURL: nil,
            placeholder: UIImage(systemName: item.placeholderSymbol)
        )
        coverView.tintColor = .tertiaryLabel
        coverView.contentMode = coverView.image == nil ? .center : .scaleAspectFill
        isAccessibilityElement = true
        accessibilityLabel = item.accessibilityLabel
        accessibilityTraits = .button
    }
}

/// A search result of any kind, hashable by what it is so the diffable data
/// source can move rows instead of replacing them while the query narrows.
nonisolated enum SearchItem: Hashable, Sendable {
    case album(Album)
    case artist(ArtistItem, cover: Album?)
    case song(Track)
    case playlist(PlaylistItem)

    var title: String {
        switch self {
        case .album(let album): album.title
        case .artist(let artist, _): artist.name
        case .song(let track): track.title
        case .playlist(let playlist): playlist.name
        }
    }

    @MainActor var detail: String {
        switch self {
        case .album(let album): album.artist
        case .artist(let artist, _): SearchCopy.albumCount(artist.albumCount, appearances: artist.appearanceCount)
        case .song(let track): "\(track.artist) · \(track.albumTitle)"
        case .playlist(let playlist): HomeCopy.songCount(playlist.trackCount)
        }
    }

    var isRoundCover: Bool {
        if case .artist = self { return true }
        return false
    }

    var coverTitle: String {
        switch self {
        case .album(let album): album.title
        case .artist(_, let cover): cover?.title ?? ""
        case .song(let track): track.albumTitle
        case .playlist: ""
        }
    }

    var coverArtist: String {
        switch self {
        case .album(let album): album.artist
        case .artist(_, let cover): cover?.artist ?? ""
        case .song(let track): track.artist
        case .playlist: ""
        }
    }

    var placeholderSymbol: String {
        switch self {
        case .artist: "person.fill"
        case .playlist: "music.note.list"
        default: "music.note"
        }
    }

    @MainActor var accessibilityLabel: String {
        "\(title), \(detail)"
    }
}

enum SearchCopy {

    static func albumCount(_ albums: Int, appearances: Int) -> String {
        if albums == 0, appearances > 0 { return String(localized: "Appears on \(appearances) albums") }
        return String(localized: "\(albums) albums")
    }

    static var prompt: String { String(localized: "Search Your Library") }
    static var promptDetail: String { String(localized: "Find albums, artists, songs and playlists.") }
}
