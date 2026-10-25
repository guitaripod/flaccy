import FlaccyCore
import MidgarCore
import UIKit

final class PlaylistDetailViewController: UIViewController, SonglinkShareable {

    private let playlistId: Int64
    private let playlistName: String
    private let audioPlayer: AudioPlaying
    private let db = DatabaseManager.shared
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let reorderFeedback = UISelectionFeedbackGenerator()
    private let selectionFeedback = UISelectionFeedbackGenerator()

    private var tableView: UITableView!
    private var tracks: [Track] = []
    private var playlistTrackRecords: [PlaylistTrackRecord] = []
    private let mosaicView = StackedArtworkMosaicView()
    private let editCoverButton = UIButton(type: .custom)
    private let buttonStack = UIStackView()
    private let headerColumn = UIScrollView()
    private var headerLayoutConstraints: [NSLayoutConstraint] = []
    private var appliedHeaderStyle: AdaptiveLayout.DetailHeaderStyle?
    private var tableLeading: NSLayoutConstraint!
    private var tableColumnLeading: NSLayoutConstraint!
    private var hasAnimatedAppearance = false
    private var hasLoadedOnce = false
    private var mosaicGeneration = 0

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
        NotificationCenter.default.addObserver(
            self, selector: #selector(playbackChanged), name: AudioPlayer.trackDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(playbackChanged), name: AudioPlayer.playbackStateDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(artworkChanged), name: AlbumArtworkCache.didChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(tracksRevised), name: Library.tracksRevised, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Repaints the cover and the menu after a picture was chosen or cleared,
    /// here or in the playlists list.
    @objc private func artworkChanged() {
        updateMosaic()
        updateOverflowMenu()
    }

    /// Repaints the visible rows so the playing one lights up here the way it
    /// already does in album detail.
    @objc private func playbackChanged() {
        guard let visible = tableView.indexPathsForVisibleRows, !visible.isEmpty else { return }
        tableView.reloadRows(at: visible, with: .none)
    }

    /// Repaints the visible rows so a song re-exported while the playlist is
    /// open gains its New mix chip.
    @objc private func tracksRevised() {
        playbackChanged()
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
        buildHeaderComponents()
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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyHeaderStyle()
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

    private func buildHeaderComponents() {
        mosaicView.translatesAutoresizingMaskIntoConstraints = false
        mosaicView.artworkLabel = String(localized: "Playlist artwork")
        installEditCoverButton()

        let playButton = makeHeaderButton(
            title: String(localized: "Play"),
            systemImage: "play.fill",
            accessibilityLabel: String(localized: "Play playlist")
        ) { [weak self] in self?.playTapped() }

        let shuffleButton = makeHeaderButton(
            title: String(localized: "Shuffle"),
            systemImage: "shuffle",
            accessibilityLabel: String(localized: "Shuffle playlist")
        ) { [weak self] in self?.shuffleTapped() }

        for capsule in [GlassCapsule(hosting: playButton, height: 48), GlassCapsule(hosting: shuffleButton, height: 48)] {
            buttonStack.addArrangedSubview(capsule)
        }
        buttonStack.spacing = 12
        buttonStack.distribution = .fillEqually
    }

    /// A small material disc at the cover's bottom-trailing corner. The button
    /// itself is 44 pt so it is easy to hit; the disc inside it is 32 pt.
    private func installEditCoverButton() {
        let disc = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        disc.isUserInteractionEnabled = false
        disc.layer.cornerRadius = 16
        disc.layer.cornerCurve = .continuous
        disc.clipsToBounds = true
        disc.translatesAutoresizingMaskIntoConstraints = false

        let glyph = UIImageView(image: UIImage(
            systemName: "pencil",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        ))
        glyph.tintColor = .label
        glyph.contentMode = .center
        glyph.translatesAutoresizingMaskIntoConstraints = false
        disc.contentView.addSubview(glyph)

        editCoverButton.translatesAutoresizingMaskIntoConstraints = false
        editCoverButton.accessibilityLabel = String(localized: "Edit cover")
        editCoverButton.addSubview(disc)
        editCoverButton.addAction(UIAction { [weak self] _ in
            self?.selectionFeedback.selectionChanged()
            self?.presentCoverEditor()
        }, for: .touchUpInside)
        mosaicView.addSubview(editCoverButton)

        NSLayoutConstraint.activate([
            disc.widthAnchor.constraint(equalToConstant: 32),
            disc.heightAnchor.constraint(equalToConstant: 32),
            disc.centerXAnchor.constraint(equalTo: editCoverButton.centerXAnchor),
            disc.centerYAnchor.constraint(equalTo: editCoverButton.centerYAnchor),
            glyph.centerXAnchor.constraint(equalTo: disc.contentView.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: disc.contentView.centerYAnchor),
            editCoverButton.widthAnchor.constraint(equalToConstant: 44),
            editCoverButton.heightAnchor.constraint(equalToConstant: 44),
            editCoverButton.trailingAnchor.constraint(equalTo: mosaicView.trailingAnchor, constant: -2),
            editCoverButton.bottomAnchor.constraint(equalTo: mosaicView.bottomAnchor, constant: -2),
        ])
        mosaicView.accessibilityElements = [mosaicView.artworkElement, editCoverButton]
    }

    private var coverSubject: ArtworkSubject {
        ArtworkSubject(playlistId: playlistId, name: playlistName, tracks: tracks)
    }

    private func presentCoverEditor() {
        ArtworkEditorViewController.present(for: coverSubject, from: self) { [weak self] in
            guard let self else { return }
            ToastView.show(String(localized: "Artwork updated"), in: self.view, style: .success)
        }
    }

    private func confirmAutomaticCover() {
        ArtworkEditorViewController.confirmReset(for: coverSubject, from: self, anchor: nil) { [weak self] in
            guard let self else { return }
            ArtworkEditorViewController.reset(self.coverSubject) { [weak self] succeeded in
                guard succeeded, let self else { return }
                ToastView.show(String(localized: "Automatic cover restored"), in: self.view, style: .success)
            }
        }
    }

    /// Stacked is the phone column. The banner sets a modest cover beside the
    /// play buttons so rows start high on a wider page. Side by side pins the
    /// cover and buttons in a column and gives the other half to the tracks.
    private func applyHeaderStyle() {
        let usable = view.safeAreaLayoutGuide.layoutFrame.size
        guard usable.width > 1 else { return }
        let style = AdaptiveLayout.detailHeaderStyle(forSize: usable)
        guard style != appliedHeaderStyle else { return }
        appliedHeaderStyle = style
        NSLayoutConstraint.deactivate(headerLayoutConstraints)
        headerLayoutConstraints = []
        headerColumn.removeFromSuperview()
        tableView.tableHeaderView = nil
        mosaicView.removeFromSuperview()
        buttonStack.removeFromSuperview()
        buttonStack.axis = style == .stacked ? .horizontal : .vertical

        switch style {
        case .stacked: installStackedHeader()
        case .banner: installBannerHeader(width: usable.width)
        case .sideBySide: installColumnHeader(size: usable)
        }
        tableLeading.isActive = style != .sideBySide
        tableColumnLeading.isActive = style == .sideBySide
        view.setNeedsLayout()
    }

    private func installStackedHeader() {
        let container = UIView()
        let mainStack = UIStackView(arrangedSubviews: [mosaicView, buttonStack])
        mainStack.axis = .vertical
        mainStack.spacing = 24
        mainStack.alignment = .center
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(mainStack)
        let guide = container.safeAreaLayoutGuide
        let leading = mainStack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 32)
        let trailing = mainStack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -32)
        let bottom = mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24)
        let buttonWidth = buttonStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
        let mosaicWidth = mosaicView.widthAnchor.constraint(equalTo: mainStack.widthAnchor, multiplier: 0.62)
        for constraint in [leading, trailing, bottom, buttonWidth, mosaicWidth] { constraint.priority = .defaultHigh }
        let constraints = [
            mainStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            leading, trailing, bottom, buttonWidth, mosaicWidth,
            mosaicView.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
            mosaicView.heightAnchor.constraint(equalTo: mosaicView.widthAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
        headerLayoutConstraints = constraints
        tableView.tableHeaderView = container
    }

    private func installBannerHeader(width: CGFloat) {
        let container = UIView()
        let side = min(max(width * 0.3, 120), 200)
        let row = UIStackView(arrangedSubviews: [mosaicView, buttonStack])
        row.axis = .horizontal
        row.spacing = 24
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        let guide = container.safeAreaLayoutGuide
        let constraints = [
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            row.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            row.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            mosaicView.widthAnchor.constraint(equalToConstant: side),
            mosaicView.heightAnchor.constraint(equalTo: mosaicView.widthAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
        headerLayoutConstraints = constraints
        tableView.tableHeaderView = container
    }

    private func installColumnHeader(size: CGSize) {
        let side = min(max(size.width * 0.4, 240) - 40, size.height * 0.5, 320)
        let columnWidth = max(side + 40, 260)
        headerColumn.translatesAutoresizingMaskIntoConstraints = false
        headerColumn.showsVerticalScrollIndicator = false
        headerColumn.alwaysBounceVertical = false
        headerColumn.contentInsetAdjustmentBehavior = .always
        view.addSubview(headerColumn)
        let mainStack = UIStackView(arrangedSubviews: [mosaicView, buttonStack])
        mainStack.axis = .vertical
        mainStack.spacing = 20
        mainStack.alignment = .fill
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        headerColumn.addSubview(mainStack)
        let guide = view.safeAreaLayoutGuide
        let constraints = [
            headerColumn.topAnchor.constraint(equalTo: view.topAnchor),
            headerColumn.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            headerColumn.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            headerColumn.widthAnchor.constraint(equalToConstant: columnWidth),
            mainStack.topAnchor.constraint(equalTo: headerColumn.contentLayoutGuide.topAnchor, constant: 16),
            mainStack.bottomAnchor.constraint(equalTo: headerColumn.contentLayoutGuide.bottomAnchor, constant: -24),
            mainStack.leadingAnchor.constraint(equalTo: headerColumn.frameLayoutGuide.leadingAnchor, constant: 24),
            mainStack.trailingAnchor.constraint(equalTo: headerColumn.frameLayoutGuide.trailingAnchor, constant: -16),
            mosaicView.heightAnchor.constraint(equalTo: mosaicView.widthAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
        headerLayoutConstraints = constraints
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

    /// Playlist entries that repeat a song an earlier entry already plays, in
    /// any release. The first entry keeps the person's place in the order.
    private func duplicateEntryIDs() -> [Int64] {
        guard let all = try? db.fetchAllTracks() else { return [] }
        let tracksByURL = Dictionary(all.map { ($0.fileURL, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: [String: [TimeInterval]] = [:]
        var ids: [Int64] = []
        for entry in playlistTrackRecords {
            guard let id = entry.id, let record = tracksByURL[entry.trackFileURL] else { continue }
            let track = Track.from(record: record, artwork: nil)
            let key = LibraryHygiene.songKey(title: track.title, artist: track.artist)
            let tolerance = LibraryHygiene.songDurationTolerance
            if seen[key]?.contains(where: { abs($0 - track.duration) <= tolerance }) == true {
                ids.append(id)
            } else {
                seen[key, default: []].append(track.duration)
            }
        }
        return ids
    }

    private func updateOverflowMenu() {
        let duplicates = duplicateEntryIDs()
        let remove = UIAction(
            title: duplicates.isEmpty
                ? String(localized: "No Duplicate Songs")
                : String(localized: "Remove \(duplicates.count) Duplicate Songs"),
            image: UIImage(systemName: "square.on.square"),
            attributes: duplicates.isEmpty ? .disabled : []
        ) { [weak self] _ in
            self?.confirmRemoval(of: duplicates)
        }
        var coverActions = [UIAction(
            title: String(localized: "Edit Cover…"),
            image: UIImage(systemName: "photo")
        ) { [weak self] _ in
            self?.presentCoverEditor()
        }]
        if AlbumArtworkEditor.hasCustomCover(coverSubject) {
            coverActions.append(UIAction(
                title: String(localized: "Use Automatic Cover"),
                image: UIImage(systemName: "arrow.uturn.backward")
            ) { [weak self] _ in
                self?.confirmAutomaticCover()
            })
        }
        let coverMenu = UIMenu(options: .displayInline, children: coverActions)
        let menuButton = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: [coverMenu, remove])
        )
        menuButton.accessibilityLabel = String(localized: "More")
        navigationItem.rightBarButtonItems = [editButtonItem, menuButton]
    }

    private func confirmRemoval(of ids: [Int64]) {
        let alert = UIAlertController(
            title: String(localized: "Remove \(ids.count) Duplicate Songs?"),
            message: String(localized: "Each song stays in the playlist once, at its first position. Your files are not deleted."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Remove"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            do {
                for id in ids { try self.db.removeTrackFromPlaylist(id: id) }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                self.loadTracks()
                ToastView.show(String(localized: "Removed \(ids.count) duplicates"), in: self.view, style: .success)
            } catch {
                MidgarLog.error("Failed to remove duplicates: \(error.localizedDescription)", category: .database)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        })
        present(alert, animated: true)
    }

    private func loadTracks() {
        do {
            playlistTrackRecords = try db.fetchPlaylistTracks(playlistId: playlistId)
            let allDBTracks = try db.fetchAllTracks()
            let tracksByURL = Dictionary(allDBTracks.map { ($0.fileURL, $0) }, uniquingKeysWith: { first, _ in first })

            tracks = playlistTrackRecords.compactMap { playlistTrack in
                guard let record = tracksByURL[playlistTrack.trackFileURL] else { return nil }
                return Track.from(record: record, artwork: nil)
            }

            tableView.reloadData()
            updateMosaic()
            updateOverflowMenu()
            hasLoadedOnce = true
        } catch {
            MidgarLog.error("Failed to load playlist tracks: \(error.localizedDescription)", category: .database)
        }
    }

    /// Shows the picture the person chose when there is one, and otherwise
    /// resolves up to four distinct album thumbnails through AlbumArtworkCache
    /// and applies them once every load lands, discarding results superseded
    /// by a newer refresh.
    private func updateMosaic() {
        mosaicGeneration += 1
        let generation = mosaicGeneration
        AlbumArtworkCache.shared.loadArtwork(
            forAlbum: PlaylistCover.title(forPlaylist: playlistId), artist: PlaylistCover.artist
        ) { [weak self] custom in
            guard let self, self.mosaicGeneration == generation else { return }
            if let custom {
                self.applyMosaicCovers([custom], isCustom: true)
            } else {
                self.updateAutomaticMosaic(generation: generation)
            }
        }
    }

    private func updateAutomaticMosaic(generation: Int) {
        let albumKeys = PlaylistCover.mosaicAlbums(tracks.map { (title: $0.albumTitle, artist: $0.artist) })
        guard !albumKeys.isEmpty else {
            applyMosaicCovers([], isCustom: false)
            return
        }
        var coversByIndex = [Int: UIImage]()
        var remaining = albumKeys.count
        for (index, key) in albumKeys.enumerated() {
            AlbumArtworkCache.shared.loadThumbnail(forAlbum: key.title, artist: key.artist) { [weak self] image in
                guard let self, self.mosaicGeneration == generation else { return }
                if let image { coversByIndex[index] = image }
                remaining -= 1
                if remaining == 0 {
                    self.applyMosaicCovers(albumKeys.indices.compactMap { coversByIndex[$0] }, isCustom: false)
                }
            }
        }
    }

    private func applyMosaicCovers(_ covers: [UIImage], isCustom: Bool) {
        let apply = { self.mosaicView.setCovers(covers) }
        if hasLoadedOnce, !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(with: mosaicView, duration: 0.3, options: [.transitionCrossDissolve, .beginFromCurrentState], animations: apply)
        } else {
            apply()
        }
        if isCustom {
            mosaicView.artworkLabel = String(localized: "Playlist artwork")
        } else {
            mosaicView.artworkLabel = covers.isEmpty
                ? String(localized: "Playlist artwork placeholder")
                : String(localized: "Playlist artwork, \(covers.count) album covers")
        }
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
        let track = tracks[indexPath.row]
        cell.configure(
            with: track,
            isPlaying: AudioPlayer.shared.currentTrack?.fileURL == track.fileURL
        )
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
            MidgarLog.error("Failed to remove track from playlist: \(error.localizedDescription)", category: .database)
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
                MidgarLog.error("Failed to reorder playlist track: \(error.localizedDescription)", category: .database)
            }
        }
        updateMosaic()
        impactLight.impactOccurred()
    }
}

private final class PlaylistTrackCell: UITableViewCell {

    static let reuseID = "PlaylistTrackCell"

    private let titleLabel = UILabel()
    private lazy var titleRow = TitleWithChipView(titleLabel: titleLabel)
    private let artistLabel = UILabel()
    private let durationLabel = UILabel()
    private let barsView = NowPlayingBarsView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true

        artistLabel.font = .preferredFont(forTextStyle: .caption1)
        artistLabel.adjustsFontForContentSizeCategory = true
        artistLabel.textColor = .secondaryLabel

        durationLabel.font = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 13, weight: .regular))
        durationLabel.adjustsFontForContentSizeCategory = true
        durationLabel.textColor = .tertiaryLabel
        durationLabel.textAlignment = .right

        let infoStack = UIStackView(arrangedSubviews: [titleRow, artistLabel])
        infoStack.axis = .vertical
        infoStack.spacing = 2

        barsView.isHidden = true
        barsView.tintColor = .tintColor
        barsView.setContentHuggingPriority(.required, for: .horizontal)
        barsView.widthAnchor.constraint(equalToConstant: 14).isActive = true

        let stack = UIStackView(arrangedSubviews: [barsView, infoStack, durationLabel])
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

    func configure(with track: Track, isPlaying: Bool) {
        titleLabel.text = track.title
        artistLabel.text = track.artist
        let newMix = track.showsNewMix
        titleRow.setNewMix(newMix)
        accessibilityLabel = newMix ? TrackVersionCopy.accessibilityLabel("\(track.title), \(track.artist)", newMix: true) : nil
        let total = Int(track.duration)
        durationLabel.text = String(format: "%d:%02d", total / 60, total % 60)
        titleLabel.textColor = isPlaying ? .tintColor : .label
        barsView.isHidden = !isPlaying
        barsView.setAnimating(isPlaying && AudioPlayer.shared.isPlaying)
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
                title: String(localized: "Remove from Playlist"),
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
            MidgarLog.error("Failed to remove track from playlist: \(error.localizedDescription)", category: .database)
        }
    }
}

/// A stacked-artwork mosaic that lays out up to four distinct covers:
/// a 2x2 grid for four, a large-plus-column split for three, side-by-side
/// halves for two, a single full-bleed cover for one, and a music.note
/// placeholder tile when the playlist has no artwork at all. It serves the
/// detail page's cover and, smaller and without a shadow, the playlists
/// list's thumbnails.
final class StackedArtworkMosaicView: UIView {

    private let contentContainer = UIView()
    private let cornerRadius: CGFloat
    private let showsShadow: Bool
    private let placeholderPointSize: CGFloat

    var artworkLabel: String? {
        get { contentContainer.accessibilityLabel }
        set { contentContainer.accessibilityLabel = newValue }
    }

    var artworkElement: UIView { contentContainer }

    init(cornerRadius: CGFloat = 20, showsShadow: Bool = true, placeholderPointSize: CGFloat = 56) {
        self.cornerRadius = cornerRadius
        self.showsShadow = showsShadow
        self.placeholderPointSize = placeholderPointSize
        super.init(frame: .zero)
        if showsShadow {
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.25
            layer.shadowOffset = CGSize(width: 0, height: 10)
            layer.shadowRadius = 24
        }

        contentContainer.layer.cornerRadius = cornerRadius
        contentContainer.layer.cornerCurve = .continuous
        contentContainer.clipsToBounds = true
        contentContainer.backgroundColor = .secondarySystemBackground
        contentContainer.isAccessibilityElement = true
        contentContainer.accessibilityTraits = .image
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
        if showsShadow {
            layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: cornerRadius).cgPath
        }
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
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: placeholderPointSize, weight: .thin)
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
