import FlaccyCore
import GRDB
import MidgarCore
import UIKit

/// A playlist's page on the iPhone and iPad. The database is its one source:
/// it observes the playlist's songs, so an edit made here, by a drop, on
/// another screen or by a server sync lands the same way, animated. Songs move
/// by a long press and a drag, leave by a swipe or a selection with Undo, and
/// come in from the Add Songs sheet or the Suggested Songs shelf under the
/// list. Each playlist keeps its own order on this device, and a search finds
/// songs inside it.
final class PlaylistDetailViewController: UIViewController, SonglinkShareable {

    nonisolated enum Section: Hashable, Sendable {
        case songs
        case suggestions
    }

    nonisolated enum Item: Hashable, Sendable {
        case entry(Int64)
        case suggestion(String)
    }

    /// One song of the playlist: its entry, the file it names and the song
    /// the library has for it, or nil when the library lost it.
    struct Row: Equatable {
        let entryId: Int64
        let file: String
        let track: Track?
    }

    let playlistId: Int64
    var playlistName: String
    let audioPlayer: AudioPlaying
    let db = DatabaseManager.shared
    let impactLight = UIImpactFeedbackGenerator(style: .light)
    let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    let selectionFeedback = UISelectionFeedbackGenerator()

    var tableView: UITableView!
    var dataSource: PlaylistTableDataSource!
    var rows: [Row] = []
    var shownRows: [Row] = []
    var rowsById: [Int64: Row] = [:]
    var suggestions: [Track] = []
    var suggestionsPage = 0
    var suggestionsTask: Task<Void, Never>?
    var suggestionsBasis: Set<String> = []
    var order: PlaylistSongOrder
    var query = ""
    var hasLoadedOnce = false

    let mosaicView = StackedArtworkMosaicView()
    let editCoverButton = UIButton(type: .custom)
    let nameButton = UIButton(type: .system)
    let summaryLabel = UILabel()
    let sortNoteButton = UIButton(type: .system)
    let infoStack = UIStackView()
    let buttonStack = UIStackView()
    private let headerColumn = UIScrollView()
    private var headerLayoutConstraints: [NSLayoutConstraint] = []
    private var appliedHeaderStyle: AdaptiveLayout.DetailHeaderStyle?
    private var appliedHeaderFold: ClosedRange<CGFloat>?
    private var tableLeading: NSLayoutConstraint!
    private var tableColumnLeading: NSLayoutConstraint!
    private var hasAnimatedAppearance = false
    private var mosaicGeneration = 0
    private var mosaicAlbumKeys: [String] = []
    private var entriesToken: AnyDatabaseCancellable?
    private var playlistsToken: AnyDatabaseCancellable?
    let emptyFooter = PlaylistEmptyFooterView()
    let selectionBar = PlaylistSelectionBar()
    let searchController = UISearchController(searchResultsController: nil)

    init(playlistId: Int64, playlistName: String, audioPlayer: AudioPlaying = AudioPlayer.shared) {
        self.playlistId = playlistId
        self.playlistName = playlistName
        self.audioPlayer = audioPlayer
        self.order = PlaylistSongOrder.saved(for: playlistId)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        setupSearch()
        setupTableView()
        updateBarItems()
        observe()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(playbackChanged), name: AudioPlayer.trackDidChange, object: nil)
        center.addObserver(self, selector: #selector(playbackChanged), name: AudioPlayer.playbackStateDidChange, object: nil)
        center.addObserver(self, selector: #selector(artworkChanged), name: AlbumArtworkCache.didChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(libraryRevised), name: Library.tracksRevised, object: nil)
        center.addObserver(self, selector: #selector(libraryRevised), name: RemoteAvailability.didChange, object: nil)
        center.addObserver(self, selector: #selector(suggestionsSettingChanged), name: PlaylistSuggestionsSetting.didChange, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        animateHeaderAppearanceIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isEditing { setEditing(false, animated: false) }
        if isMovingFromParent { suggestionsTask?.cancel() }
    }

    /// Follows the playlist's songs and its name in the database. A playlist
    /// deleted elsewhere closes its page.
    private func observe() {
        entriesToken = db.observePlaylistEntries(playlistId: playlistId) { [weak self] entries in
            self?.apply(entries: entries)
        }
        playlistsToken = db.observePlaylists { [weak self] playlists in
            guard let self else { return }
            guard let playlist = playlists.first(where: { $0.id == self.playlistId }) else {
                self.playlistVanished()
                return
            }
            self.showRenamed(playlist.name)
        }
    }

    private func playlistVanished() {
        guard let navigation = navigationController, navigation.viewControllers.contains(self) else { return }
        if navigation.viewControllers.first !== self {
            if navigation.topViewController === self {
                navigation.popViewController(animated: true)
            } else {
                navigation.viewControllers.removeAll { $0 === self }
            }
        }
    }

    /// Takes a new name given here, elsewhere, by a server sync or another
    /// device.
    func showRenamed(_ name: String) {
        guard name != playlistName else { return }
        playlistName = name
        updateHeaderText()
        updateTitleVisibility()
    }

    private func apply(entries: [PlaylistEntry]) {
        rows = entries.compactMap { entry in
            guard let id = entry.record.id else { return nil }
            return Row(entryId: id, file: entry.record.trackFileURL, track: entry.track.map { Track.from(record: $0, artwork: nil) })
        }
        rowsById = Dictionary(rows.map { ($0.entryId, $0) }, uniquingKeysWith: { first, _ in first })
        refreshShownRows(animated: hasLoadedOnce)
        updateMosaicIfAlbumsChanged()
        reloadSuggestionsIfPlaylistChanged()
        hasLoadedOnce = true
    }

    /// Sorts and searches `rows` into what the page lists, and repaints.
    func refreshShownRows(animated: Bool) {
        var shown = order.sorted(rows, entryId: \.entryId, track: \.track)
        let words = LibrarySearch.Query(query)
        if !words.isEmpty {
            shown = shown.filter { row in
                guard let track = row.track else { return words.matches(fields: [row.file]) }
                return words.matches(fields: [track.title, track.artist, track.albumTitle])
            }
        }
        shownRows = shown
        applySnapshot(animated: animated)
        updateHeaderText()
        updateEmptyFooter()
        updateBarItems()
    }

    func applySnapshot(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.songs])
        snapshot.appendItems(shownRows.map { .entry($0.entryId) }, toSection: .songs)
        if showsSuggestions, !suggestions.isEmpty {
            snapshot.appendSections([.suggestions])
            snapshot.appendItems(suggestions.map { .suggestion(Self.suggestionKey($0)) }, toSection: .suggestions)
        }
        let previous = Set(dataSource.snapshot().itemIdentifiers)
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter(previous.contains))
        dataSource.apply(snapshot, animatingDifferences: animated && !UIAccessibility.isReduceMotionEnabled)
    }

    static func suggestionKey(_ track: Track) -> String { track.fileURL.absoluteString }

    /// The songs the page lists that can play, in the page's order.
    var playableShownTracks: [Track] { shownRows.compactMap(\.track) }

    var allowsReordering: Bool { order == .playlist && query.isEmpty }

    var playbackContext: PlaybackContext { PlaylistCommands.context(id: playlistId, name: playlistName) }


    private func setupTableView() {
        tableView = UITableView(frame: .zero, style: .plain)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.allowsMultipleSelectionDuringEditing = true
        tableView.sectionHeaderTopPadding = 0
        tableView.dragDelegate = self
        tableView.dropDelegate = self
        tableView.dragInteractionEnabled = true
        tableView.keyboardDismissMode = .onDrag
        tableView.register(PlaylistTrackCell.self, forCellReuseIdentifier: PlaylistTrackCell.reuseID)
        tableView.register(PlaylistSuggestionsHeaderView.self, forHeaderFooterViewReuseIdentifier: PlaylistSuggestionsHeaderView.reuseID)
        tableView.accessibilityIdentifier = "playlist.songs"
        dataSource = PlaylistTableDataSource(tableView: tableView) { [weak self] tableView, indexPath, item in
            let cell = tableView.dequeueReusableCell(withIdentifier: PlaylistTrackCell.reuseID, for: indexPath) as! PlaylistTrackCell
            self?.configure(cell, for: item)
            return cell
        }
        dataSource.defaultRowAnimation = .fade
        dataSource.owner = self
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
        emptyFooter.onAddSongs = { [weak self] in self?.presentAddSongs() }
    }

    private func configure(_ cell: PlaylistTrackCell, for item: Item) {
        let current = audioPlayer.currentTrack?.fileURL
        switch item {
        case .entry(let id):
            guard let row = rowsById[id] else { return }
            if let track = row.track {
                cell.configure(with: track, isCurrent: current == track.fileURL, isPlaying: audioPlayer.isPlaying)
            } else {
                cell.configureMissing(file: row.file)
            }
            cell.accessibilityCustomActions = accessibilityActions(for: row)
        case .suggestion(let key):
            guard let track = suggestions.first(where: { Self.suggestionKey($0) == key }) else { return }
            cell.configure(with: track, isCurrent: current == track.fileURL, isPlaying: audioPlayer.isPlaying, isSuggestion: true)
            cell.onAdd = { [weak self] in self?.addSuggestion(track) }
            cell.accessibilityCustomActions = nil
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyHeaderStyle()
        fit(tableView.tableHeaderView) { tableView.tableHeaderView = $0 }
        fit(tableView.tableFooterView) { tableView.tableFooterView = $0 }
    }

    /// Sizes a table header or footer to its content at the table's width.
    private func fit(_ view: UIView?, reassign: (UIView) -> Void) {
        guard let view else { return }
        let size = view.systemLayoutSizeFitting(
            CGSize(width: tableView.bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        guard view.frame.size.height != size.height else { return }
        view.frame.size.height = size.height
        reassign(view)
    }


    private func buildHeaderComponents() {
        mosaicView.translatesAutoresizingMaskIntoConstraints = false
        mosaicView.artworkLabel = String(localized: "Playlist artwork")
        installEditCoverButton()

        var name = UIButton.Configuration.plain()
        name.titleLineBreakMode = .byWordWrapping
        name.contentInsets = .zero
        name.baseForegroundColor = .label
        name.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var updated = attributes
            updated.font = UIFontMetrics(forTextStyle: .title1).scaledFont(for: .systemFont(ofSize: 26, weight: .bold))
            return updated
        }
        nameButton.configuration = name
        nameButton.titleLabel?.numberOfLines = 2
        nameButton.titleLabel?.textAlignment = .center
        nameButton.accessibilityHint = String(localized: "Renames the playlist")
        nameButton.accessibilityTraits = [.header, .button]
        nameButton.addAction(UIAction { [weak self] _ in self?.renameTapped() }, for: .touchUpInside)

        summaryLabel.font = .preferredFont(forTextStyle: .subheadline)
        summaryLabel.adjustsFontForContentSizeCategory = true
        summaryLabel.textColor = .secondaryLabel
        summaryLabel.numberOfLines = 0

        var note = UIButton.Configuration.plain()
        note.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0)
        note.image = UIImage(systemName: "xmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        note.imagePlacement = .trailing
        note.imagePadding = 4
        note.baseForegroundColor = .tintColor
        note.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var updated = attributes
            updated.font = UIFont.preferredFont(forTextStyle: .footnote)
            return updated
        }
        sortNoteButton.configuration = note
        sortNoteButton.isHidden = true
        sortNoteButton.accessibilityHint = PlaylistCopy.backToPlaylistOrder
        sortNoteButton.addAction(UIAction { [weak self] _ in self?.setOrder(.playlist) }, for: .touchUpInside)

        infoStack.axis = .vertical
        infoStack.spacing = 4
        for view in [nameButton, summaryLabel, sortNoteButton] { infoStack.addArrangedSubview(view) }

        let playButton = makeHeaderButton(
            title: String(localized: "Play"), systemImage: "play.fill", accessibilityLabel: String(localized: "Play playlist")
        ) { [weak self] in self?.playTapped(shuffled: false) }
        let shuffleButton = makeHeaderButton(
            title: String(localized: "Shuffle"), systemImage: "shuffle", accessibilityLabel: String(localized: "Shuffle playlist")
        ) { [weak self] in self?.playTapped(shuffled: true) }
        for capsule in [GlassCapsule(hosting: playButton, height: 48), GlassCapsule(hosting: shuffleButton, height: 48)] {
            buttonStack.addArrangedSubview(capsule)
        }
        buttonStack.spacing = 12
        buttonStack.distribution = .fillEqually
        updateHeaderText()
    }

    func updateHeaderText() {
        nameButton.configuration?.title = playlistName
        nameButton.accessibilityLabel = playlistName
        let available = rows.compactMap(\.track)
        summaryLabel.text = PlaylistCopy.summary(
            songs: rows.count, seconds: available.reduce(0) { $0 + $1.duration }, missing: rows.count - available.count
        )
        sortNoteButton.isHidden = order == .playlist
        sortNoteButton.configuration?.title = PlaylistCopy.sortedBy(order.title)
        for case let capsule as GlassCapsule in buttonStack.arrangedSubviews {
            capsule.alpha = available.isEmpty ? 0.45 : 1
        }
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
            systemName: "pencil", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
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

    /// Stacked is the phone column. The banner sets a modest cover beside the
    /// name and play buttons so rows start high on a wider page. Side by side
    /// pins the cover, name and buttons in a column and gives the other half
    /// to the songs; with a fold running down the page the column ends where
    /// it begins.
    private func applyHeaderStyle() {
        let usable = view.safeAreaLayoutGuide.layoutFrame.size
        guard usable.width > 1 else { return }
        let style = AdaptiveLayout.detailHeaderStyle(forSize: usable)
        let fold = view.verticalFoldSpan
        guard style != appliedHeaderStyle || (style == .sideBySide && fold != appliedHeaderFold) else { return }
        appliedHeaderStyle = style
        appliedHeaderFold = fold
        NSLayoutConstraint.deactivate(headerLayoutConstraints)
        headerLayoutConstraints = []
        headerColumn.removeFromSuperview()
        tableView.tableHeaderView = nil
        for view in [mosaicView, infoStack, buttonStack] { view.removeFromSuperview() }
        buttonStack.axis = style == .stacked ? .horizontal : .vertical
        let centered = style == .stacked
        infoStack.alignment = centered ? .center : .leading
        summaryLabel.textAlignment = centered ? .center : .natural
        nameButton.titleLabel?.textAlignment = centered ? .center : .natural
        nameButton.contentHorizontalAlignment = centered ? .center : .leading

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
        let mainStack = UIStackView(arrangedSubviews: [mosaicView, infoStack, buttonStack])
        mainStack.axis = .vertical
        mainStack.spacing = 16
        mainStack.setCustomSpacing(20, after: infoStack)
        mainStack.alignment = .center
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(mainStack)
        let guide = container.safeAreaLayoutGuide
        let leading = mainStack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24)
        let trailing = mainStack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24)
        let bottom = mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        let buttonWidth = buttonStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
        let infoWidth = infoStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
        let mosaicWidth = mosaicView.widthAnchor.constraint(equalTo: mainStack.widthAnchor, multiplier: 0.62)
        for constraint in [leading, trailing, bottom, buttonWidth, infoWidth, mosaicWidth] { constraint.priority = .defaultHigh }
        let constraints = [
            mainStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            leading, trailing, bottom, buttonWidth, infoWidth, mosaicWidth,
            mosaicView.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
            mosaicView.heightAnchor.constraint(equalTo: mosaicView.widthAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
        headerLayoutConstraints = constraints
        tableView.tableHeaderView = container
    }

    private func installBannerHeader(width: CGFloat) {
        let container = UIView()
        let side = min(max(width * 0.3, 120), 200)
        let details = UIStackView(arrangedSubviews: [infoStack, buttonStack])
        details.axis = .vertical
        details.spacing = 16
        details.alignment = .fill
        let row = UIStackView(arrangedSubviews: [mosaicView, details])
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
        let insets = view.safeAreaInsets
        let fold = AdaptiveLayout.foldHalves(
            content: insets.left...(view.bounds.width - insets.right), fold: view.verticalFoldSpan,
            leadingMinimum: 260, trailingMinimum: 260
        )
        let side = min((fold?.leading ?? max(size.width * 0.4, 240)) - 40, size.height * 0.5, 320)
        let columnWidth = fold?.leading ?? max(side + 40, 260)
        tableColumnLeading.constant = fold?.gap ?? 0
        headerColumn.translatesAutoresizingMaskIntoConstraints = false
        headerColumn.showsVerticalScrollIndicator = false
        headerColumn.alwaysBounceVertical = false
        headerColumn.contentInsetAdjustmentBehavior = .always
        view.addSubview(headerColumn)
        let mainStack = UIStackView(arrangedSubviews: [mosaicView, infoStack, buttonStack])
        mainStack.axis = .vertical
        mainStack.spacing = 16
        mainStack.setCustomSpacing(20, after: infoStack)
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
        title: String, systemImage: String, accessibilityLabel: String, action: @escaping () -> Void
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
        UIViewPropertyAnimator(duration: 0.32, dampingRatio: 0.84) {
            header.alpha = 1
            header.transform = .identity
        }.startAnimation()
    }

    /// The navigation bar names the playlist once its big name has scrolled
    /// away, as Music does.
    func updateTitleVisibility() {
        guard isViewLoaded, nameButton.window != nil else {
            navigationItem.title = isEditing ? navigationItem.title : nil
            return
        }
        guard !isEditing else { return }
        let frame = nameButton.convert(nameButton.bounds, to: view)
        let barBottom = view.safeAreaInsets.top
        navigationItem.title = appliedHeaderStyle == .sideBySide || frame.maxY > barBottom ? nil : playlistName
    }

    func updateEmptyFooter() {
        let footer: UIView?
        if rows.isEmpty {
            emptyFooter.show(title: PlaylistCopy.emptyTitle, message: PlaylistCopy.emptyMessage, offersAdd: true)
            footer = emptyFooter
        } else if shownRows.isEmpty, !query.isEmpty {
            emptyFooter.show(title: String(localized: "No Results"), message: String(localized: "No songs in this playlist match \u{201C}\(query)\u{201D}."), offersAdd: false)
            footer = emptyFooter
        } else {
            footer = nil
        }
        guard tableView.tableFooterView !== footer else {
            view.setNeedsLayout()
            return
        }
        tableView.tableFooterView = footer
        view.setNeedsLayout()
    }


    var coverSubject: ArtworkSubject {
        ArtworkSubject(playlistId: playlistId, name: playlistName, tracks: rows.compactMap(\.track))
    }

    func presentCoverEditor() {
        ArtworkEditorViewController.present(for: coverSubject, from: self) { [weak self] in
            guard let self else { return }
            ToastView.show(String(localized: "Artwork updated"), in: self.view, style: .success)
        }
    }

    func confirmAutomaticCover() {
        ArtworkEditorViewController.confirmReset(for: coverSubject, from: self, anchor: nil) { [weak self] in
            guard let self else { return }
            ArtworkEditorViewController.reset(self.coverSubject) { [weak self] succeeded in
                guard succeeded, let self else { return }
                ToastView.show(String(localized: "Automatic cover restored"), in: self.view, style: .success)
            }
        }
    }

    private func updateMosaicIfAlbumsChanged() {
        let keys = PlaylistCover.mosaicAlbums(rows.compactMap(\.track).map { (title: $0.albumTitle, artist: $0.artist) })
            .map { $0.title + "\u{0}" + $0.artist }
        guard keys != mosaicAlbumKeys || !hasLoadedOnce else { return }
        mosaicAlbumKeys = keys
        updateMosaic()
    }

    /// Shows the picture the person chose when there is one, and otherwise
    /// resolves up to four distinct album thumbnails through AlbumArtworkCache
    /// and applies them once every load lands, discarding results superseded
    /// by a newer refresh.
    func updateMosaic() {
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
        let albumKeys = PlaylistCover.mosaicAlbums(rows.compactMap(\.track).map { (title: $0.albumTitle, artist: $0.artist) })
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


    func playTapped(shuffled: Bool) {
        let tracks = playableShownTracks
        guard !tracks.isEmpty else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        impactMedium.impactOccurred()
        audioPlayer.play(shuffled ? tracks.shuffled() : tracks, startingAt: 0, context: playbackContext)
    }

    func play(from row: Row) {
        let playable = shownRows.filter { $0.track != nil }
        guard let index = playable.firstIndex(where: { $0.entryId == row.entryId }) else { return }
        let tracks = playable.compactMap(\.track)
        impactLight.impactOccurred()
        audioPlayer.play(tracks, startingAt: index, context: playbackContext)
    }

    /// Repaints the visible rows so the playing one lights up.
    @objc private func playbackChanged() {
        reconfigureVisibleRows()
    }

    /// Repaints the visible rows so a song re-exported or downloaded while
    /// the playlist is open shows its chip.
    @objc private func libraryRevised() {
        reconfigureVisibleRows()
    }

    func reconfigureVisibleRows() {
        guard let visible = tableView.indexPathsForVisibleRows, !visible.isEmpty else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(visible.compactMap { dataSource.itemIdentifier(for: $0) })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Repaints the cover and the menu after a picture was chosen or cleared,
    /// here or in the playlists list.
    @objc private func artworkChanged() {
        updateMosaic()
        updateBarItems()
    }


    private func setupSearch() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = PlaylistCopy.searchPlaceholder
        searchController.searchBar.accessibilityIdentifier = "playlist.search"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = true
        navigationItem.preferredSearchBarPlacement = .stacked
    }
}

extension PlaylistDetailViewController: UISearchResultsUpdating {

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard text != query else { return }
        query = text
        refreshShownRows(animated: false)
        reloadSuggestionsIfPlaylistChanged()
    }
}

#if DEBUG
extension PlaylistDetailViewController {

    /// The page's cover as it is on screen.
    func debugCoverSnapshot() -> CGImage? {
        guard mosaicView.bounds.width > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(bounds: mosaicView.bounds, format: format)
        return renderer.image { _ in
            mosaicView.drawHierarchy(in: mosaicView.bounds, afterScreenUpdates: true)
        }.cgImage
    }
}
#endif
