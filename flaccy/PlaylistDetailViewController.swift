import UIKit

final class PlaylistDetailViewController: UIViewController, SonglinkShareable {

    private let playlistId: Int64
    private let playlistName: String
    private let audioPlayer: AudioPlaying
    private let db = DatabaseManager.shared
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let reorderFeedback = UISelectionFeedbackGenerator()

    private var tableView: UITableView!
    private var tracks: [Track] = []
    private var playlistTrackRecords: [PlaylistTrackRecord] = []
    private let mosaicView = StackedArtworkMosaicView()
    private var hasAnimatedAppearance = false
    private var hasLoadedOnce = false

    init(playlistId: Int64, playlistName: String, audioPlayer: AudioPlaying = AudioPlayer.shared) {
        self.playlistId = playlistId
        self.playlistName = playlistName
        self.audioPlayer = audioPlayer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        title = playlistName
        navigationItem.rightBarButtonItem = editButtonItem
        setupTableView()
        loadTracks()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadTracks()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        animateHeaderAppearanceIfNeeded()
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView.setEditing(editing, animated: animated)
        if editing { reorderFeedback.prepare() }
    }

    private func setupTableView() {
        tableView = UITableView(frame: .zero, style: .plain)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.register(PlaylistTrackCell.self, forCellReuseIdentifier: PlaylistTrackCell.reuseID)
        tableView.tableHeaderView = buildHeaderView()
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header = tableView.tableHeaderView else { return }
        let targetSize = CGSize(
            width: tableView.bounds.width,
            height: UIView.layoutFittingCompressedSize.height
        )
        let size = header.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        if header.frame.size.height != size.height {
            header.frame.size.height = size.height
            tableView.tableHeaderView = header
        }
    }

    private func buildHeaderView() -> UIView {
        let container = UIView()

        mosaicView.translatesAutoresizingMaskIntoConstraints = false
        mosaicView.isAccessibilityElement = true
        mosaicView.accessibilityLabel = "Playlist artwork"

        let playButton = makeHeaderButton(
            title: "Play",
            systemImage: "play.fill",
            accessibilityLabel: "Play playlist"
        ) { [weak self] in self?.playTapped() }

        let shuffleButton = makeHeaderButton(
            title: "Shuffle",
            systemImage: "shuffle",
            accessibilityLabel: "Shuffle playlist"
        ) { [weak self] in self?.shuffleTapped() }

        let buttonStack = UIStackView(arrangedSubviews: [
            GlassCapsule(hosting: playButton, height: 48),
            GlassCapsule(hosting: shuffleButton, height: 48),
        ])
        buttonStack.axis = .horizontal
        buttonStack.spacing = 12
        buttonStack.distribution = .fillEqually

        let mainStack = UIStackView(arrangedSubviews: [mosaicView, buttonStack])
        mainStack.axis = .vertical
        mainStack.spacing = 24
        mainStack.alignment = .center
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(mainStack)

        let leading = mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32)
        let trailing = mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -32)
        let bottom = mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24)
        leading.priority = .defaultHigh
        trailing.priority = .defaultHigh
        bottom.priority = .defaultHigh

        let buttonWidth = buttonStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
        buttonWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            leading, trailing, bottom,
            buttonWidth,
            mosaicView.widthAnchor.constraint(equalTo: mainStack.widthAnchor, multiplier: 0.62),
            mosaicView.heightAnchor.constraint(equalTo: mosaicView.widthAnchor),
        ])

        return container
    }

    private func makeHeaderButton(
        title: String,
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = UIImage(systemName: systemImage)
        configuration.imagePadding = 6
        configuration.baseForegroundColor = .label
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var updated = attributes
            updated.font = UIFont.preferredFont(forTextStyle: .headline)
            return updated
        }
        let button = UIButton(configuration: configuration)
        button.maximumContentSizeCategory = .accessibilityMedium
        button.accessibilityLabel = accessibilityLabel
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    /// Fades and floats the header in with a spring on first appearance,
    /// skipped entirely under Reduce Motion.
    private func animateHeaderAppearanceIfNeeded() {
        guard !hasAnimatedAppearance else { return }
        hasAnimatedAppearance = true
        guard !UIAccessibility.isReduceMotionEnabled, let header = tableView.tableHeaderView else { return }
        header.alpha = 0
        header.transform = CGAffineTransform(translationX: 0, y: 14)
        let animator = UIViewPropertyAnimator(duration: 0.32, dampingRatio: 0.84) {
            header.alpha = 1
            header.transform = .identity
        }
        animator.startAnimation()
    }

    private func loadTracks() {
        do {
            playlistTrackRecords = try db.fetchPlaylistTracks(playlistId: playlistId)
            let allDBTracks = try db.fetchAllTracks()
            let tracksByURL = Dictionary(allDBTracks.map { ($0.fileURL, $0) }, uniquingKeysWith: { first, _ in first })
            let albumsWithTracks = try db.fetchAlbumsWithTracks()

            var artworkByAlbumKey = [String: UIImage]()
            for (albumInfo, albumTracks) in albumsWithTracks {
                guard let first = albumTracks.first else { continue }
                let key = "\(first.albumTitle)\0\(first.artist)"
                if let data = albumInfo?.coverArtData, let img = UIImage(data: data) {
                    artworkByAlbumKey[key] = img
                } else if let data = first.artworkData, let img = UIImage(data: data) {
                    artworkByAlbumKey[key] = img
                }
            }

            tracks = playlistTrackRecords.compactMap { playlistTrack in
                guard let record = tracksByURL[playlistTrack.trackFileURL] else { return nil }
                let key = "\(record.albumTitle)\0\(record.artist)"
                return Track.from(record: record, artwork: artworkByAlbumKey[key])
            }

            tableView.reloadData()
            updateMosaic()
            hasLoadedOnce = true
        } catch {
            AppLogger.error("Failed to load playlist tracks: \(error.localizedDescription)", category: .database)
        }
    }

    private func updateMosaic() {
        let covers = distinctCovers(limit: 4)
        let apply = { self.mosaicView.setCovers(covers) }
        if hasLoadedOnce, !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(with: mosaicView, duration: 0.3, options: [.transitionCrossDissolve, .beginFromCurrentState], animations: apply)
        } else {
            apply()
        }
        mosaicView.accessibilityLabel = covers.isEmpty
            ? "Playlist artwork placeholder"
            : "Playlist artwork, \(covers.count) album cover\(covers.count == 1 ? "" : "s")"
    }

    private func distinctCovers(limit: Int) -> [UIImage] {
        var seenAlbumKeys = Set<String>()
        var covers: [UIImage] = []
        for track in tracks {
            guard covers.count < limit else { break }
            guard let artwork = track.artwork else { continue }
            let key = "\(track.albumTitle)\0\(track.artist)"
            guard seenAlbumKeys.insert(key).inserted else { continue }
            covers.append(artwork)
        }
        return covers
    }

    private func playTapped() {
        guard !tracks.isEmpty else { return }
        impactMedium.impactOccurred()
        audioPlayer.play(tracks, startingAt: 0)
    }

    private func shuffleTapped() {
        guard !tracks.isEmpty else { return }
        impactMedium.impactOccurred()
        var shuffled = tracks
        shuffled.shuffle()
        audioPlayer.play(shuffled, startingAt: 0)
    }
}

extension PlaylistDetailViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        tracks.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: PlaylistTrackCell.reuseID, for: indexPath) as! PlaylistTrackCell
        cell.configure(with: tracks[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        true
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        let record = playlistTrackRecords[indexPath.row]
        guard let recordId = record.id else { return }

        do {
            try db.removeTrackFromPlaylist(id: recordId)
            playlistTrackRecords.remove(at: indexPath.row)
            tracks.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .automatic)
            updateMosaic()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            AppLogger.error("Failed to remove track from playlist: \(error.localizedDescription)", category: .database)
        }
    }

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        true
    }

    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        let movedTrack = tracks.remove(at: sourceIndexPath.row)
        tracks.insert(movedTrack, at: destinationIndexPath.row)

        let movedRecord = playlistTrackRecords.remove(at: sourceIndexPath.row)
        playlistTrackRecords.insert(movedRecord, at: destinationIndexPath.row)

        for (index, record) in playlistTrackRecords.enumerated() {
            guard let recordId = record.id else { continue }
            do {
                try db.reorderPlaylistTrack(id: recordId, newPosition: index)
            } catch {
                AppLogger.error("Failed to reorder playlist track: \(error.localizedDescription)", category: .database)
            }
        }
        updateMosaic()
        impactLight.impactOccurred()
    }
}

private final class PlaylistTrackCell: UITableViewCell {

    static let reuseID = "PlaylistTrackCell"

    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let durationLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        artistLabel.font = .preferredFont(forTextStyle: .caption1)
        artistLabel.adjustsFontForContentSizeCategory = true
        artistLabel.textColor = .secondaryLabel

        durationLabel.font = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 13, weight: .regular))
        durationLabel.adjustsFontForContentSizeCategory = true
        durationLabel.textColor = .tertiaryLabel
        durationLabel.textAlignment = .right

        let infoStack = UIStackView(arrangedSubviews: [titleLabel, artistLabel])
        infoStack.axis = .vertical
        infoStack.spacing = 2

        let stack = UIStackView(arrangedSubviews: [infoStack, durationLabel])
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            durationLabel.widthAnchor.constraint(equalToConstant: 48),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with track: Track) {
        titleLabel.text = track.title
        artistLabel.text = track.artist
        let total = Int(track.duration)
        durationLabel.text = String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension PlaylistDetailViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        impactLight.impactOccurred()
        audioPlayer.play(tracks, startingAt: indexPath.row)
    }

    func tableView(_ tableView: UITableView, willBeginEditingRowAt indexPath: IndexPath) {
        reorderFeedback.prepare()
    }

    func tableView(
        _ tableView: UITableView,
        targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath,
        toProposedIndexPath proposedDestinationIndexPath: IndexPath
    ) -> IndexPath {
        if sourceIndexPath != proposedDestinationIndexPath {
            reorderFeedback.selectionChanged()
        }
        return proposedDestinationIndexPath
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let track = tracks[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            let remove = UIAction(
                title: "Remove from Playlist",
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in
                self?.removeTrack(at: indexPath)
            }
            return TrackContextMenu.build(
                for: track,
                in: self,
                push: { [weak self] viewController in
                    self?.navigationController?.pushViewController(viewController, animated: true)
                },
                context: TrackContextMenu.Context(
                    extraSections: [UIMenu(options: .displayInline, children: [remove])]
                )
            )
        }
    }

    private func removeTrack(at indexPath: IndexPath) {
        guard playlistTrackRecords.indices.contains(indexPath.row),
              let recordId = playlistTrackRecords[indexPath.row].id else { return }
        do {
            try db.removeTrackFromPlaylist(id: recordId)
            playlistTrackRecords.remove(at: indexPath.row)
            tracks.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .automatic)
            updateMosaic()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            AppLogger.error("Failed to remove track from playlist: \(error.localizedDescription)", category: .database)
        }
    }
}

/// A stacked-artwork mosaic that lays out up to four distinct covers:
/// a 2x2 grid for four, a large-plus-column split for three, side-by-side
/// halves for two, a single full-bleed cover for one, and a music.note
/// placeholder tile when the playlist has no artwork at all.
private final class StackedArtworkMosaicView: UIView {

    private let contentContainer = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowOffset = CGSize(width: 0, height: 10)
        layer.shadowRadius = 24

        contentContainer.layer.cornerRadius = 20
        contentContainer.layer.cornerCurve = .continuous
        contentContainer.clipsToBounds = true
        contentContainer.backgroundColor = .secondarySystemBackground
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)

        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setCovers([])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 20).cgPath
    }

    func setCovers(_ covers: [UIImage]) {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        let mosaic = buildMosaic(covers: covers)
        mosaic.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(mosaic)
        NSLayoutConstraint.activate([
            mosaic.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            mosaic.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            mosaic.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            mosaic.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    private func buildMosaic(covers: [UIImage]) -> UIView {
        switch covers.count {
        case 0:
            return placeholderTile()
        case 1:
            return coverTile(covers[0])
        case 2:
            return rowStack([coverTile(covers[0]), coverTile(covers[1])])
        case 3:
            let column = columnStack([coverTile(covers[1]), coverTile(covers[2])])
            return rowStack([coverTile(covers[0]), column])
        default:
            let top = rowStack([coverTile(covers[0]), coverTile(covers[1])])
            let bottom = rowStack([coverTile(covers[2]), coverTile(covers[3])])
            return columnStack([top, bottom])
        }
    }

    private func rowStack(_ views: [UIView]) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 1
        return stack
    }

    private func columnStack(_ views: [UIView]) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.distribution = .fillEqually
        stack.spacing = 1
        return stack
    }

    private func coverTile(_ image: UIImage) -> UIImageView {
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        return imageView
    }

    private func placeholderTile() -> UIView {
        let tile = UIView()
        tile.backgroundColor = .tertiarySystemFill
        let symbol = UIImageView(image: UIImage(systemName: "music.note"))
        symbol.tintColor = .secondaryLabel
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 56, weight: .thin)
        symbol.contentMode = .scaleAspectFit
        symbol.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(symbol)
        NSLayoutConstraint.activate([
            symbol.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        return tile
    }
}
