import AppKit
import MidgarCore
import Combine
import FlaccyCore

/// The Albums page: a diffable NSCollectionView over the shared
/// LibraryViewModel with its full sort/filter/search pipeline, shown as a
/// grid, a wall of bare covers, a list or a carousel (the worn theme's choice
/// until the person switches it), with a resizable cover zoom, type-select,
/// context menus, and a Recently Played shelf over the grid when the default
/// browse state is active.
final class AlbumGridViewController: NSViewController {

    var onOpenAlbum: ((Album) -> Void)?

    private let viewModel = LibraryViewModel()
    private let scrollView = NSScrollView()
    private let collectionView = TypeSelectCollectionView()
    private let layout = NSCollectionViewFlowLayout()
    private let carouselLayout = AlbumCarouselLayout()
    private let chipsBar = FilterChipsBar()
    private let sortPopUp = NSPopUpButton()
    private let zoomSlider = NSSlider()
    private let viewSwitch = NSSegmentedControl()
    private var zoomControls: [NSView] = []
    private var shownView = WornTheme.look.albums
    private var laidOutWidth: CGFloat = 0
    private var settleTask: Task<Void, Never>?
    private let emptyStateView = LibraryEmptyStateView()
    private var dataSource: NSCollectionViewDiffableDataSource<Int, LibraryItem>?
    private var cancellables = Set<AnyCancellable>()
    private var hasMultipleSections = false

    private static let zoomKey = "flaccy.mac.albumGridZoom"
    private static let zoomRange: ClosedRange<Double> = 140...260

    private static let standardTileWidth = 184.0

    /// Forgets the cover size the person set with the slider, so the worn
    /// theme's own size shows again.
    static func forgetZoom() {
        UserDefaults.standard.removeObject(forKey: zoomKey)
    }

    /// Whether the person set a cover size of their own.
    static var hasOwnZoom: Bool {
        UserDefaults.standard.double(forKey: zoomKey) != 0
    }

    /// The cover size the worn theme asks for, on the Mac's scale: a theme
    /// states it against the size Flaccy's own theme has.
    private static var themedTileWidth: Double {
        standardTileWidth * Double(WornTheme.look.coverSize) / Double(ThemePack.coverSizeDefault)
    }

    private var tileWidth: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: Self.zoomKey)
            let width = stored == 0 ? Self.themedTileWidth : stored
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
            AlbumListItem.self, forItemWithIdentifier: AlbumListItem.identifier
        )
        collectionView.delegate = self
        collectionView.onSidewaysWheel = { [weak self] in self?.settleCarouselSoon() }
        collectionView.onStep = { [weak self] step in self?.stepCarousel(by: step) }
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
        collectionView.registerForDraggedTypes(ArtworkInputReader.pasteboardTypes)
        collectionView.onPictureDrop = { [weak self] indexPath, input in
            self?.openArtworkEditor(at: indexPath, initial: input)
        }
        collectionView.onDropTargetChange = { [weak self] previous, current in
            self?.setDropTarget(previous, false)
            self?.setDropTarget(current, true)
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
        showAlbums(as: shownView)
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
            self, selector: #selector(remoteServersChanged), name: RemoteServers.didChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(lovedDidChange), name: LovedTracksService.didChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange), name: WornTheme.didChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollDidEnd), name: NSScrollView.didEndLiveScrollNotification, object: scrollView
        )

        if !LibrarySearchState.query.isEmpty {
            viewModel.search(query: LibrarySearchState.query)
        }
        apply(viewModel.currentSnapshot(), animated: false)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Offers or withdraws the Offline chip as the first server arrives or the last one goes.
    @objc private func remoteServersChanged() {
        viewModel.dropUnofferedFilter()
        chipsBar.configure(filters: viewModel.availableFilters(), selected: viewModel.filter)
    }

    private func buildControlsBar() -> NSView {
        chipsBar.clearChipID = LibraryFilter.all.rawValue
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
        sortPopUp.toolTip = String(localized: "Sort albums")

        let sortLabel = NSTextField(labelWithString: String(localized: "Sort"))
        sortLabel.font = .systemFont(ofSize: 11)
        sortLabel.textColor = .secondaryLabelColor

        let zoomOut = NSImageView(image: NSImage(
            systemSymbolName: "square.grid.3x3", accessibilityDescription: String(localized: "Smaller covers")
        ) ?? NSImage())
        zoomOut.symbolConfiguration = .init(pointSize: 10, weight: .medium)
        zoomOut.contentTintColor = .flaccySecondaryLabel
        let zoomIn = NSImageView(image: NSImage(
            systemSymbolName: "square.grid.2x2", accessibilityDescription: String(localized: "Larger covers")
        ) ?? NSImage())
        zoomIn.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        zoomIn.contentTintColor = .flaccySecondaryLabel

        zoomSlider.minValue = Self.zoomRange.lowerBound
        zoomSlider.maxValue = Self.zoomRange.upperBound
        zoomSlider.doubleValue = Double(tileWidth)
        zoomSlider.controlSize = .small
        zoomSlider.target = self
        zoomSlider.action = #selector(zoomChanged(_:))
        zoomSlider.toolTip = String(localized: "Cover size")
        zoomSlider.widthAnchor.constraint(equalToConstant: 110).isActive = true
        zoomControls = [zoomOut, zoomSlider, zoomIn]
        buildViewSwitch()

        let bar = NSStackView(views: [chipsBar, viewSwitch, sortLabel, sortPopUp, zoomOut, zoomSlider, zoomIn])
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
                withIdentifier: self?.shownView == .list ? AlbumListItem.identifier : AlbumGridItem.identifier,
                for: indexPath
            )
            guard let self, let gridItem = cell as? AlbumCollectionItem,
                  let album = Self.album(from: item) else { return cell }
            (gridItem as? AlbumGridItem)?.isBare = self.shownView == .wall
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
                ? (indexPath.section == 0 ? String(localized: "Recently Played") : String(localized: "All Albums"))
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
        layout.headerReferenceSize = hasMultipleSections && shownView == .grid ? NSSize(width: 0, height: 34) : .zero
        let swapsList = viewModel.snapshotIntent == .replaceList
        dataSource?.apply(
            snapshot,
            animatingDifferences: animated && !swapsList && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        refreshEmptyState()
        MidgarLog.debug("Album grid showing \(snapshot.numberOfItems) items", category: .ui)
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
        MidgarLog.info("Album sort changed to \(sort.displayName)", category: .ui)
    }

    @objc private func zoomChanged(_ sender: NSSlider) {
        setZoom(CGFloat(sender.doubleValue))
    }

    @objc private func searchQueryChanged(_ notification: Notification) {
        let query = notification.userInfo?[LibraryNavigator.Key.query] as? String ?? ""
        viewModel.search(query: query)
    }

    @objc private func lovedDidChange() {
        for case let item as AlbumCollectionItem in collectionView.visibleItems() {
            guard let indexPath = collectionView.indexPath(for: item),
                  let libraryItem = dataSource?.itemIdentifier(for: indexPath),
                  let album = Self.album(from: libraryItem) else { continue }
            item.setLoved(viewModel.isLovedAlbum(album))
        }
        if viewModel.filter == .favorites {
            viewModel.refilter()
        }
    }

    private func openArtworkEditor(at indexPath: IndexPath, initial: ArtworkInput) {
        guard let item = dataSource?.itemIdentifier(for: indexPath), let album = Self.album(from: item) else { return }
        MacArtworkEditor.present(for: resolvedAlbum(album), initial: initial, from: view.window)
    }

    private func setDropTarget(_ indexPath: IndexPath?, _ targeted: Bool) {
        guard let indexPath, let item = collectionView.item(at: indexPath) as? AlbumCollectionItem else { return }
        item.setDropTargeted(targeted)
    }

    private func setZoom(_ width: CGFloat) {
        let clamped = CGFloat(Double(width).clamped(to: Self.zoomRange))
        guard abs(clamped - tileWidth) > 0.5 else { return }
        tileWidth = clamped
        zoomSlider.doubleValue = Double(clamped)
        applyTileSize()
    }

    private static let viewSymbols: [(view: ThemePack.AlbumsView, symbol: String)] = [
        (.grid, "square.grid.2x2"), (.wall, "square.grid.3x3.fill"), (.list, "list.bullet"),
        (.carousel, "rectangle.split.3x1"),
    ]

    private func buildViewSwitch() {
        viewSwitch.segmentCount = Self.viewSymbols.count
        viewSwitch.trackingMode = .selectOne
        viewSwitch.controlSize = .small
        viewSwitch.segmentStyle = .automatic
        for (index, entry) in Self.viewSymbols.enumerated() {
            let name = ThemeCopy.name(of: entry.view)
            viewSwitch.setImage(NSImage(systemSymbolName: entry.symbol, accessibilityDescription: name), forSegment: index)
            viewSwitch.setToolTip(name, forSegment: index)
            viewSwitch.setWidth(30, forSegment: index)
        }
        viewSwitch.target = self
        viewSwitch.action = #selector(viewSwitched(_:))
        viewSwitch.setAccessibilityLabel(ThemeCopy.albumsView)
        viewSwitch.setAccessibilityIdentifier("albums.viewSwitch")
    }

    @objc private func viewSwitched(_ sender: NSSegmentedControl) {
        guard Self.viewSymbols.indices.contains(sender.selectedSegment) else { return }
        let view = Self.viewSymbols[sender.selectedSegment].view
        MidgarLog.info("Albums shown as \(view.id)", category: .ui)
        WornTheme.showAlbums(as: view)
    }

    /// The look changed: the theme may show Albums another way, at another
    /// cover size.
    @objc private func themeDidChange() {
        let view = WornTheme.look.albums
        guard view != shownView else {
            applyTileSize()
            zoomSlider.doubleValue = Double(tileWidth)
            return
        }
        showAlbums(as: view)
        viewModel.refilter()
    }

    /// Lays the page out as `view`: its layout, which controls it offers and
    /// which kind of item shows an album.
    private func showAlbums(as view: ThemePack.AlbumsView) {
        shownView = view
        let carousel = view == .carousel
        viewSwitch.selectedSegment = Self.viewSymbols.firstIndex { $0.view == view } ?? 0
        zoomControls.forEach { $0.isHidden = view == .list || carousel }
        zoomSlider.doubleValue = Double(tileWidth)
        scrollView.hasVerticalScroller = !carousel
        collectionView.scrollsSideways = carousel
        collectionView.allowsMultipleSelection = !carousel
        collectionView.deselectAll(nil)
        let wanted: NSCollectionViewLayout = carousel ? carouselLayout : layout
        if collectionView.collectionViewLayout !== wanted { collectionView.collectionViewLayout = wanted }
        applyTileSize()
        collectionView.reloadData()
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: -scrollView.contentInsets.top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func applyTileSize() {
        let width = scrollView.contentView.bounds.width
        laidOutWidth = width
        switch shownView {
        case .grid:
            layout.minimumInteritemSpacing = 20
            layout.minimumLineSpacing = 24
            layout.sectionInset = NSEdgeInsets(top: 16, left: 28, bottom: 24, right: 28)
            layout.itemSize = NSSize(width: tileWidth, height: tileWidth + 46)
        case .wall:
            let columns = max(2, (width / tileWidth).rounded())
            let side = max((width / columns) - 0.01, 1)
            layout.minimumInteritemSpacing = 0
            layout.minimumLineSpacing = 0
            layout.sectionInset = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            layout.itemSize = NSSize(width: side, height: side)
        case .list:
            layout.minimumInteritemSpacing = 0
            layout.minimumLineSpacing = 2
            layout.sectionInset = NSEdgeInsets(top: 8, left: 20, bottom: 24, right: 20)
            layout.itemSize = NSSize(width: max(width - 40, 1), height: AlbumListItem.rowHeight)
        case .carousel:
            carouselLayout.invalidateLayout()
            return
        }
        layout.invalidateLayout()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard abs(scrollView.contentView.bounds.width - laidOutWidth) > 0.5, shownView != .grid else { return }
        applyTileSize()
    }

    /// The cover the carousel rests on, or is nearest to while it moves.
    private var carouselPlace: Int {
        Int(carouselLayout.position.rounded())
    }

    private func scrollCarousel(to index: Int, animated: Bool) {
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.x = carouselLayout.offset(restingAt: index)
        guard abs(origin.x - clip.bounds.minX) > 0.5 else { return }
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(origin)
            }
        } else {
            clip.setBoundsOrigin(origin)
        }
        scrollView.reflectScrolledClipView(clip)
    }

    /// Brings the carousel to rest on a cover once a scroll has stopped.
    @objc private func scrollDidEnd() {
        guard shownView == .carousel else { return }
        scrollCarousel(to: carouselPlace, animated: true)
    }

    /// A mouse wheel moves the carousel in steps with no end of its own, so
    /// it settles a moment after the last one.
    private func settleCarouselSoon() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            self?.scrollDidEnd()
        }
    }

    private func stepCarousel(by step: Int) {
        guard shownView == .carousel, let dataSource else { return }
        let count = dataSource.snapshot().numberOfItems
        let place = min(max(carouselPlace + step, 0), max(count - 1, 0))
        let indexPath = IndexPath(item: place, section: 0)
        collectionView.deselectAll(nil)
        collectionView.selectItems(at: [indexPath], scrollPosition: [])
        scrollCarousel(to: place, animated: true)
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
                    if shownView == .carousel {
                        collectionView.selectItems(at: [indexPath], scrollPosition: [])
                        scrollCarousel(to: row, animated: true)
                    } else {
                        collectionView.selectItems(at: [indexPath], scrollPosition: .top)
                    }
                    return
                }
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let resting = shownView == .carousel ? IndexPath(item: carouselPlace, section: 0) : nil
        if isReturn,
           let indexPath = collectionView.selectionIndexPaths.first ?? resting,
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
        MidgarLog.info("Playing album \(resolved.title) — \(resolved.artist)", category: .playback)
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
        menu.addItem(ClosureMenuItem(title: String(localized: "Play \(albums.count) Albums"), systemImage: "play.fill") {
            guard !tracks.isEmpty else { return }
            AudioPlayer.shared.play(tracks, startingAt: 0)
        })
        menu.addItem(ClosureMenuItem(title: String(localized: "Add \(tracks.count) Songs to Queue"), systemImage: "text.append") {
            tracks.forEach { AudioPlayer.shared.addToQueue($0) }
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: String(localized: "Love All"), systemImage: "heart.fill") {
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

extension AlbumGridViewController: NSCollectionViewDelegate {

    /// A cover picked in the carousel comes to the middle.
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard shownView == .carousel, let picked = indexPaths.first else { return }
        scrollCarousel(to: picked.item, animated: true)
    }
}

/// Collection view adding type-select and pinch-zoom hooks over the diffable
/// grid; unhandled keys still bubble to the controller for Return-to-play.
final class TypeSelectCollectionView: NSCollectionView {

    var onTypeAhead: ((String) -> Void)?
    var onMagnify: ((CGFloat) -> Void)?

    /// Set while the view is a carousel: the wheel and the arrow keys move it
    /// sideways.
    var scrollsSideways = false
    var onSidewaysWheel: (() -> Void)?
    var onStep: ((Int) -> Void)?

    private static let leftArrow: UInt16 = 123
    private static let rightArrow: UInt16 = 124

    /// Turns an up and down wheel into the carousel's sideways travel. A
    /// trackpad swiping sideways already scrolls it and is left alone.
    override func scrollWheel(with event: NSEvent) {
        guard scrollsSideways, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
              let scroll = enclosingScrollView else {
            super.scrollWheel(with: event)
            return
        }
        let clip = scroll.contentView
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 16
        let limit = max(frame.width - clip.bounds.width, 0)
        var origin = clip.bounds.origin
        origin.x = min(max(origin.x - step, 0), limit)
        clip.setBoundsOrigin(origin)
        scroll.reflectScrolledClipView(clip)
        onSidewaysWheel?()
    }
    var onPictureDrop: ((IndexPath, ArtworkInput) -> Void)?
    var onDropTargetChange: ((IndexPath?, IndexPath?) -> Void)?

    private lazy var dropRelay = ArtworkDropRelay(view: self)
    private var dropTarget: IndexPath?

    private var buffer = ""
    private var resetTask: Task<Void, Never>?

    deinit {
        resetTask?.cancel()
    }

    override func keyDown(with event: NSEvent) {
        if scrollsSideways, event.keyCode == Self.leftArrow || event.keyCode == Self.rightArrow {
            onStep?(event.keyCode == Self.leftArrow ? -1 : 1)
            return
        }
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

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropRelay.endRelay()
        return pictureOrRelayedOperation(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        pictureOrRelayedOperation(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropTarget(nil)
        dropRelay.relayExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setDropTarget(nil)
        dropRelay.relayEnded(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if dropRelay.isActive { return dropRelay.relayPerform(sender) }
        defer { setDropTarget(nil) }
        guard let indexPath = dropTarget, let input = ArtworkInputReader.input(from: sender.draggingPasteboard) else {
            return false
        }
        onPictureDrop?(indexPath, input)
        return true
    }

    /// A picture over an album tile targets that tile; anything else — music
    /// files, folders — belongs to the window's import and is handed to it.
    private func pictureOrRelayedOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard dropRelay.carriesPicture(sender) else {
            setDropTarget(nil)
            return dropRelay.isActive ? dropRelay.operation : dropRelay.relayEntered(sender)
        }
        let path = indexPathForItem(at: convert(sender.draggingLocation, from: nil))
        setDropTarget(path)
        return path == nil ? [] : .copy
    }

    private func setDropTarget(_ path: IndexPath?) {
        guard path != dropTarget else { return }
        let previous = dropTarget
        dropTarget = path
        onDropTargetChange?(previous, path)
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
        icon.contentTintColor = .flaccyTertiaryLabel

        title.font = .systemFont(ofSize: 22, weight: .semibold)
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 2
        subtitle.preferredMaxLayoutWidth = 340

        let chooseButton = NSButton(
            title: String(localized: "Choose Music Folder…"),
            target: nil,
            action: #selector(MacAppDelegate.chooseMusicFolder(_:))
        )
        chooseButton.bezelStyle = .glass
        chooseButton.controlSize = .large

        let importButton = NSButton(
            title: String(localized: "Import Files…"),
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
        title.stringValue = String(localized: "Your library is empty")
        subtitle.stringValue = String(localized: "Choose a music folder to index in place, or import files into Flaccy's own library.")
        buttons.isHidden = false
    }

    func showNoResults(query: String) {
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        title.stringValue = String(localized: "No Results")
        subtitle.stringValue = String(localized: "Nothing in your library matches \u{201C}\(query)\u{201D}.")
        buttons.isHidden = true
    }

    func showNoMatches(for filterTitle: String) {
        icon.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: nil)
        title.stringValue = String(localized: "No Results")
        subtitle.stringValue = String(localized: "No songs match \u{201C}\(filterTitle)\u{201D} yet.")
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
