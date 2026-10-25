import FlaccyCore
import UIKit

/// An album in Recently Added: cover, title, artist, and a quality badge only
/// when the album is a hi-res master.
final class HomeAlbumCardCell: UICollectionViewCell {

    static let reuseID = "HomeAlbumCardCell"
    static let artSide: CGFloat = 136

    private let art = HomeArtView(cornerRadius: 10, showsShadow: false)
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let badge = QualityBadgeView(size: .compact)
    private let badgeHolder = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        art.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .scaled(.subheadline, size: 14, weight: .semibold)
        titleLabel.numberOfLines = 1
        artistLabel.font = .scaled(.caption1, size: 12, weight: .regular)
        artistLabel.textColor = .secondaryLabel
        artistLabel.numberOfLines = 1
        titleLabel.adjustsFontForContentSizeCategory = true
        artistLabel.adjustsFontForContentSizeCategory = true
        badgeHolder.axis = .horizontal
        badgeHolder.addArrangedSubview(badge)
        badgeHolder.addArrangedSubview(UIView())

        let stack = UIStackView(arrangedSubviews: [art, titleLabel, artistLabel, badgeHolder])
        stack.axis = .vertical
        stack.spacing = 2
        stack.setCustomSpacing(8, after: art)
        stack.setCustomSpacing(4, after: artistLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            art.widthAnchor.constraint(equalToConstant: Self.artSide),
            art.heightAnchor.constraint(equalToConstant: Self.artSide),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        art.reset()
    }

    func configure(with album: Album) {
        titleLabel.text = album.title
        artistLabel.text = album.artist
        art.show(albums: [album])
        let representative = album.highResolutionRepresentative
        badge.configure(with: representative)
        badgeHolder.isHidden = representative == nil
        accessibilityLabel = representative.flatMap(\.qualityBadge).map { "\(album.title), \(album.artist), \($0)" }
            ?? "\(album.title), \(album.artist)"
    }
}
