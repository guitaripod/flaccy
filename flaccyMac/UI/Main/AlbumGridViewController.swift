import AppKit

/// Stage A album wall: a diffable NSCollectionView over the shared Library,
/// artwork thumbnails with deterministic placeholder gradients, double-click
/// to play. The full browsing experience (zoom, sort, context menus) lands in
/// Stage B on top of this controller.
final class AlbumGridViewController: NSViewController {

    private enum Section {
        case main
    }

    private let scrollView = NSScrollView()
    private let collectionView = NSCollectionView()
    private var dataSource: NSCollectionViewDiffableDataSource<Section, Album>?
    private let emptyStateView = EmptyLibraryView()

    override func loadView() {
        view = NSView()

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 184, height: 238)
        layout.minimumInteritemSpacing = 20
        layout.minimumLineSpacing = 24
        layout.sectionInset = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)

        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            AlbumGridItem.self,
            forItemWithIdentifier: AlbumGridItem.identifier
        )

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.isHidden = true
        view.addSubview(emptyStateView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(libraryDidUpdate), name: Library.didUpdateNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(libraryDidUpdate), name: Library.loadingStateChanged, object: nil
        )
        applySnapshot(animated: false)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func configureDataSource() {
        dataSource = NSCollectionViewDiffableDataSource<Section, Album>(
            collectionView: collectionView
        ) { collectionView, indexPath, album in
            let item = collectionView.makeItem(
                withIdentifier: AlbumGridItem.identifier, for: indexPath
            )
            guard let gridItem = item as? AlbumGridItem else { return item }
            gridItem.configure(with: album)
            gridItem.onDoubleClick = { [weak self] in
                self?.play(album)
            }
            return gridItem
        }
    }

    @objc private func libraryDidUpdate() {
        applySnapshot(animated: true)
    }

    private func applySnapshot(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Album>()
        snapshot.appendSections([.main])
        let albums = Library.shared.albums.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        snapshot.appendItems(albums)
        dataSource?.apply(snapshot, animatingDifferences: animated)
        emptyStateView.isHidden = !albums.isEmpty || Library.shared.isLoading
        emptyStateView.setLoading(Library.shared.isLoading)
        AppLogger.debug("Album grid showing \(albums.count) albums", category: .ui)
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn,
           let indexPath = collectionView.selectionIndexPaths.first,
           let album = dataSource?.itemIdentifier(for: indexPath) {
            play(album)
            return
        }
        super.keyDown(with: event)
    }

    private func play(_ album: Album) {
        guard !album.tracks.isEmpty else { return }
        AppLogger.info("Playing album \(album.title) — \(album.artist)", category: .playback)
        AudioPlayer.shared.play(album.tracks, startingAt: 0)
    }
}

private final class EmptyLibraryView: NSView {

    private let spinner = NSProgressIndicator()
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let icon = NSImageView(image: NSImage(
            systemSymbolName: "music.note.house", accessibilityDescription: nil
        ) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 46, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor

        let title = NSTextField(labelWithString: "Your library is empty")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let subtitle = NSTextField(
            labelWithString: "Choose a music folder to index in place, or import files into Flaccy's own library."
        )
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
        chooseButton.keyEquivalent = "\r"

        let importButton = NSButton(
            title: "Import Files…",
            target: nil,
            action: #selector(MacAppDelegate.importFiles(_:))
        )
        importButton.bezelStyle = .glass
        importButton.controlSize = .large

        let buttons = NSStackView(views: [chooseButton, importButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        stack.setViews([icon, title, subtitle, buttons, spinner], in: .center)
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setLoading(_ loading: Bool) {
        if loading {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }
}
