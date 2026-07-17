import AppKit
import Combine

/// The album wall: a diffable NSCollectionView over the shared
/// LibraryViewModel with its full sort/filter/search pipeline, a resizable
/// cover zoom, type-select, context menus, and a Recently Played shelf when
/// the default browse state is active.
final class AlbumGridViewController: NSViewController {

    var onOpenAlbum: ((Album) -> Void)?

    private let viewModel = LibraryViewModel()
    private let scrollView = NSScrollView()
    private let collectionView = TypeSelectCollectionView()
    private let layout = NSCollectionViewFlowLayout()
    private let chipsBar = FilterChipsBar()
    private let sortPopUp = NSPopUpButton()
    private let zoomSlider = NSSlider()
    private let emptyStateView = LibraryEmptyStateView()
    private var dataSource: NSCollectionViewDiffableDataSource<Int, LibraryItem>?
    private var cancellables = Set<AnyCancellable>()
    private var hasMultipleSections = false

    private static let zoomKey = "flaccy.mac.albumGridZoom"
    private static let zoomRange: ClosedRange<Double> = 140...260

    private var tileWidth: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: Self.zoomKey)
            let width = stored == 0 ? 184 : stored
            return CGFloat(width.clamped(to: Self.zoomRange))
        }
        set {
            UserDefaults.standard.set(Double(newValue).clamped(to: Self.zoomRange), forKey: Self.zoomKey)
        }
    }

    override func loadView() {
        view = NSView()

        layout.minimumInteritemSpacing = 20
        layout.minimumLineSpacing = 24
        layout.sectionInset = NSEdgeInsets(top: 16, left: 28, bottom: 24, right: 28)

        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            AlbumGridItem.self, forItemWithIdentifier: AlbumGridItem.identifier
        )
        collectionView.register(
            GridSectionHeaderView.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: GridSectionHeaderView.identifier
        )
        collectionView.onTypeAhead = { [weak self] prefix in
            self?.jumpToPrefix(prefix)
        }
        collectionView.onMagnify = { [weak self] magnification in
            guard let self else { return }
            self.setZoom(self.tileWidth * (1 + magnification))
        }

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let controls = buildControlsBar()
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)
        view.addSubview(scrollView)

        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.isHidden = true
        view.addSubview(emptyStateView)

        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            controls.heightAnchor.constraint(equalToConstant: 28),

            scrollView.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureDataSource()
        applyTileSize()
        chipsBar.configure(filters: viewModel.availableFilters(), selected: viewModel.filter)
        selectSortItem(viewModel.albumSort)

        viewModel.snapshotPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.apply(snapshot, animated: true)
            }
            .store(in: &cancellables)
        viewModel.loadingPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loading in
                self?.emptyStateView.setLoading(loading)
                self?.refreshEmptyState()
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self, selector: #selector(searchQueryChanged(_:)), name: .flaccySearchQueryChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(lovedDidChange), name: LovedTracksService.didChange, object: nil
        )

        if !LibrarySearchState.query.isEmpty {
            viewModel.search(query: LibrarySearchState.query)
        }
        apply(viewModel.currentSnapshot(), animated: false)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func buildControlsBar() -> NSView {
        chipsBar.onSelect = { [weak self] filter in
            self?.viewModel.setFilter(filter)
        }

        sortPopUp.controlSize = .small
        sortPopUp.font = .systemFont(ofSize: 11.5)
        for sort in LibraryViewModel.AlbumSort.allCases {
            sortPopUp.addItem(withTitle: sort.displayName)
            sortPopUp.lastItem?.representedObject = sort.rawValue
        }
        sortPopUp.target = self
        sortPopUp.action = #selector(sortChanged(_:))
        sortPopUp.toolTip = "Sort albums"

        let sortLabel = NSTextField(labelWithString: "Sort")
        sortLabel.font = .systemFont(ofSize: 11)
        sortLabel.textColor = .secondaryLabelColor

        let zoomOut = NSImageView(image: NSImage(
            systemSymbolName: "square.grid.3x3", accessibilityDescription: "Smaller covers"
        ) ?? NSImage())
        zoomOut.symbolConfiguration = .init(pointSize: 10, weight: .medium)
        zoomOut.contentTintColor = .secondaryLabelColor
        let zoomIn = NSImageView(image: NSImage(
            systemSymbolName: "square.grid.2x2", accessibilityDescription: "Larger covers"
        ) ?? NSImage())
        zoomIn.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        zoomIn.contentTintColor = .secondaryLabelColor

        zoomSlider.minValue = Self.zoomRange.lowerBound
        zoomSlider.maxValue = Self.zoomRange.upperBound
        zoomSlider.doubleValue = Double(tileWidth)
        zoomSlider.controlSize = .small
        zoomSlider.target = self
        zoomSlider.action = #selector(zoomChanged(_:))
        zoomSlider.toolTip = "Cover size"
        zoomSlider.widthAnchor.constraint(equalToConstant: 110).isActive = true

        let bar = NSStackView(views: [chipsBar, sortLabel, sortPopUp, zoomOut, zoomSlider, zoomIn])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.alignment = .centerY
        bar.setHuggingPriority(.defaultLow, for: .horizontal)
        chipsBar.setContentHuggingPriority(.init(1), for: .horizontal)
        return bar
    }

    private func configureDataSource() {
        let dataSource = NSCollectionViewDiffableDataSource<Int, LibraryItem>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, item in
            let cell = collectionView.makeItem(
                withIdentifier: AlbumGridItem.identifier, for: indexPath
            )
            guard let self, let gridItem = cell as? AlbumGridItem,
                  let album = Self.album(from: item) else { return cell }
            gridItem.configure(with: album, loved: self.viewModel.isLovedAlbum(album))
            gridItem.onDoubleClick = { [weak self] in self?.play(album) }
            gridItem.onOpen = { [weak self] in
                guard let self else { return }
                self.onOpenAlbum?(self.resolvedAlbum(album))
            }
            gridItem.onMenu = { [weak self, weak gridItem] in
                guard let self else { return nil }
                let selected = self.collectionView.selectionIndexPaths
                if selected.count > 1,
                   let indexPath = self.dataSource?.indexPath(for: item),
                   selected.contains(indexPath) {
                    return self.bulkMenu(for: self.selectedAlbums())
                }
                return MacTrackMenuFactory.menu(for: self.resolvedAlbum(album), anchor: gridItem?.view)
            }
            return cell
        }
        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            let header = collectionView.makeSupplementaryView(
                ofKind: kind, withIdentifier: GridSectionHeaderView.identifier, for: indexPath
            )
            guard let headerView = header as? GridSectionHeaderView else {
                return GridSectionHeaderView()
            }
            headerView.title = self?.hasMultipleSections == true
                ? (indexPath.section == 0 ? "Recently Played" : "All Albums")
                : ""
            return headerView
        }
        self.dataSource = dataSource
    }

    private static func album(from item: LibraryItem) -> Album? {
        switch item {
        case .album(let album), .recentAlbum(let album): album
        default: nil
        }
    }

    private func apply(_ snapshot: LibraryViewModel.Snapshot, animated: Bool) {
        guard viewModel.currentSegment == .albums else { return }
        hasMultipleSections = snapshot.sectionIdentifiers.count > 1
        layout.headerReferenceSize = hasMultipleSections ? NSSize(width: 0, height: 34) : .zero
        dataSource?.apply(snapshot, animatingDifferences: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        refreshEmptyState()
        AppLogger.debug("Album grid showing \(snapshot.numberOfItems) items", category: .ui)
    }

    private func refreshEmptyState() {
        switch viewModel.emptyState {
        case .none:
            emptyStateView.isHidden = true
        case .noLibrary:
            emptyStateView.isHidden = OnboardingPanelView.visibility != .hide
                || (Library.shared.isLoading && !Library.shared.albums.isEmpty)
            emptyStateView.showNoLibrary()
        case .noSearchResults(let query):
            emptyStateView.isHidden = false
            emptyStateView.showNoResults(query: query)
        }
    }

    @objc private func sortChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let sort = LibraryViewModel.AlbumSort(rawValue: raw) else { return }
        viewModel.setAlbumSort(sort)
        collectionView.scroll(.zero)
        AppLogger.info("Album sort changed to \(sort.displayName)", category: .ui)
    }

    @objc private func zoomChanged(_ sender: NSSlider) {
        setZoom(CGFloat(sender.doubleValue))
    }

    @objc private func searchQueryChanged(_ notification: Notification) {
        let query = notification.userInfo?[LibraryNavigator.Key.query] as? String ?? ""
        viewModel.search(query: query)
    }

    @objc private func lovedDidChange() {
        for case let item as AlbumGridItem in collectionView.visibleItems() {
            guard let indexPath = collectionView.indexPath(for: item),
                  let libraryItem = dataSource?.itemIdentifier(for: indexPath),
                  let album = Self.album(from: libraryItem) else { continue }
            item.setLoved(viewModel.isLovedAlbum(album))
        }
        if viewModel.filter == .favorites {
            viewModel.refilter()
        }
    }

    private func setZoom(_ width: CGFloat) {
        let clamped = CGFloat(Double(width).clamped(to: Self.zoomRange))
        guard abs(clamped - tileWidth) > 0.5 else { return }
        tileWidth = clamped
        zoomSlider.doubleValue = Double(clamped)
        applyTileSize()
    }

    private func applyTileSize() {
        layout.itemSize = NSSize(width: tileWidth, height: tileWidth + 46)
        layout.invalidateLayout()
    }

    private func selectSortItem(_ sort: LibraryViewModel.AlbumSort) {
        let index = sortPopUp.itemArray.firstIndex { ($0.representedObject as? String) == sort.rawValue }
        if let index { sortPopUp.selectItem(at: index) }
    }

    private func jumpToPrefix(_ prefix: String) {
        guard let dataSource else { return }
        let snapshot = dataSource.snapshot()
        let byArtist = viewModel.albumSort == .artist
        for section in snapshot.sectionIdentifiers {
            guard !hasMultipleSections || section != 0 else { continue }
            for (row, item) in snapshot.itemIdentifiers(inSection: section).enumerated() {
                guard let album = Self.album(from: item) else { continue }
                let key = byArtist ? album.artist : album.title
                if key.lowercased().hasPrefix(prefix.lowercased()) {
                    let indexPath = IndexPath(item: row, section: section)
                    collectionView.deselectItems(at: collectionView.selectionIndexPaths)
                    collectionView.selectItems(at: [indexPath], scrollPosition: .top)
                    return
                }
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn,
           let indexPath = collectionView.selectionIndexPaths.first,
           let item = dataSource?.itemIdentifier(for: indexPath),
           let album = Self.album(from: item) {
            play(album)
            return
        }
        super.keyDown(with: event)
    }

    private func play(_ album: Album) {
        let resolved = resolvedAlbum(album)
        guard !resolved.tracks.isEmpty else { return }
        AppLogger.info("Playing album \(resolved.title) — \(resolved.artist)", category: .playback)
        AudioPlayer.shared.play(resolved.tracks, startingAt: 0)
    }

    private func selectedAlbums() -> [Album] {
        guard let dataSource else { return [] }
        return collectionView.selectionIndexPaths.sorted().compactMap { indexPath in
            dataSource.itemIdentifier(for: indexPath).flatMap(Self.album(from:)).map(resolvedAlbum)
        }
    }

    private func bulkMenu(for albums: [Album]) -> NSMenu {
        let tracks = albums.flatMap(\.tracks)
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Play \(albums.count) Albums", systemImage: "play.fill") {
            guard !tracks.isEmpty else { return }
            AudioPlayer.shared.play(tracks, startingAt: 0)
        })
        menu.addItem(ClosureMenuItem(title: "Add \(tracks.count) Songs to Queue", systemImage: "text.append") {
            tracks.forEach { AudioPlayer.shared.addToQueue($0) }
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Love All", systemImage: "heart.fill") {
            Task {
                for track in tracks where !LovedTracksService.shared.isLoved(track: track) {
                    _ = await LovedTracksService.shared.toggleLove(track: track)
                }
            }
        })
        return menu
    }

    /// Album identity is title+artist only, so a cell configured before a
    /// library reload can hold a stale track list; actions re-resolve against
    /// the live library before playing or opening.
    private func resolvedAlbum(_ album: Album) -> Album {
        Library.shared.albums.first { $0 == album } ?? album
    }
}

/// Collection view adding type-select and pinch-zoom hooks over the diffable
/// grid; unhandled keys still bubble to the controller for Return-to-play.
final class TypeSelectCollectionView: NSCollectionView {

    var onTypeAhead: ((String) -> Void)?
    var onMagnify: ((CGFloat) -> Void)?

    private var buffer = ""
    private var resetTask: Task<Void, Never>?

    deinit {
        resetTask?.cancel()
    }

    override func keyDown(with event: NSEvent) {
        if let characters = event.charactersIgnoringModifiers,
           !characters.isEmpty,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           characters.rangeOfCharacter(from: .alphanumerics) != nil {
            buffer += characters.lowercased()
            onTypeAhead?(buffer)
            scheduleBufferReset()
            return
        }
        super.keyDown(with: event)
    }

    override func magnify(with event: NSEvent) {
        onMagnify?(event.magnification)
    }

    private func scheduleBufferReset() {
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.buffer = ""
        }
    }
}

final class GridSectionHeaderView: NSView, NSCollectionViewElement {

    static let identifier = NSUserInterfaceItemIdentifier("GridSectionHeaderView")

    private let label = NSTextField(labelWithString: "")

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 15, weight: .bold)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Empty and no-results states for the library browsing surfaces.
final class LibraryEmptyStateView: NSView {

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let buttons = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        icon.symbolConfiguration = .init(pointSize: 46, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor

        title.font = .systemFont(ofSize: 22, weight: .semibold)
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 2
        subtitle.preferredMaxLayoutWidth = 340

        let chooseButton = NSButton(
            title: "Choose Music Folder…",
            target: nil,
            action: #selector(MacAppDelegate.chooseMusicFolder(_:))
        )
        chooseButton.bezelStyle = .glass
        chooseButton.controlSize = .large

        let importButton = NSButton(
            title: "Import Files…",
            target: nil,
            action: #selector(MacAppDelegate.importFiles(_:))
        )
        importButton.bezelStyle = .glass
        importButton.controlSize = .large

        buttons.setViews([chooseButton, importButton], in: .center)
        buttons.orientation = .horizontal
        buttons.spacing = 12

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let stack = NSStackView(views: [icon, title, subtitle, buttons, spinner])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        showNoLibrary()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showNoLibrary() {
        icon.image = NSImage(systemSymbolName: "music.note.house", accessibilityDescription: nil)
        title.stringValue = "Your library is empty"
        subtitle.stringValue = "Choose a music folder to index in place, or import files into Flaccy's own library."
        buttons.isHidden = false
    }

    func showNoResults(query: String) {
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        title.stringValue = "No Results"
        subtitle.stringValue = "Nothing in your library matches \u{201C}\(query)\u{201D}."
        buttons.isHidden = true
    }

    func setLoading(_ loading: Bool) {
        if loading {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
