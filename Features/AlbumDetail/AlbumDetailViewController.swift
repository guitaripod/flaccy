import FlaccyCore
import UIKit

final class AlbumDetailViewController: UIViewController, SonglinkShareable {

    let album: Album
    let audioPlayer: AudioPlaying
    var tableView: UITableView!
    var dataSource: UITableViewDiffableDataSource<Int, Track>!
    let backdropView = AmbientPaletteBackdropView()
    let artworkCard = UIView()
    let artworkView = UIImageView()
    let titleMarquee = MarqueeLabel()
    var accentColor: UIColor = .white
    var appearanceElements: [UIView] = []
    var hasAnimatedAppearance = false
    let genreChipsHolder = UIView()
    let infoStack = UIStackView()
    var actionRow = UIView()
    let headerColumn = UIScrollView()
    var headerLayoutConstraints: [NSLayoutConstraint] = []
    var appliedHeaderStyle: AdaptiveLayout.DetailHeaderStyle?
    var tableLeading: NSLayoutConstraint!
    var tableColumnLeading: NSLayoutConstraint!
    let playCountLabel = UILabel()
    let metaLabel = UILabel()
    var enrichmentTask: Task<Void, Never>?
    var metadataTask: Task<Void, Never>?
    var playCountTask: Task<Void, Never>?
    let impactLight = UIImpactFeedbackGenerator(style: .light)
    let impactMedium = UIImpactFeedbackGenerator(style: .medium)

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
        setupOverflowMenu()

        NotificationCenter.default.addObserver(self, selector: #selector(playbackChanged), name: AudioPlayer.trackDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(playbackChanged), name: AudioPlayer.playbackStateDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(lovedChanged), name: LovedTracksService.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(artworkChanged), name: AlbumArtworkCache.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(tracksRevised), name: Library.tracksRevised, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(tracksRevised), name: RemoteAvailability.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(historyDidChange), name: ListenHistorySync.didChange, object: nil)
        loadEnrichment()
        repairMetadataIfNeeded()
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
        metadataTask?.cancel()
        playCountTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func setupOverflowMenu() {
        let album = self.album
        let localTracks = album.tracks.filter { $0.remoteSong == nil }
        let delete = UIAction(title: String(localized: "Delete from Library"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            guard let self else { return }
            TrackContextMenu.confirmDelete(
                title: String(localized: "Delete \"\(album.title)\"?"),
                message: String(localized: "All \(localTracks.count) tracks will be removed from this device."),
                in: self
            ) { [weak self] in
                Task { @MainActor in
                    let navigationController = self?.navigationController
                    navigationController?.popViewController(animated: true)
                    await Library.shared.deleteTracks(localTracks)
                    if let navView = navigationController?.view {
                        ToastView.show(String(localized: "Deleted \(album.title)"), in: navView, style: .info)
                    }
                }
            }
        }
        var sections: [UIMenuElement] = [editArtworkAction()]
        if let download = RemoteDownloadActions.action(for: album.tracks, in: self) {
            sections.append(UIMenu(options: .displayInline, children: [download]))
        }
        if !localTracks.isEmpty { sections.append(UIMenu(options: .displayInline, children: [delete])) }
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            menu: UIMenu(children: sections)
        )
    }

    func editArtworkAction() -> UIAction {
        UIAction(title: String(localized: "Edit Artwork"), image: UIImage(systemName: "photo.badge.pencil")) { [weak self] _ in
            self?.presentArtworkEditor()
        }
    }

    func presentArtworkEditor() {
        impactLight.impactOccurred()
        ArtworkEditorViewController.present(for: album, from: self) { [weak self] in
            guard let self else { return }
            ToastView.show(String(localized: "Artwork updated"), in: self.view, style: .success)
        }
    }

    @objc func artworkChanged() {
        AlbumArtworkCache.shared.loadArtwork(forAlbum: album.title, artist: album.artist) { [weak self] image in
            guard let self else { return }
            guard let image else {
                self.artworkView.contentMode = .center
                self.artworkView.image = UIImage(systemName: "music.note")
                self.applyPalette(from: nil, animated: true)
                return
            }
            UIView.transition(with: self.artworkView, duration: 0.3, options: .transitionCrossDissolve) {
                self.artworkView.contentMode = .scaleAspectFill
                self.artworkView.image = image
            }
            self.applyPalette(from: image, animated: true)
        }
    }

    @objc func playbackChanged() {
        reconfigureAllRows()
    }

    @objc func lovedChanged() {
        reconfigureAllRows()
    }

    @objc func tracksRevised() {
        reconfigureAllRows()
    }

    func reconfigureAllRows() {
        guard let dataSource else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func setupBackdrop() {
        backdropView.frame = view.bounds
        view.addSubview(backdropView)
        applyPalette(from: resolvedArtwork(), animated: false)
    }

    func resolvedArtwork() -> UIImage? {
        album.artwork ?? AlbumArtworkCache.shared.artwork(forAlbum: album.title, artist: album.artist)
    }

    func applyPalette(from artwork: UIImage?, animated: Bool) {
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
    static func readableAccent(from palette: ArtworkPalette) -> UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        palette.dominant.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return UIColor(hue: hue, saturation: min(saturation, 0.5), brightness: max(brightness, 0.9), alpha: 1)
    }

    func setupTableView() {
        tableView = UITableView(frame: .zero, style: .plain)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.indicatorStyle = .white
        tableView.register(AlbumTrackCell.self, forCellReuseIdentifier: AlbumTrackCell.reuseID)
        buildHeaderComponents()
        tableView.tableFooterView = buildFooterView()
        view.addSubview(tableView)

        tableLeading = tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        tableColumnLeading = tableView.leadingAnchor.constraint(equalTo: headerColumn.trailingAnchor)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableLeading,
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func configureDataSource() {
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

    func applySnapshot() {
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
        applyHeaderStyle()
        sizeHeaderToFit()
    }

    func prepareAppearanceAnimationIfNeeded() {
        guard !hasAnimatedAppearance, !UIAccessibility.isReduceMotionEnabled else { return }
        tableView.alpha = 0
        for element in appearanceElements {
            element.alpha = 0
            element.transform = CGAffineTransform(translationX: 0, y: 14)
        }
    }

    func runAppearanceAnimationIfNeeded() {
        guard !hasAnimatedAppearance else { return }
        hasAnimatedAppearance = true
        guard !UIAccessibility.isReduceMotionEnabled else {
            tableView.alpha = 1
            return
        }
        UIViewPropertyAnimator(duration: 0.32, dampingRatio: 0.84) { [self] in
            tableView.alpha = 1
        }.startAnimation()
        for (index, element) in appearanceElements.enumerated() {
            let animator = UIViewPropertyAnimator(duration: 0.32, dampingRatio: 0.84) {
                element.alpha = 1
                element.transform = .identity
            }
            animator.startAnimation(afterDelay: Double(index) * 0.05)
        }
    }

    func playTapped() {
        impactMedium.impactOccurred()
        audioPlayer.play(album.tracks, startingAt: 0)
    }

    func shuffleTapped() {
        impactMedium.impactOccurred()
        var shuffled = album.tracks
        shuffled.shuffle()
        audioPlayer.play(shuffled, startingAt: 0)
    }

    func addAlbumToQueue() {
        for track in album.tracks {
            AudioPlayer.shared.addToQueue(track)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        ToastView.show(String(localized: "Added \(album.tracks.count) tracks to queue"), in: view, style: .info)
    }

    func toggleLove(_ track: Track) {
        impactLight.impactOccurred()
        Task { _ = await LovedTracksService.shared.toggleLove(track: track) }
    }

    func artistTapped() {
        impactLight.impactOccurred()
        let artistAlbums = Library.shared.albums.filter { $0.artist == album.artist }
        let vc = ArtistDetailViewController(artistName: album.artist, albums: artistAlbums)
        navigationController?.pushViewController(vc, animated: true)
    }
}
