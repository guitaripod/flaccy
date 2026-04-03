import UIKit

final class AlbumCell: UICollectionViewCell {

    static let reuseID = "AlbumCell"

    private let artworkView = UIImageView()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let metaLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.layer.cornerRadius = 8
        artworkView.backgroundColor = .tertiarySystemFill
        artworkView.tintColor = .tertiaryLabel
        artworkView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 32, weight: .ultraLight)

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail

        artistLabel.font = .systemFont(ofSize: 12, weight: .regular)
        artistLabel.textColor = .secondaryLabel
        artistLabel.numberOfLines = 1
        artistLabel.lineBreakMode = .byTruncatingTail

        metaLabel.font = .systemFont(ofSize: 10, weight: .regular)
        metaLabel.textColor = .tertiaryLabel
        metaLabel.numberOfLines = 1
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.isHidden = true

        let stack = UIStackView(arrangedSubviews: [artworkView, titleLabel, artistLabel, metaLabel])
        stack.axis = .vertical
        stack.spacing = 6
        stack.setCustomSpacing(4, after: titleLabel)
        stack.setCustomSpacing(2, after: artistLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        let aspectRatio = artworkView.heightAnchor.constraint(equalTo: artworkView.widthAnchor)
        aspectRatio.priority = .defaultHigh

        NSLayoutConstraint.activate([
            aspectRatio,
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with album: Album) {
        titleLabel.text = album.title
        artistLabel.text = album.artist

        if let artwork = album.artwork {
            artworkView.contentMode = .scaleAspectFill
            artworkView.image = artwork
        } else if let cached = AlbumArtworkCache.shared.artwork(forAlbum: album.title, artist: album.artist) {
            artworkView.contentMode = .scaleAspectFill
            artworkView.image = cached
        } else {
            artworkView.contentMode = .center
            artworkView.image = UIImage(systemName: "music.note")
            AlbumArtworkCache.shared.loadArtwork(forAlbum: album.title, artist: album.artist) { [weak self] image in
                guard let self, self.titleLabel.text == album.title else { return }
                if let image {
                    self.artworkView.contentMode = .scaleAspectFill
                    self.artworkView.image = image
                }
            }
        }

        var metaParts: [String] = []
        if let year = album.year, !year.isEmpty { metaParts.append(year) }
        if let genre = album.genre, !genre.isEmpty { metaParts.append(genre) }
        metaLabel.text = metaParts.joined(separator: " \u{00B7} ")
        metaLabel.isHidden = metaParts.isEmpty
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkView.image = nil
        titleLabel.text = nil
        artistLabel.text = nil
        metaLabel.text = nil
        metaLabel.isHidden = true
    }
}
