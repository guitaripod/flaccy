import UIKit

final class AlbumDetailViewController: UIViewController, SonglinkShareable {

    private let album: Album
    private let audioPlayer: AudioPlaying
    private var tableView: UITableView!
    private var dataSource: UITableViewDiffableDataSource<Int, Track>!
    private let backdropView = AmbientPaletteBackdropView()
    private let artworkCard = UIView()
    private let artworkView = UIImageView()
    private let titleMarquee = MarqueeLabel()
    private var accentColor: UIColor = .white
    private var appearanceElements: [UIView] = []
    private var hasAnimatedAppearance = false
    private let genreChipsHolder = UIView()
    private let playCountLabel = UILabel()
    private var enrichmentTask: Task<Void, Never>?
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)

    init(album: Album, audioPlayer: AudioPlaying = AudioPlayer.shared) {
        self.album = album
        self.audioPlayer = audioPlayer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        navigationItem.largeTitleDisplayMode = .never
        setupBackdrop()
        setupTableView()
        configureDataSource()
        applySnapshot()

        NotificationCenter.default.addObserver(self, selector: #selector(playbackChanged), name: AudioPlayer.trackDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(playbackChanged), name: AudioPlayer.playbackStateDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(lovedChanged), name: LovedTracksService.didChange, object: nil)
        loadEnrichment()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        prepareAppearanceAnimationIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        runAppearanceAnimationIfNeeded()
    }

    deinit {
        enrichmentTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func playbackChanged() {
        reconfigureAllRows()
    }

    @objc private func lovedChanged() {
        reconfigureAllRows()
    }

    private func reconfigureAllRows() {
        guard let dataSource else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Fetches Last.fm genre tags and the personal album play count off-main,
    /// caching results, then folds them into the header without blocking UI.
    private func loadEnrichment() {
        let artist = album.artist
        let title = album.title
        let authenticated = LastFMService.shared.isAuthenticated
        enrichmentTask = Task { [weak self] in
            let tags = await DetailEnrichmentCache.shared.topTags(artist: artist)
            if !Task.isCancelled { self?.applyGenreChips(tags) }

            guard authenticated else { return }
            let plays = await DetailEnrichmentCache.shared.albumPlayCount(artist: artist, album: title)
            if !Task.isCancelled, plays > 0 { self?.applyPlayCount(plays) }
        }
    }

    private func applyGenreChips(_ tags: [String]) {
        genreChipsHolder.subviews.forEach { $0.removeFromSuperview() }
        guard !tags.isEmpty else {
            genreChipsHolder.isHidden = true
            sizeHeaderToFit()
            return
        }
        let row = DetailChip.chipsRow(tags)
        row.translatesAutoresizingMaskIntoConstraints = false
        genreChipsHolder.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: genreChipsHolder.topAnchor),
            row.bottomAnchor.constraint(equalTo: genreChipsHolder.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: genreChipsHolder.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: genreChipsHolder.trailingAnchor),
        ])
        genreChipsHolder.isHidden = false
        sizeHeaderToFit()
    }

    private func applyPlayCount(_ count: Int) {
        let word = count == 1 ? "time" : "times"
        playCountLabel.text = "You've played this album \(count) \(word)"
        playCountLabel.textColor = accentColor
        playCountLabel.isHidden = false
        sizeHeaderToFit()
    }

    private func setupBackdrop() {
        backdropView.frame = view.bounds
        view.addSubview(backdropView)
        applyPalette(from: resolvedArtwork(), animated: false)
    }

    private func resolvedArtwork() -> UIImage? {
        album.artwork ?? AlbumArtworkCache.shared.artwork(forAlbum: album.title, artist: album.artist)
    }

    private func applyPalette(from artwork: UIImage?, animated: Bool) {
        let cacheKey = "\(album.title)\0\(album.artist)"
        ArtworkPaletteExtractor.palette(for: artwork, cacheKey: cacheKey, fallbackSeed: album.id) { [weak self] palette in
            guard let self else { return }
            self.backdropView.apply(palette, animated: animated)
            self.accentColor = Self.readableAccent(from: palette)
            self.playbackChanged()
        }
    }

    /// Lifts the dominant palette color to a bright, low-saturation tint so
    /// now-playing rows stay legible against the dark backdrop.
    private static func readableAccent(from palette: ArtworkPalette) -> UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        palette.dominant.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return UIColor(hue: hue, saturation: min(saturation, 0.5), brightness: max(brightness, 0.9), alpha: 1)
    }

    private func setupTableView() {
        tableView = UITableView(frame: .zero, style: .plain)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.indicatorStyle = .white
        tableView.register(AlbumTrackCell.self, forCellReuseIdentifier: AlbumTrackCell.reuseID)
        tableView.tableHeaderView = buildHeaderView()
        tableView.tableFooterView = buildFooterView()
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource<Int, Track>(tableView: tableView) {
            [weak self] tableView, indexPath, track in
            let cell = tableView.dequeueReusableCell(withIdentifier: AlbumTrackCell.reuseID, for: indexPath) as! AlbumTrackCell
            guard let self else { return cell }
            let isCurrent = self.audioPlayer.currentTrack?.fileURL == track.fileURL
            cell.configure(
                with: track,
                index: indexPath.row,
                isCurrent: isCurrent,
                isPlaying: isCurrent && self.audioPlayer.isPlaying,
                loved: LovedTracksService.shared.isLoved(track: track),
                accent: self.accentColor
            )
            cell.onToggleLove = { [weak self] in self?.toggleLove(track) }
            return cell
        }
        dataSource.defaultRowAnimation = .fade
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Track>()
        snapshot.appendSections([0])
        snapshot.appendItems(album.tracks)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        backdropView.frame = view.bounds
        artworkCard.layer.shadowPath = UIBezierPath(
            roundedRect: artworkCard.bounds, cornerRadius: 16
        ).cgPath
        sizeHeaderToFit()
    }

    private func sizeHeaderToFit() {
        for wrapper in [tableView.tableHeaderView, tableView.tableFooterView] {
            guard let wrapper else { continue }
            let size = wrapper.systemLayoutSizeFitting(
                CGSize(width: tableView.bounds.width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            if wrapper.frame.size.height != size.height {
                wrapper.frame.size.height = size.height
                if wrapper === tableView.tableHeaderView {
                    tableView.tableHeaderView = wrapper
                } else {
                    tableView.tableFooterView = wrapper
                }
            }
        }
    }

    private func buildHeaderView() -> UIView {
        let container = UIView()

        setupArtworkCard()

        titleMarquee.text = album.title
        titleMarquee.font = .scaled(.title2, size: 24, weight: .bold)
        titleMarquee.textColor = .white

        let artistButton = UIButton(type: .system)
        artistButton.setTitle(album.artist, for: .normal)
        artistButton.titleLabel?.font = .scaled(.callout, size: 16, weight: .semibold)
        artistButton.titleLabel?.adjustsFontForContentSizeCategory = true
        artistButton.setTitleColor(.white.withAlphaComponent(0.85), for: .normal)
        artistButton.contentHorizontalAlignment = .leading
        artistButton.accessibilityHint = "Shows the artist's albums"
        artistButton.addAction(UIAction { [weak self] _ in self?.artistTapped() }, for: .touchUpInside)

        let metaLabel = UILabel()
        metaLabel.font = .scaled(.footnote, size: 13, weight: .regular)
        metaLabel.adjustsFontForContentSizeCategory = true
        metaLabel.textColor = .white.withAlphaComponent(0.55)
        var metaParts: [String] = []
        if let year = album.year, !year.isEmpty { metaParts.append(year) }
        if let genre = album.genre, !genre.isEmpty { metaParts.append(genre) }
        metaLabel.text = metaParts.joined(separator: " \u{00B7} ")
        metaLabel.isHidden = metaParts.isEmpty

        playCountLabel.font = .scaled(.footnote, size: 13, weight: .semibold)
        playCountLabel.adjustsFontForContentSizeCategory = true
        playCountLabel.textColor = accentColor
        playCountLabel.numberOfLines = 0
        playCountLabel.isHidden = true

        genreChipsHolder.isHidden = true

        let qualityBadgeRow = buildQualityBadgeRow()

        let infoStack = UIStackView(arrangedSubviews: [titleMarquee, artistButton, metaLabel, playCountLabel])
        infoStack.axis = .vertical
        infoStack.spacing = 2
        infoStack.alignment = .leading
        if let qualityBadgeRow {
            infoStack.addArrangedSubview(qualityBadgeRow)
            infoStack.setCustomSpacing(10, after: metaLabel)
        }
        infoStack.addArrangedSubview(genreChipsHolder)
        infoStack.setCustomSpacing(10, after: qualityBadgeRow ?? metaLabel)
        genreChipsHolder.widthAnchor.constraint(equalTo: infoStack.widthAnchor).isActive = true
        titleMarquee.widthAnchor.constraint(equalTo: infoStack.widthAnchor).isActive = true

        let actionRow = buildActionRow()
        appearanceElements = [artworkCard, infoStack, actionRow]

        let mainStack = UIStackView(arrangedSubviews: [artworkCard, infoStack, actionRow])
        mainStack.axis = .vertical
        mainStack.spacing = 18
        mainStack.setCustomSpacing(22, after: artworkCard)
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(mainStack)

        let leading = mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24)
        let trailing = mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24)
        let bottom = mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20)
        for constraint in [leading, trailing, bottom] {
            constraint.priority = .defaultHigh
        }
        let cardWidth = artworkCard.widthAnchor.constraint(equalTo: mainStack.widthAnchor, multiplier: 0.8)
        cardWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            artworkCard.centerXAnchor.constraint(equalTo: mainStack.centerXAnchor),
            leading, trailing, bottom, cardWidth,
        ])
        return container
    }

    private func setupArtworkCard() {
        artworkCard.layer.shadowColor = UIColor.black.cgColor
        artworkCard.layer.shadowOpacity = 0.45
        artworkCard.layer.shadowOffset = CGSize(width: 0, height: 12)
        artworkCard.layer.shadowRadius = 28
        addMotionParallax(to: artworkCard)

        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.layer.cornerRadius = 16
        artworkView.layer.cornerCurve = .continuous
        artworkView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        artworkView.tintColor = UIColor.white.withAlphaComponent(0.35)
        artworkView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 56, weight: .ultraLight)
        artworkView.isAccessibilityElement = true
        artworkView.accessibilityLabel = "Album artwork for \(album.title)"

        if let artwork = resolvedArtwork() {
            artworkView.image = artwork
        } else {
            artworkView.contentMode = .center
            artworkView.image = UIImage(systemName: "music.note")
            AlbumArtworkCache.shared.loadArtwork(forAlbum: album.title, artist: album.artist) { [weak self] image in
                guard let self, let image else { return }
                self.artworkView.contentMode = .scaleAspectFill
                self.artworkView.image = image
                self.applyPalette(from: image, animated: true)
            }
        }

        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkCard.addSubview(artworkView)
        NSLayoutConstraint.activate([
            artworkView.topAnchor.constraint(equalTo: artworkCard.topAnchor),
            artworkView.leadingAnchor.constraint(equalTo: artworkCard.leadingAnchor),
            artworkView.trailingAnchor.constraint(equalTo: artworkCard.trailingAnchor),
            artworkView.bottomAnchor.constraint(equalTo: artworkCard.bottomAnchor),
            artworkView.heightAnchor.constraint(equalTo: artworkView.widthAnchor),
        ])
    }

    /// Device-tilt parallax matching the Now Playing artwork card; skipped
    /// under Reduce Motion.
    private func addMotionParallax(to card: UIView) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let horizontal = UIInterpolatingMotionEffect(keyPath: "center.x", type: .tiltAlongHorizontalAxis)
        horizontal.minimumRelativeValue = -14
        horizontal.maximumRelativeValue = 14
        let vertical = UIInterpolatingMotionEffect(keyPath: "center.y", type: .tiltAlongVerticalAxis)
        vertical.minimumRelativeValue = -10
        vertical.maximumRelativeValue = 10
        let group = UIMotionEffectGroup()
        group.motionEffects = [horizontal, vertical]
        card.addMotionEffect(group)
    }

    /// A left-aligned glass pill summarizing the album's peak audio quality,
    /// or nil when no track carries codec/quality metadata.
    private func buildQualityBadgeRow() -> UIView? {
        guard let summary = DetailChip.albumQualitySummary(tracks: album.tracks) else { return nil }
        let pill = DetailChip.pill(text: summary, systemImage: "waveform", accessibilityPrefix: "Audio quality")
        let row = UIStackView(arrangedSubviews: [pill, UIView()])
        row.axis = .horizontal
        row.alignment = .center
        return row
    }

    private func buildActionRow() -> UIView {
        let play = LiquidGlass.actionCapsule(title: "Play", systemImage: "play.fill") { [weak self] in
            self?.playTapped()
        }
        let shuffle = LiquidGlass.actionCapsule(title: "Shuffle", systemImage: "shuffle") { [weak self] in
            self?.shuffleTapped()
        }
        let queue = LiquidGlass.iconCapsule(systemImage: "text.append", accessibilityLabel: "Add album to queue") { [weak self] in
            self?.addAlbumToQueue()
        }
        let share = LiquidGlass.iconCapsule(systemImage: "square.and.arrow.up", accessibilityLabel: "Share album") { [weak self] in
            guard let self else { return }
            self.shareAlbumViaSonglink(title: self.album.title, artist: self.album.artist, from: self.view)
        }
        let row = UIStackView(arrangedSubviews: [play, shuffle, queue, share])
        row.spacing = 10
        play.widthAnchor.constraint(equalTo: shuffle.widthAnchor).isActive = true
        return LiquidGlass.grouping(row)
    }

    private func buildFooterView() -> UIView {
        let container = UIView()
        let label = UILabel()
        label.font = .scaled(.footnote, size: 13, weight: .regular)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white.withAlphaComponent(0.45)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.text = footerText()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -32),
        ])
        let trailing = label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24)
        trailing.priority = .defaultHigh
        trailing.isActive = true
        return container
    }

    private func footerText() -> String {
        let count = album.tracks.count
        let trackWord = count == 1 ? "track" : "tracks"
        let totalSeconds = album.tracks.reduce(0) { $0 + Int($1.duration) }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let duration = hours > 0 ? "\(hours) hr \(minutes) min" : "\(minutes) min"
        return "\(count) \(trackWord) \u{00B7} \(duration)"
    }

    private func prepareAppearanceAnimationIfNeeded() {
        guard !hasAnimatedAppearance, !UIAccessibility.isReduceMotionEnabled else { return }
        for element in appearanceElements {
            element.alpha = 0
            element.transform = CGAffineTransform(translationX: 0, y: 14)
        }
    }

    private func runAppearanceAnimationIfNeeded() {
        guard !hasAnimatedAppearance else { return }
        hasAnimatedAppearance = true
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        for (index, element) in appearanceElements.enumerated() {
            let animator = UIViewPropertyAnimator(duration: 0.32, dampingRatio: 0.84) {
                element.alpha = 1
                element.transform = .identity
            }
            animator.startAnimation(afterDelay: Double(index) * 0.05)
        }
    }

    private func playTapped() {
        impactMedium.impactOccurred()
        audioPlayer.play(album.tracks, startingAt: 0)
    }

    private func shuffleTapped() {
        impactMedium.impactOccurred()
        var shuffled = album.tracks
        shuffled.shuffle()
        audioPlayer.play(shuffled, startingAt: 0)
    }

    private func addAlbumToQueue() {
        for track in album.tracks {
            AudioPlayer.shared.addToQueue(track)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        ToastView.show("Added \(album.tracks.count) tracks to queue", in: view, style: .info)
    }

    private func toggleLove(_ track: Track) {
        impactLight.impactOccurred()
        Task { _ = await LovedTracksService.shared.toggleLove(track: track) }
    }

    private func artistTapped() {
        impactLight.impactOccurred()
        let artistAlbums = Library.shared.albums.filter { $0.artist == album.artist }
        let vc = ArtistDetailViewController(artistName: album.artist, albums: artistAlbums)
        navigationController?.pushViewController(vc, animated: true)
    }
}

extension AlbumDetailViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        impactLight.impactOccurred()
        audioPlayer.play(album.tracks, startingAt: indexPath.row)
    }

    /// Stretchy hero: pulling past the top scales the artwork card up around
    /// its center so the overscroll feels physical.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard hasAnimatedAppearance, !UIAccessibility.isReduceMotionEnabled else { return }
        let pull = -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
        if pull > 0 {
            let scale = 1 + min(pull / 500, 0.18)
            artworkCard.transform = CGAffineTransform(translationX: 0, y: -pull * 0.15).scaledBy(x: scale, y: scale)
        } else {
            artworkCard.transform = .identity
        }
    }

    func tableView(
        _ tableView: UITableView,
        leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let track = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let isLoved = LovedTracksService.shared.isLoved(track: track)
        let love = UIContextualAction(style: .normal, title: isLoved ? "Unlove" : "Love") { [weak self] _, _, completion in
            guard let self else { return completion(false) }
            self.toggleLove(track)
            completion(true)
        }
        love.image = UIImage(systemName: isLoved ? "heart.slash.fill" : "heart.fill")
        love.backgroundColor = .systemPink
        let playNext = UIContextualAction(style: .normal, title: "Play Next") { [weak self] _, _, completion in
            guard let self else { return completion(false) }
            AudioPlayer.shared.insertNext(track)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            ToastView.show("Playing next", in: self.view, style: .info)
            completion(true)
        }
        playNext.image = UIImage(systemName: "text.line.first.and.arrowtriangle.forward")
        playNext.backgroundColor = .systemIndigo
        return UISwipeActionsConfiguration(actions: [love, playNext])
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let track = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let addToQueue = UIContextualAction(style: .normal, title: "Queue") { [weak self] _, _, completion in
            guard let self else { return completion(false) }
            AudioPlayer.shared.addToQueue(track)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            ToastView.show("Added to queue", in: self.view, style: .info)
            completion(true)
        }
        addToQueue.image = UIImage(systemName: "text.append")
        addToQueue.backgroundColor = .systemTeal
        return UISwipeActionsConfiguration(actions: [addToQueue])
    }

    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let track = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.buildTrackContextMenu(for: track)
        }
    }

    private func buildTrackContextMenu(for track: Track) -> UIMenu {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL
        let trackPath = track.fileURL.standardizedFileURL.path
        let docsPath = docsDir.path
        let relativeURL: String
        if trackPath.hasPrefix(docsPath) {
            let rel = String(trackPath.dropFirst(docsPath.count))
            relativeURL = rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
        } else {
            relativeURL = track.fileURL.lastPathComponent
        }

        var playlistActions: [UIMenuElement] = []

        do {
            let playlists = try DatabaseManager.shared.fetchAllPlaylists()
            for playlist in playlists {
                guard let playlistId = playlist.id else { continue }
                let action = UIAction(title: playlist.name, image: UIImage(systemName: "music.note.list")) { [weak self] _ in
                    guard let self else { return }
                    do {
                        try DatabaseManager.shared.addTrackToPlaylist(playlistId: playlistId, trackFileURL: relativeURL)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        ToastView.show("Added to \(playlist.name)", in: self.view, style: .success)
                    } catch {
                        AppLogger.error("Failed to add track to playlist: \(error.localizedDescription)", category: .database)
                        ToastView.show("Failed to add to playlist", in: self.view, style: .error)
                    }
                }
                playlistActions.append(action)
            }
        } catch {
            AppLogger.error("Failed to fetch playlists: \(error.localizedDescription)", category: .database)
        }

        let newPlaylistAction = UIAction(
            title: "New Playlist\u{2026}",
            image: UIImage(systemName: "plus")
        ) { [weak self] _ in
            self?.promptNewPlaylistAndAdd(trackFileURL: relativeURL)
        }
        playlistActions.append(newPlaylistAction)

        let addToPlaylistMenu = UIMenu(
            title: "Add to Playlist",
            image: UIImage(systemName: "text.badge.plus"),
            children: playlistActions
        )

        let playNext = UIAction(
            title: "Play Next",
            image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")
        ) { [weak self] _ in
            guard let self else { return }
            AudioPlayer.shared.insertNext(track)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            ToastView.show("Playing next", in: self.view, style: .info)
        }

        let addToQueue = UIAction(
            title: "Add to Queue",
            image: UIImage(systemName: "text.append")
        ) { [weak self] _ in
            guard let self else { return }
            AudioPlayer.shared.addToQueue(track)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            ToastView.show("Added to queue", in: self.view, style: .info)
        }

        let share = UIAction(
            title: "Share",
            image: UIImage(systemName: "square.and.arrow.up")
        ) { [weak self] _ in
            guard let self else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self.shareTrackViaSonglink(title: track.title, artist: track.artist, from: self.view)
        }
        let shareMenu = UIMenu(options: .displayInline, children: [share])

        return UIMenu(children: [playNext, addToQueue, addToPlaylistMenu, shareMenu])
    }

    private func promptNewPlaylistAndAdd(trackFileURL: String) {
        let alert = UIAlertController(title: "New Playlist", message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "Playlist name"
            textField.autocapitalizationType = .words
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { _ in
            guard let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty else { return }
            do {
                let playlist = try DatabaseManager.shared.createPlaylist(name: name)
                if let playlistId = playlist.id {
                    try DatabaseManager.shared.addTrackToPlaylist(playlistId: playlistId, trackFileURL: trackFileURL)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                AppLogger.error("Failed to create playlist and add track: \(error.localizedDescription)", category: .database)
            }
        })
        present(alert, animated: true)
    }
}

private final class AlbumTrackCell: UITableViewCell {

    static let reuseID = "AlbumTrackCell"

    var onToggleLove: (() -> Void)?

    private let numberLabel = UILabel()
    private let barsView = NowPlayingBarsView()
    private let trackTitleLabel = UILabel()
    private let qualityLabel = UILabel()
    private let lovedButton = UIButton(type: .system)
    private let durationLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        let selection = UIView()
        selection.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        selectedBackgroundView = selection

        numberLabel.font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 15, weight: .regular), maximumPointSize: 24)
        numberLabel.adjustsFontForContentSizeCategory = true
        numberLabel.textColor = .white.withAlphaComponent(0.45)
        numberLabel.textAlignment = .center

        barsView.isHidden = true

        trackTitleLabel.font = .scaled(.body, size: 16, weight: .regular)
        trackTitleLabel.adjustsFontForContentSizeCategory = true
        trackTitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trackTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        qualityLabel.font = UIFontMetrics(forTextStyle: .caption2)
            .scaledFont(for: .monospacedSystemFont(ofSize: 10, weight: .semibold), maximumPointSize: 16)
        qualityLabel.adjustsFontForContentSizeCategory = true
        qualityLabel.textColor = .white.withAlphaComponent(0.6)
        qualityLabel.setContentHuggingPriority(.required, for: .horizontal)
        qualityLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        lovedButton.setContentHuggingPriority(.required, for: .horizontal)
        lovedButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        lovedButton.tintColor = .systemPink
        lovedButton.addAction(UIAction { [weak self] _ in self?.onToggleLove?() }, for: .touchUpInside)
        lovedButton.widthAnchor.constraint(equalToConstant: 30).isActive = true

        durationLabel.font = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 13, weight: .regular), maximumPointSize: 22)
        durationLabel.adjustsFontForContentSizeCategory = true
        durationLabel.textColor = .white.withAlphaComponent(0.45)
        durationLabel.textAlignment = .right

        let numberContainer = UIView()
        numberContainer.translatesAutoresizingMaskIntoConstraints = false
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        barsView.translatesAutoresizingMaskIntoConstraints = false
        numberContainer.addSubview(numberLabel)
        numberContainer.addSubview(barsView)

        NSLayoutConstraint.activate([
            numberLabel.topAnchor.constraint(equalTo: numberContainer.topAnchor),
            numberLabel.bottomAnchor.constraint(equalTo: numberContainer.bottomAnchor),
            numberLabel.leadingAnchor.constraint(equalTo: numberContainer.leadingAnchor),
            numberLabel.trailingAnchor.constraint(equalTo: numberContainer.trailingAnchor),
            barsView.centerXAnchor.constraint(equalTo: numberContainer.centerXAnchor),
            barsView.centerYAnchor.constraint(equalTo: numberContainer.centerYAnchor),
            barsView.widthAnchor.constraint(equalToConstant: 16),
            barsView.heightAnchor.constraint(equalToConstant: 14),
        ])

        let stack = UIStackView(arrangedSubviews: [numberContainer, trackTitleLabel, qualityLabel, lovedButton, durationLabel])
        stack.spacing = 10
        stack.alignment = .center
        stack.setCustomSpacing(4, after: lovedButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            numberContainer.widthAnchor.constraint(equalToConstant: 28),
            durationLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with track: Track, index: Int, isCurrent: Bool, isPlaying: Bool, loved: Bool, accent: UIColor) {
        numberLabel.text = track.trackNumber > 0 ? "\(track.trackNumber)" : "\(index + 1)"
        trackTitleLabel.text = track.title
        let minutes = Int(track.duration) / 60
        let seconds = Int(track.duration) % 60
        durationLabel.text = String(format: "%d:%02d", minutes, seconds)

        if let badge = track.qualityBadge {
            qualityLabel.text = badge
            qualityLabel.isHidden = false
        } else {
            qualityLabel.text = nil
            qualityLabel.isHidden = true
        }

        let heart = UIImage(
            systemName: loved ? "heart.fill" : "heart",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        )
        lovedButton.setImage(heart, for: .normal)
        lovedButton.tintColor = loved ? .systemPink : .white.withAlphaComponent(0.5)
        lovedButton.accessibilityLabel = loved ? "Loved" : "Not loved"
        lovedButton.accessibilityHint = "Double tap to \(loved ? "unlove" : "love") this track"

        numberLabel.isHidden = isCurrent
        barsView.isHidden = !isCurrent
        barsView.tintColor = accent
        barsView.setAnimating(isPlaying)
        trackTitleLabel.textColor = isCurrent ? accent : .white
        trackTitleLabel.font = .scaled(.body, size: 16, weight: isCurrent ? .semibold : .regular)
        accessibilityValue = isCurrent ? (isPlaying ? "Now playing" : "Paused") : nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onToggleLove = nil
    }
}

/// Three vertical bars that bounce while the track is playing and freeze at
/// staggered heights when paused; Reduce Motion keeps them static.
private final class NowPlayingBarsView: UIView {

    private let barLayers: [CALayer] = (0..<3).map { _ in CALayer() }
    private var isAnimating = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        for bar in barLayers {
            bar.cornerRadius = 1.25
            layer.addSublayer(bar)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(restartIfNeeded),
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        for bar in barLayers {
            bar.backgroundColor = tintColor.cgColor
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let barWidth: CGFloat = 2.5
        let spacing = (bounds.width - barWidth * 3) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in barLayers.enumerated() {
            let x = CGFloat(index) * (barWidth + spacing)
            bar.frame = CGRect(x: x, y: 0, width: barWidth, height: bounds.height)
            bar.anchorPoint = CGPoint(x: 0.5, y: 1)
            bar.position = CGPoint(x: x + barWidth / 2, y: bounds.height)
            bar.backgroundColor = tintColor.cgColor
        }
        CATransaction.commit()
        applyBarState()
    }

    func setAnimating(_ animating: Bool) {
        isAnimating = animating
        applyBarState()
    }

    @objc private func restartIfNeeded() {
        applyBarState()
    }

    private func applyBarState() {
        let restScales: [CGFloat] = [0.45, 0.8, 0.6]
        guard isAnimating, !UIAccessibility.isReduceMotionEnabled, window != nil || superview != nil else {
            for (index, bar) in barLayers.enumerated() {
                bar.removeAnimation(forKey: "bounce")
                bar.transform = CATransform3DMakeScale(1, restScales[index], 1)
            }
            return
        }
        for (index, bar) in barLayers.enumerated() {
            guard bar.animation(forKey: "bounce") == nil else { continue }
            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = restScales[index]
            animation.toValue = 1.0
            animation.duration = 0.36 + Double(index) * 0.08
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.add(animation, forKey: "bounce")
        }
    }
}
