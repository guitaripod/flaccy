import Combine
import UIKit

/// A wantlist row with artwork, title, artist, and the reason the item is
/// listed — the persuasive line ("34 plays · you own 3 of its tracks") that
/// makes the list feel curated instead of scraped.
final class WantlistRowCell: UICollectionViewCell {
    static let reuseID = "WantlistRowCell"

    private let artwork = AsyncImageView()
    private let titleLabel = UILabel()
    private let reasonLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        artwork.layer.cornerRadius = 6
        artwork.layer.cornerCurve = .continuous
        artwork.clipsToBounds = true
        artwork.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .scaled(.subheadline, size: 14, weight: .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1

        reasonLabel.font = .scaled(.caption1, size: 12, weight: .regular)
        reasonLabel.adjustsFontForContentSizeCategory = true
        reasonLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        reasonLabel.numberOfLines = 1

        let text = UIStackView(arrangedSubviews: [titleLabel, reasonLabel])
        text.axis = .vertical
        text.spacing = 2

        let row = UIStackView(arrangedSubviews: [artwork, text])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)

        NSLayoutConstraint.activate([
            artwork.widthAnchor.constraint(equalToConstant: 48),
            artwork.heightAnchor.constraint(equalToConstant: 48),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, artist: String, reason: String, artworkTitle: String, artworkArtist: String, remoteURL: String?, fallback: RecapArtworkQuery?) {
        titleLabel.text = title
        reasonLabel.text = reason.isEmpty ? artist : "\(artist) · \(reason)"
        artwork.setAlbum(
            title: artworkTitle, artist: artworkArtist, remoteURL: remoteURL,
            placeholder: UIImage(systemName: "music.note"), remoteFallback: fallback
        )
        isAccessibilityElement = true
        accessibilityLabel = "\(title), \(artist). \(reason)"
    }
}

/// The Wantlist: a persistent acquisition queue built from Last.fm history,
/// local gap and quality analysis, similar-artist discovery, and a new-release
/// watch — rendered instantly from the store, refreshed in the background.
final class WantlistViewController: UIViewController {

    private let viewModel = WantlistViewModel()

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<WantlistSection, WantlistItem>!
    private let backdrop = AmbientPaletteBackdropView()
    private let emptyLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let chipBar = UIScrollView()
    private let chipStack = UIStackView()
    private var chipButtons: [UIButton] = []

    private var currentFilter: WantlistFilter = .all
    private var currentData: WantlistData?
    private var currentTint = UIColor.systemTeal
    private var cancellables = Set<AnyCancellable>()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Wantlist"
        view.backgroundColor = .black
        navigationItem.largeTitleDisplayMode = .never

        setupBackdrop()
        setupChips()
        setupCollectionView()
        setupDataSource()
        setupOverlays()
        setupNavigationItems()
        bindViewModel()

        viewModel.loadCached()
        viewModel.refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        WantlistService.shared.markAllSeen()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        PreviewPlayer.shared.stop()
    }

    private func setupBackdrop() {
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.apply(ArtworkPaletteExtractor.fallbackPalette(seed: "wantlist"), animated: false)
        view.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupChips() {
        chipBar.showsHorizontalScrollIndicator = false
        chipBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(chipBar)

        chipStack.axis = .horizontal
        chipStack.spacing = 8
        chipStack.translatesAutoresizingMaskIntoConstraints = false
        chipBar.addSubview(chipStack)

        for filter in WantlistFilter.allCases {
            var config = UIButton.Configuration.filled()
            config.title = filter.title
            config.cornerStyle = .capsule
            config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14)
            let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                self?.selectFilter(filter)
            })
            button.configurationUpdateHandler = { button in
                var config = button.configuration
                let selected = button.isSelected
                config?.baseBackgroundColor = selected ? .white : UIColor.white.withAlphaComponent(0.12)
                config?.baseForegroundColor = selected ? .black : .white
                config?.attributedTitle?.font = .scaled(.footnote, size: 13, weight: .semibold)
                button.configuration = config
            }
            button.isSelected = filter == currentFilter
            chipButtons.append(button)
            chipStack.addArrangedSubview(button)
        }

        NSLayoutConstraint.activate([
            chipBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            chipBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chipBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chipBar.heightAnchor.constraint(equalToConstant: 40),
            chipStack.topAnchor.constraint(equalTo: chipBar.contentLayoutGuide.topAnchor),
            chipStack.bottomAnchor.constraint(equalTo: chipBar.contentLayoutGuide.bottomAnchor),
            chipStack.leadingAnchor.constraint(equalTo: chipBar.contentLayoutGuide.leadingAnchor, constant: 16),
            chipStack.trailingAnchor.constraint(equalTo: chipBar.contentLayoutGuide.trailingAnchor, constant: -16),
            chipStack.heightAnchor.constraint(equalTo: chipBar.frameLayoutGuide.heightAnchor),
        ])
    }

    private func selectFilter(_ filter: WantlistFilter) {
        guard filter != currentFilter else { return }
        currentFilter = filter
        UISelectionFeedbackGenerator().selectionChanged()
        for (index, button) in chipButtons.enumerated() {
            button.isSelected = WantlistFilter.allCases[index] == filter
        }
        applySnapshot(animated: true)
    }

    private func setupCollectionView() {
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.contentInset.bottom = 24

        let refresh = UIRefreshControl()
        refresh.tintColor = .white
        refresh.addAction(UIAction { [weak self] _ in
            self?.viewModel.refresh()
            self?.collectionView.refreshControl?.endRefreshing()
        }, for: .valueChanged)
        collectionView.refreshControl = refresh

        collectionView.register(AlbumCoverCell.self, forCellWithReuseIdentifier: AlbumCoverCell.reuseID)
        collectionView.register(WantlistRowCell.self, forCellWithReuseIdentifier: WantlistRowCell.reuseID)
        collectionView.register(ArtistCardCell.self, forCellWithReuseIdentifier: ArtistCardCell.reuseID)
        collectionView.register(
            RecapHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: RecapHeaderView.reuseID
        )

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: chipBar.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupOverlays() {
        emptyLabel.font = .scaled(.body, size: 16, weight: .medium)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func setupNavigationItems() {
        let share = UIBarButtonItem(
            image: UIImage(systemName: "square.and.arrow.up"),
            primaryAction: UIAction { [weak self] _ in self?.shareWantlist() }
        )
        share.accessibilityLabel = "Share Wantlist"
        navigationItem.rightBarButtonItem = share
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, _ in
            guard let self, let section = self.dataSource.sectionIdentifier(for: index) else { return nil }
            return self.layoutSection(for: section)
        }
    }

    private func layoutSection(for section: WantlistSection) -> NSCollectionLayoutSection {
        let result: NSCollectionLayoutSection
        switch section {
        case .newReleases, .albums, .discoverAlbums:
            let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0 / 3.0), heightDimension: .estimated(150))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            item.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 5, bottom: 12, trailing: 5)
            let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(150))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item, item, item])
            result = NSCollectionLayoutSection(group: group)
        case .tracks, .gaps, .upgrades:
            let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(60))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: itemSize, subitems: [item])
            result = NSCollectionLayoutSection(group: group)
        case .discoverArtists:
            let itemSize = NSCollectionLayoutSize(widthDimension: .absolute(96), heightDimension: .estimated(150))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])
            result = NSCollectionLayoutSection(group: group)
            result.interGroupSpacing = 14
            result.orthogonalScrollingBehavior = .continuous
        }
        result.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 16)

        let headerSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(34))
        let header = NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: headerSize,
            elementKind: UICollectionView.elementKindSectionHeader,
            alignment: .top
        )
        result.boundarySupplementaryItems = [header]
        return result
    }

    private func setupDataSource() {
        let tint = currentTint
        dataSource = UICollectionViewDiffableDataSource<WantlistSection, WantlistItem>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, item in
            let section = self?.dataSource.sectionIdentifier(for: indexPath.section)
            switch item {
            case .album(let album, let meta):
                if section == .gaps || section == .upgrades {
                    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: WantlistRowCell.reuseID, for: indexPath) as! WantlistRowCell
                    cell.configure(
                        title: album.name, artist: album.artist, reason: meta.reason,
                        artworkTitle: album.name, artworkArtist: album.artist,
                        remoteURL: album.imageURL, fallback: nil
                    )
                    return cell
                }
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: AlbumCoverCell.reuseID, for: indexPath) as! AlbumCoverCell
                cell.configure(album)
                return cell
            case .track(let track, let meta):
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: WantlistRowCell.reuseID, for: indexPath) as! WantlistRowCell
                cell.configure(
                    title: track.name, artist: track.artist, reason: meta.reason,
                    artworkTitle: track.name, artworkArtist: track.artist,
                    remoteURL: nil, fallback: .track(artist: track.artist, track: track.name)
                )
                return cell
            case .artist(let artist, _):
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ArtistCardCell.reuseID, for: indexPath) as! ArtistCardCell
                cell.configure(artist, tint: tint)
                return cell
            }
        }

        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            guard kind == UICollectionView.elementKindSectionHeader,
                  let section = self?.dataSource.sectionIdentifier(for: indexPath.section) else { return nil }
            let header = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: RecapHeaderView.reuseID,
                for: indexPath
            ) as! RecapHeaderView
            header.configure(title: section.headerTitle)
            return header
        }
    }

    private func bindViewModel() {
        viewModel.dataPublisher
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in self?.render(data) }
            .store(in: &cancellables)

        viewModel.loadingPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loading in
                guard let self else { return }
                if loading, self.dataSource.snapshot().numberOfItems == 0 {
                    self.spinner.startAnimating()
                    self.emptyLabel.isHidden = true
                } else if !loading {
                    self.spinner.stopAnimating()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: WantlistService.didChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.viewModel.loadCached() }
            .store(in: &cancellables)
    }

    private func render(_ data: WantlistData) {
        currentData = data
        if !data.isEmpty {
            spinner.stopAnimating()
        }
        applySnapshot(animated: false)
        prewarmArtwork(data)
    }

    private func applySnapshot(animated: Bool) {
        guard let data = currentData else { return }
        var snapshot = NSDiffableDataSourceSnapshot<WantlistSection, WantlistItem>()
        for (section, items) in data.filtered(by: currentFilter) {
            snapshot.appendSections([section])
            snapshot.appendItems(items, toSection: section)
        }
        dataSource.apply(snapshot, animatingDifferences: animated)

        let empty = snapshot.numberOfItems == 0
        emptyLabel.isHidden = !empty || spinner.isAnimating
        if empty {
            emptyLabel.text = viewModel.isAvailable
                ? "Nothing here right now.\nYour library already covers it."
                : "Connect Last.fm in Settings to see\nwhich music you love but don't own."
        }
    }

    private func prewarmArtwork(_ data: WantlistData) {
        var targets: [(String, String, String?, RecapArtworkQuery?)] = []
        for (_, items) in data.sections {
            for item in items {
                switch item {
                case .album(let album, _):
                    targets.append((album.name, album.artist, album.imageURL, .album(artist: album.artist, album: album.name)))
                case .track(let track, _):
                    targets.append((track.name, track.artist, nil, .track(artist: track.artist, track: track.name)))
                case .artist:
                    break
                }
            }
        }
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for target in targets.prefix(40) {
                    group.addTask {
                        _ = await AsyncImageView.prewarmAlbum(
                            title: target.0, artist: target.1, remoteURL: target.2, remoteFallback: target.3
                        )
                    }
                }
            }
        }
    }

    private func shareWantlist() {
        guard let data = currentData, !data.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        var lines: [String] = ["My flaccy wantlist:"]
        for (section, items) in data.sections {
            lines.append("")
            lines.append(section.headerTitle)
            for item in items {
                switch item {
                case .album(let album, _): lines.append("• \(album.artist) — \(album.name)")
                case .track(let track, _): lines.append("• \(track.artist) — \(track.name)")
                case .artist(let artist, _): lines.append("• \(artist.name)")
                }
            }
        }
        let activity = UIActivityViewController(activityItems: [lines.joined(separator: "\n")], applicationActivities: nil)
        activity.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(activity, animated: true)
    }
}

extension WantlistViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        presentActions(for: item)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.menu(for: item)
        }
    }

    private func menu(for item: WantlistItem) -> UIMenu {
        let (title, artist, meta, isAlbum) = unpack(item)
        var actions: [UIMenuElement] = []

        if !isAlbum || meta.source != "release" {
            actions.append(UIAction(title: "Got It", image: UIImage(systemName: "checkmark.circle")) { _ in
                WantlistService.shared.setState(.acquired, normKey: meta.normKey)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            })
            actions.append(UIAction(title: "Not Interested", image: UIImage(systemName: "hand.thumbsdown"), attributes: .destructive) { _ in
                WantlistService.shared.setState(.dismissed, normKey: meta.normKey)
            })
        }
        if !isAlbum {
            actions.append(UIAction(title: "Play Preview", image: UIImage(systemName: "play.circle")) { [weak self] _ in
                self?.playPreview(title: title, artist: artist, key: meta.normKey)
            })
        }
        actions.append(UIAction(title: "Open in Apple Music", image: UIImage(systemName: "arrow.up.forward.app")) { [weak self] _ in
            self?.openInAppleMusic(title: title, artist: artist, isAlbum: isAlbum, storeURL: meta.storeURL)
        })
        actions.append(UIAction(title: "View on Last.fm", image: UIImage(systemName: "safari")) { [weak self] _ in
            self?.openLastFM(path: isAlbum ? [artist, title] : (title.isEmpty ? [artist] : [artist, "_", title]))
        })
        actions.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
            UIPasteboard.general.string = title.isEmpty ? artist : "\(artist) — \(title)"
        })
        return UIMenu(children: actions)
    }

    private func unpack(_ item: WantlistItem) -> (title: String, artist: String, meta: WantlistRowMeta, isAlbum: Bool) {
        switch item {
        case .album(let album, let meta): (album.name, album.artist, meta, true)
        case .track(let track, let meta): (track.name, track.artist, meta, false)
        case .artist(let artist, let meta): ("", artist.name, meta, false)
        }
    }

    private func presentActions(for item: WantlistItem) {
        let (title, artist, meta, isAlbum) = unpack(item)
        let sheet = UIAlertController(
            title: title.isEmpty ? artist : title,
            message: meta.reason.isEmpty ? artist : "\(artist)\n\(meta.reason)",
            preferredStyle: .actionSheet
        )
        if meta.source != "release" {
            sheet.addAction(UIAlertAction(title: "Got It", style: .default) { _ in
                WantlistService.shared.setState(.acquired, normKey: meta.normKey)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            })
            sheet.addAction(UIAlertAction(title: "Not Interested", style: .destructive) { _ in
                WantlistService.shared.setState(.dismissed, normKey: meta.normKey)
            })
        }
        if !isAlbum, !title.isEmpty {
            let previewing = PreviewPlayer.shared.currentKey == meta.normKey
            sheet.addAction(UIAlertAction(title: previewing ? "Stop Preview" : "Play Preview", style: .default) { [weak self] _ in
                self?.playPreview(title: title, artist: artist, key: meta.normKey)
            })
        }
        sheet.addAction(UIAlertAction(title: "Open in Apple Music", style: .default) { [weak self] _ in
            self?.openInAppleMusic(title: title, artist: artist, isAlbum: isAlbum, storeURL: meta.storeURL)
        })
        sheet.addAction(UIAlertAction(title: "View on Last.fm", style: .default) { [weak self] _ in
            self?.openLastFM(path: isAlbum ? [artist, title] : (title.isEmpty ? [artist] : [artist, "_", title]))
        })
        sheet.addAction(UIAlertAction(title: "Copy", style: .default) { _ in
            UIPasteboard.general.string = title.isEmpty ? artist : "\(artist) — \(title)"
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    private func playPreview(title: String, artist: String, key: String) {
        if PreviewPlayer.shared.currentKey == key {
            PreviewPlayer.shared.stop()
            return
        }
        Task { [weak self] in
            guard let url = await WantlistService.fetchPreviewURL(title: title, artist: artist) else {
                if let self {
                    ToastView.show("No preview available", in: self.view, style: .error)
                }
                return
            }
            PreviewPlayer.shared.toggle(key: key, url: url)
            if let self {
                ToastView.show("Previewing \(title)", in: self.view, style: .success)
            }
        }
    }

    private func openInAppleMusic(title: String, artist: String, isAlbum: Bool, storeURL: String?) {
        if let storeURL, let url = URL(string: storeURL) {
            UIApplication.shared.open(url)
            return
        }
        Task { [weak self] in
            let url: URL?
            if isAlbum {
                url = await MusicKitService.shared.findAlbum(title: title, artist: artist)?.appleMusicURL
            } else if title.isEmpty {
                url = nil
            } else {
                url = await MusicKitService.shared.findSong(title: title, artist: artist)?.appleMusicURL
            }
            guard let self else { return }
            if let url {
                await UIApplication.shared.open(url)
            } else {
                ToastView.show("Not found on Apple Music", in: self.view, style: .error)
            }
        }
    }

    private func openLastFM(path components: [String]) {
        var url = URL(string: "https://www.last.fm/music")!
        for component in components {
            url.appendPathComponent(component)
        }
        UIApplication.shared.open(url)
    }
}
