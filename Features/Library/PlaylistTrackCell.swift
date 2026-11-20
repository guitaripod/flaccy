import FlaccyCore
import UIKit

/// A song on a playlist page: its album's cover, the title with its New mix
/// and downloaded chips, the artist and album, and the length. The playing
/// song lights up with moving bars, a song the library no longer has is dimmed
/// and says so, and a suggestion carries an add button instead of a length.
final class PlaylistTrackCell: UITableViewCell {

    static let reuseID = "PlaylistTrackCell"
    static let artworkSide: CGFloat = 44

    private let artworkView = UIImageView()
    private let titleLabel = UILabel()
    private lazy var titleRow = TitleWithChipView(titleLabel: titleLabel)
    private let subtitleLabel = UILabel()
    private let durationLabel = UILabel()
    private let barsView = NowPlayingBarsView()
    private let barsBackdrop = UIView()
    private let addButton = UIButton(type: .system)
    private var artworkKey: String?

    var onAdd: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear

        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.layer.cornerRadius = 6
        artworkView.layer.cornerCurve = .continuous
        artworkView.backgroundColor = .tertiarySystemFill
        artworkView.tintColor = .secondaryLabel
        artworkView.translatesAutoresizingMaskIntoConstraints = false

        barsView.tintColor = .white
        barsView.isHidden = true
        barsView.translatesAutoresizingMaskIntoConstraints = false
        barsBackdrop.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        barsBackdrop.isUserInteractionEnabled = false
        barsBackdrop.translatesAutoresizingMaskIntoConstraints = false
        artworkView.addSubview(barsBackdrop)
        artworkView.addSubview(barsView)

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true

        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel

        durationLabel.font = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 13, weight: .regular))
        durationLabel.adjustsFontForContentSizeCategory = true
        durationLabel.textColor = .tertiaryLabel
        durationLabel.textAlignment = .right
        durationLabel.setContentHuggingPriority(.required, for: .horizontal)
        durationLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        var add = UIButton.Configuration.plain()
        add.image = UIImage(systemName: "plus.circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular))
        addButton.configuration = add
        addButton.tintColor = .tintColor
        addButton.isHidden = true
        addButton.addAction(UIAction { [weak self] _ in self?.onAdd?() }, for: .touchUpInside)
        addButton.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            addButton.widthAnchor.constraint(equalToConstant: 44),
            addButton.heightAnchor.constraint(equalToConstant: 44),
        ])

        let text = UIStackView(arrangedSubviews: [titleRow, subtitleLabel])
        text.axis = .vertical
        text.spacing = 2

        let row = UIStackView(arrangedSubviews: [artworkView, text, durationLabel, addButton])
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)

        NSLayoutConstraint.activate([
            artworkView.widthAnchor.constraint(equalToConstant: Self.artworkSide),
            artworkView.heightAnchor.constraint(equalToConstant: Self.artworkSide),
            barsBackdrop.topAnchor.constraint(equalTo: artworkView.topAnchor),
            barsBackdrop.leadingAnchor.constraint(equalTo: artworkView.leadingAnchor),
            barsBackdrop.trailingAnchor.constraint(equalTo: artworkView.trailingAnchor),
            barsBackdrop.bottomAnchor.constraint(equalTo: artworkView.bottomAnchor),
            barsView.centerXAnchor.constraint(equalTo: artworkView.centerXAnchor),
            barsView.centerYAnchor.constraint(equalTo: artworkView.centerYAnchor),
            barsView.widthAnchor.constraint(equalToConstant: 16),
            barsView.heightAnchor.constraint(equalToConstant: 16),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        ])
        barsBackdrop.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkKey = nil
        onAdd = nil
        artworkView.image = nil
    }

    /// A song the library has. `isSuggestion` swaps the length for an add
    /// button; `isPlaying` lights the row up.
    func configure(with track: Track, isCurrent: Bool, isPlaying: Bool, isSuggestion: Bool = false) {
        titleLabel.text = track.title
        let album = track.albumTitle.trimmingCharacters(in: .whitespaces)
        subtitleLabel.text = album.isEmpty ? track.artist : "\(track.artist) · \(album)"
        let newMix = track.showsNewMix
        let downloaded = track.isDownloadedRemote
        titleRow.setNewMix(newMix)
        titleRow.setDownloaded(downloaded)
        let total = Int(track.duration)
        durationLabel.text = String(format: "%d:%02d", total / 60, total % 60)
        durationLabel.isHidden = isSuggestion
        addButton.isHidden = !isSuggestion
        addButton.accessibilityLabel = PlaylistCopy.addSuggestion(track.title)
        titleLabel.textColor = isCurrent ? .tintColor : .label
        barsView.isHidden = !isCurrent
        barsBackdrop.isHidden = !isCurrent
        barsView.setAnimating(isCurrent && isPlaying)
        contentView.alpha = track.isUnavailableOffline ? 0.45 : 1
        accessibilityLabel = TrackVersionCopy.accessibilityLabel(
            "\(track.title), \(track.artist)", newMix: newMix, downloaded: downloaded
        )
        accessibilityValue = isCurrent ? String(localized: "Now playing") : nil
        accessibilityTraits = isCurrent ? [.button, .selected] : .button
        loadArtwork(for: track)
    }

    /// A song the playlist still names but the library no longer has: its
    /// file name, dimmed, so it can be found and taken out.
    func configureMissing(file: String) {
        let name = (file as NSString).lastPathComponent
        titleLabel.text = (name as NSString).deletingPathExtension
        subtitleLabel.text = PlaylistCopy.missingSong
        titleRow.setNewMix(false)
        titleRow.setDownloaded(false)
        durationLabel.text = nil
        durationLabel.isHidden = true
        addButton.isHidden = true
        titleLabel.textColor = .secondaryLabel
        barsView.isHidden = true
        barsBackdrop.isHidden = true
        barsView.setAnimating(false)
        contentView.alpha = 0.45
        artworkKey = nil
        artworkView.contentMode = .center
        artworkView.image = UIImage(systemName: "questionmark")
        accessibilityLabel = "\(titleLabel.text ?? ""), \(PlaylistCopy.missingSong)"
        accessibilityValue = nil
        accessibilityTraits = .staticText
    }

    private func loadArtwork(for track: Track) {
        let key = track.albumTitle + "\u{0}" + track.artist
        guard key != artworkKey || artworkView.image == nil else { return }
        artworkKey = key
        if let cached = AlbumArtworkCache.shared.thumbnail(forAlbum: track.albumTitle, artist: track.artist) {
            showArtwork(cached)
            return
        }
        artworkView.contentMode = .center
        artworkView.image = UIImage(systemName: "music.note")
        AlbumArtworkCache.shared.loadThumbnail(forAlbum: track.albumTitle, artist: track.artist) { [weak self] image in
            guard let self, self.artworkKey == key, let image else { return }
            self.showArtwork(image)
        }
    }

    private func showArtwork(_ image: UIImage) {
        artworkView.contentMode = .scaleAspectFill
        artworkView.image = image
    }
}
