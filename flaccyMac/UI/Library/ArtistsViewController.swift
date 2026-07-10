import AppKit
import Combine

/// Artist wall: circular artist photos (resolved through the shared image
/// chain, with album art then gradient fallbacks), album counts, click to
/// drill into the artist detail.
final class ArtistsViewController: NSViewController {

    var onOpenArtist: ((String) -> Void)?

    private let viewModel = LibraryViewModel()
    private let scrollView = NSScrollView()
    private let collectionView = TypeSelectCollectionView()
    private let layout = NSCollectionViewFlowLayout()
    private let sortPopUp = NSPopUpButton()
    private let emptyStateView = LibraryEmptyStateView()
    private var dataSource: NSCollectionViewDiffableDataSource<Int, LibraryItem>?
    private var cancellables = Set<AnyCancellable>()

    override func loadView() {
        view = NSView()

        layout.itemSize = NSSize(width: 150, height: 196)
        layout.minimumInteritemSpacing = 22
        layout.minimumLineSpacing = 26
        layout.sectionInset = NSEdgeInsets(top: 16, left: 28, bottom: 24, right: 28)

        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            ArtistGridItem.self, forItemWithIdentifier: ArtistGridItem.identifier
        )
        collectionView.onTypeAhead = { [weak self] prefix in
            self?.jumpToPrefix(prefix)
        }

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        sortPopUp.controlSize = .small
        sortPopUp.font = .systemFont(ofSize: 11.5)
        for sort in LibraryViewModel.ArtistSort.allCases {
            sortPopUp.addItem(withTitle: sort.displayName)
            sortPopUp.lastItem?.representedObject = sort.rawValue
        }
        sortPopUp.target = self
        sortPopUp.action = #selector(sortChanged(_:))
        sortPopUp.toolTip = "Sort artists"

        let sortLabel = NSTextField(labelWithString: "Sort")
        sortLabel.font = .systemFont(ofSize: 11)
        sortLabel.textColor = .secondaryLabelColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let controls = NSStackView(views: [spacer, sortLabel, sortPopUp])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.alignment = .centerY
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

        let dataSource = NSCollectionViewDiffableDataSource<Int, LibraryItem>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, item in
            let cell = collectionView.makeItem(
                withIdentifier: ArtistGridItem.identifier, for: indexPath
            )
            guard let gridItem = cell as? ArtistGridItem,
                  case .artist(let artist) = item else { return cell }
            let albums = Library.shared.albums.filter { $0.artist == artist.name }
            gridItem.configure(name: artist.name, albums: albums)
            gridItem.onOpen = { [weak self] in self?.onOpenArtist?(artist.name) }
            gridItem.onMenu = { [weak gridItem] in
                Self.artistMenu(name: artist.name, albums: albums, anchor: gridItem?.view)
            }
            return cell
        }
        self.dataSource = dataSource

        selectSortItem(viewModel.artistSort)
        viewModel.snapshotPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.apply(snapshot)
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self, selector: #selector(searchQueryChanged(_:)), name: .flaccySearchQueryChanged, object: nil
        )

        viewModel.switchSegment(to: .artists)
        if !LibrarySearchState.query.isEmpty {
            viewModel.search(query: LibrarySearchState.query)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func apply(_ snapshot: LibraryViewModel.Snapshot) {
        guard viewModel.currentSegment == .artists else { return }
        dataSource?.apply(
            snapshot,
            animatingDifferences: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        switch viewModel.emptyState {
        case .none:
            emptyStateView.isHidden = true
        case .noLibrary:
            emptyStateView.isHidden = OnboardingPanelView.visibility != .hide
            emptyStateView.showNoLibrary()
        case .noSearchResults(let query):
            emptyStateView.isHidden = false
            emptyStateView.showNoResults(query: query)
        }
        AppLogger.debug("Artists grid showing \(snapshot.numberOfItems) artists", category: .ui)
    }

    @objc private func sortChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let sort = LibraryViewModel.ArtistSort(rawValue: raw) else { return }
        viewModel.setArtistSort(sort)
    }

    @objc private func searchQueryChanged(_ notification: Notification) {
        viewModel.search(query: notification.userInfo?[LibraryNavigator.Key.query] as? String ?? "")
    }

    private func selectSortItem(_ sort: LibraryViewModel.ArtistSort) {
        let index = sortPopUp.itemArray.firstIndex { ($0.representedObject as? String) == sort.rawValue }
        if let index { sortPopUp.selectItem(at: index) }
    }

    private func jumpToPrefix(_ prefix: String) {
        guard let dataSource else { return }
        let snapshot = dataSource.snapshot()
        for (row, item) in snapshot.itemIdentifiers.enumerated() {
            guard case .artist(let artist) = item else { continue }
            if artist.name.lowercased().hasPrefix(prefix.lowercased()) {
                let indexPath = IndexPath(item: row, section: 0)
                collectionView.deselectItems(at: collectionView.selectionIndexPaths)
                collectionView.selectItems(at: [indexPath], scrollPosition: .top)
                return
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn,
           let indexPath = collectionView.selectionIndexPaths.first,
           let item = dataSource?.itemIdentifier(for: indexPath),
           case .artist(let artist) = item {
            onOpenArtist?(artist.name)
            return
        }
        super.keyDown(with: event)
    }

    private static func artistMenu(name: String, albums: [Album], anchor: NSView?) -> NSMenu {
        let menu = NSMenu()
        let tracks = albums.flatMap(\.tracks)
        menu.addItem(ClosureMenuItem(title: "View Artist", systemImage: "music.microphone") {
            LibraryNavigator.revealArtist(name)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Play All", systemImage: "play.fill") {
            AudioPlayer.shared.play(tracks, startingAt: 0)
        })
        menu.addItem(ClosureMenuItem(title: "Shuffle All", systemImage: "shuffle") {
            AudioPlayer.shared.play(tracks.shuffled(), startingAt: 0)
        })
        menu.addItem(ClosureMenuItem(title: "Start Station", systemImage: "dot.radiowaves.left.and.right") {
            AudioPlayer.shared.startStation(seedArtist: name)
            MacToast.show("Station started from \(name)", style: .success, in: anchor?.window)
        })
        return menu
    }
}

/// Circular artist tile with the photo-resolution chain and hover lift.
final class ArtistGridItem: NSCollectionViewItem {

    static let identifier = NSUserInterfaceItemIdentifier("ArtistGridItem")

    var onOpen: (() -> Void)?
    var onMenu: (() -> NSMenu?)?

    private let artworkTile = ArtworkTileView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private var currentArtist: String?
    private var photoTask: Task<Void, Never>?

    override func loadView() {
        view = ArtistGridItemView(owner: self)

        artworkTile.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .center

        let labels = NSStackView(views: [nameLabel, countLabel])
        labels.orientation = .vertical
        labels.alignment = .centerX
        labels.spacing = 1
        labels.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(artworkTile)
        view.addSubview(labels)
        NSLayoutConstraint.activate([
            artworkTile.topAnchor.constraint(equalTo: view.topAnchor),
            artworkTile.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            artworkTile.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -20),
            artworkTile.heightAnchor.constraint(equalTo: artworkTile.widthAnchor),

            labels.topAnchor.constraint(equalTo: artworkTile.bottomAnchor, constant: 8),
            labels.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            labels.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        artworkTile.cornerRadius = artworkTile.bounds.width / 2
    }

    func configure(name: String, albums: [Album]) {
        currentArtist = name
        nameLabel.stringValue = name
        nameLabel.toolTip = name
        let trackCount = albums.reduce(0) { $0 + $1.tracks.count }
        countLabel.stringValue = "\(albums.count) album\(albums.count == 1 ? "" : "s") · \(trackCount) songs"

        artworkTile.showPlaceholder(seed: name, shimmering: true)
        if let first = albums.first,
           let thumbnail = AlbumArtworkCache.shared.thumbnail(forAlbum: first.title, artist: first.artist) {
            artworkTile.showImage(thumbnail)
        }
        photoTask?.cancel()
        photoTask = Task { [weak self] in
            let photo = await MacArtistImageService.shared.image(for: name)
            guard let self, !Task.isCancelled, self.currentArtist == name else { return }
            if let photo {
                self.artworkTile.showImage(photo)
            } else if let first = albums.first {
                AlbumArtworkCache.shared.loadThumbnail(forAlbum: first.title, artist: first.artist) { [weak self] image in
                    guard let self, self.currentArtist == name else { return }
                    if let image {
                        self.artworkTile.showImage(image)
                    } else {
                        self.artworkTile.stopShimmer()
                    }
                }
            } else {
                self.artworkTile.stopShimmer()
            }
        }
    }

    override var isSelected: Bool {
        didSet {
            artworkTile.layer?.borderWidth = isSelected ? 2.5 : 0
            artworkTile.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        photoTask?.cancel()
        photoTask = nil
        currentArtist = nil
        onOpen = nil
        onMenu = nil
    }

    fileprivate func handleClick(count: Int) {
        onOpen?()
    }

    fileprivate func contextMenu() -> NSMenu? {
        onMenu?()
    }
}

private final class ArtistGridItemView: NSView {

    private weak var owner: ArtistGridItem?

    init(owner: ArtistGridItem) {
        self.owner = owner
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            owner?.handleClick(count: 2)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.contextMenu() ?? super.menu(for: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
