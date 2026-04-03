import Combine
import UIKit
import UniformTypeIdentifiers

final class LibraryViewController: UIViewController, SonglinkShareable {

    private let viewModel = LibraryViewModel()
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, LibraryItem>!
    private let segmentedControl = UISegmentedControl(items: ["Albums", "Songs", "Artists", "Playlists"])
    private var cancellables = Set<AnyCancellable>()
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let sectionIndexView = SectionIndexView()
    private let loadingOverlay = UIView()
    private let loadingIconView = UIImageView()
    private let loadingLabel = UILabel()
    private lazy var emptyStateView: UIView = {
        let container = UIView()

        let imageView = UIImageView(image: UIImage(systemName: "music.note.list"))
        imageView.tintColor = .tertiaryLabel
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 56, weight: .thin)
        imageView.contentMode = .scaleAspectFit

        let label = UILabel()
        label.text = "Import files from Settings"
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .body)

        let stack = UIStackView(arrangedSubviews: [imageView, label])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -40),
        ])

        return container
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        setupLoadingOverlay()
        loadingOverlay.isHidden = false
        loadingOverlay.alpha = 1
        startLoadingPulse()
        navigationController?.setNavigationBarHidden(true, animated: false)

        setupSearchController()
        setupSegmentedControl()
        setupCollectionView()
        setupSectionIndex()
        configureDataSource()
        bindViewModel()
        updateRightBarButton(for: .albums)

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"),
            primaryAction: UIAction { [weak self] _ in self?.presentSettings() }
        )

        Task {
            await viewModel.loadLibrary()
            viewModel.restorePlaybackState()
        }
    }

    private func setupSearchController() {
        let searchController = UISearchController(searchResultsController: nil)
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Albums, Artists, Songs"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.largeTitleDisplayMode = .never
        definesPresentationContext = true
    }

    private func setupSegmentedControl() {
        segmentedControl.selectedSegmentIndex = 0
        segmentedControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.impactLight.impactOccurred()
            let segment = LibraryViewModel.Segment(rawValue: self.segmentedControl.selectedSegmentIndex) ?? .albums
            self.viewModel.switchSegment(to: segment)
            self.updateRightBarButton(for: segment)
            self.updateSectionIndex()
        }, for: .valueChanged)
        navigationItem.titleView = segmentedControl
    }

    private func updateRightBarButton(for segment: LibraryViewModel.Segment) {
        switch segment {
        case .albums:
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                image: UIImage(systemName: "arrow.up.arrow.down"),
                menu: albumSortMenu()
            )
        case .songs:
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                image: UIImage(systemName: "arrow.up.arrow.down"),
                menu: songSortMenu()
            )
        case .artists:
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                image: UIImage(systemName: "arrow.up.arrow.down"),
                menu: artistSortMenu()
            )
        case .playlists:
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.createPlaylistTapped() }
            )
        }
    }

    private func albumSortMenu() -> UIMenu {
        let actions = LibraryViewModel.AlbumSort.allCases.map { sort in
            UIAction(
                title: sort.displayName,
                image: UIImage(systemName: sort.icon),
                state: viewModel.albumSort == sort ? .on : .off
            ) { [weak self] _ in
                self?.impactLight.impactOccurred()
                self?.viewModel.setAlbumSort(sort)
                self?.updateRightBarButton(for: .albums)
                self?.updateSectionIndex()
            }
        }
        return UIMenu(title: "Sort By", image: UIImage(systemName: "arrow.up.arrow.down"), children: actions)
    }

    private func songSortMenu() -> UIMenu {
        let actions = LibraryViewModel.SongSort.allCases.map { sort in
            UIAction(
                title: sort.displayName,
                image: UIImage(systemName: sort.icon),
                state: viewModel.songSort == sort ? .on : .off
            ) { [weak self] _ in
                self?.impactLight.impactOccurred()
                self?.viewModel.setSongSort(sort)
                self?.updateRightBarButton(for: .songs)
                self?.updateSectionIndex()
            }
        }
        return UIMenu(title: "Sort By", image: UIImage(systemName: "arrow.up.arrow.down"), children: actions)
    }

    private func artistSortMenu() -> UIMenu {
        let actions = LibraryViewModel.ArtistSort.allCases.map { sort in
            UIAction(
                title: sort.displayName,
                image: UIImage(systemName: sort.icon),
                state: viewModel.artistSort == sort ? .on : .off
            ) { [weak self] _ in
                self?.impactLight.impactOccurred()
                self?.viewModel.setArtistSort(sort)
                self?.updateRightBarButton(for: .artists)
                self?.updateSectionIndex()
            }
        }
        return UIMenu(title: "Sort By", image: UIImage(systemName: "arrow.up.arrow.down"), children: actions)
    }

    private func createPlaylistTapped() {
        impactLight.impactOccurred()
        let alert = UIAlertController(title: "New Playlist", message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "Playlist name"
            textField.autocapitalizationType = .words
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            guard let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty else { return }
            do {
                try DatabaseManager.shared.createPlaylist(name: name)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                self?.viewModel.refreshPlaylists()
            } catch {
                AppLogger.error("Failed to create playlist: \(error.localizedDescription)", category: .database)
            }
        })
        present(alert, animated: true)
    }

    private func setupCollectionView() {
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: createLayout(for: .albums))
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        collectionView.backgroundColor = .clear

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupSectionIndex() {
        sectionIndexView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sectionIndexView)

        NSLayoutConstraint.activate([
            sectionIndexView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            sectionIndexView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            sectionIndexView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            sectionIndexView.widthAnchor.constraint(equalToConstant: 16),
        ])

        sectionIndexView.onSelectIndex = { [weak self] letter in
            guard let self,
                  let itemIndex = self.viewModel.indexOfFirstItem(forLetter: letter) else { return }
            let section = self.viewModel.currentSegment == .albums && self.viewModel.recentlyPlayedAlbums.count > 0
                && self.dataSource.snapshot().numberOfSections > 1 ? 1 : 0
            let indexPath = IndexPath(item: itemIndex, section: section)
            self.collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
        }
    }

    private func updateSectionIndex() {
        let titles = viewModel.indexTitles()
        sectionIndexView.update(titles: titles)
        sectionIndexView.isHidden = titles.count < 5 || viewModel.currentSegment == .playlists
    }

    private func setupLoadingOverlay() {
        loadingOverlay.backgroundColor = .systemBackground
        loadingOverlay.isHidden = true
        loadingOverlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loadingOverlay)

        loadingIconView.image = UIImage(systemName: "waveform.circle.fill")
        loadingIconView.tintColor = .tintColor
        loadingIconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 64, weight: .thin)
        loadingIconView.contentMode = .scaleAspectFit

        let titleLabel = UILabel()
        titleLabel.text = "flaccy"
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [loadingIconView, titleLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.addSubview(stack)

        NSLayoutConstraint.activate([
            loadingOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            loadingOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            loadingOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: loadingOverlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: loadingOverlay.centerYAnchor, constant: -60),
        ])
    }

    private func startLoadingPulse() {
        loadingIconView.layer.removeAnimation(forKey: "pulse")
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = 1.2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        loadingIconView.layer.add(pulse, forKey: "pulse")
    }

    private func stopLoadingPulse() {
        loadingIconView.layer.removeAnimation(forKey: "pulse")
    }

    private func configureDataSource() {
        let albumRegistration = UICollectionView.CellRegistration<AlbumCell, Album> { cell, _, album in
            cell.configure(with: album)
        }

        let artistRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, ArtistItem> { cell, _, artist in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = artist.name
            content.secondaryText = "\(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s")"
            content.secondaryTextProperties.color = .secondaryLabel
            content.imageProperties.cornerRadius = 22
            content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
            content.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 44)

            let firstAlbum = Library.shared.albums.first { $0.artist == artist.name }
            let cachedArt: UIImage? = firstAlbum.flatMap { AlbumArtworkCache.shared.artwork(forAlbum: $0.title, artist: $0.artist) }

            if let cachedArt {
                content.image = cachedArt
            } else {
                content.image = UIImage(systemName: "person.crop.circle.fill")
                content.imageProperties.tintColor = .tertiaryLabel
                if let firstAlbum {
                    AlbumArtworkCache.shared.loadArtwork(forAlbum: firstAlbum.title, artist: firstAlbum.artist) { [weak cell] image in
                        guard let cell, let image else { return }
                        var updated = UIListContentConfiguration.subtitleCell()
                        updated.text = artist.name
                        updated.secondaryText = "\(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s")"
                        updated.secondaryTextProperties.color = .secondaryLabel
                        updated.imageProperties.cornerRadius = 22
                        updated.imageProperties.maximumSize = CGSize(width: 44, height: 44)
                        updated.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 44)
                        updated.image = image
                        cell.contentConfiguration = updated
                        cell.accessories = [.disclosureIndicator()]
                    }
                }
            }
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }

        let playlistRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, PlaylistItem> { cell, _, playlist in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = playlist.name
            content.secondaryText = "\(playlist.trackCount) track\(playlist.trackCount == 1 ? "" : "s")"
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: "music.note.list")
            content.imageProperties.tintColor = .tintColor
            content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
            content.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 44)
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }

        let chartsRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { cell, _, _ in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = "Last.fm Charts"
            content.secondaryText = "Your top tracks"
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: "chart.bar.fill")
            content.imageProperties.tintColor = UIColor(red: 0.84, green: 0.09, blue: 0.09, alpha: 1.0)
            content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
            content.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 44)
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }

        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { supplementaryView, _, _ in
            var config = UIListContentConfiguration.plainHeader()
            config.text = "Recently Played"
            config.textProperties.font = .systemFont(ofSize: 13, weight: .semibold)
            config.textProperties.color = .secondaryLabel
            supplementaryView.contentConfiguration = config
        }

        let songRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Track> { cell, _, track in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = track.title
            content.secondaryText = "\(track.artist) · \(track.albumTitle)"
            content.secondaryTextProperties.color = .secondaryLabel
            content.imageProperties.cornerRadius = 4
            content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
            content.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 44)
            if let cached = AlbumArtworkCache.shared.artwork(forAlbum: track.albumTitle, artist: track.artist) {
                content.image = cached
            } else {
                content.image = UIImage(systemName: "music.note")
                content.imageProperties.tintColor = .tertiaryLabel
                AlbumArtworkCache.shared.loadArtwork(forAlbum: track.albumTitle, artist: track.artist) { [weak cell] image in
                    guard let cell, let image else { return }
                    var updated = UIListContentConfiguration.subtitleCell()
                    updated.text = track.title
                    updated.secondaryText = "\(track.artist) · \(track.albumTitle)"
                    updated.secondaryTextProperties.color = .secondaryLabel
                    updated.imageProperties.cornerRadius = 4
                    updated.imageProperties.maximumSize = CGSize(width: 44, height: 44)
                    updated.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 44)
                    updated.image = image
                    cell.contentConfiguration = updated
                }
            }
            cell.contentConfiguration = content
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            switch item {
            case .album(let album):
                return collectionView.dequeueConfiguredReusableCell(
                    using: albumRegistration, for: indexPath, item: album
                )
            case .song(let track):
                return collectionView.dequeueConfiguredReusableCell(
                    using: songRegistration, for: indexPath, item: track
                )
            case .artist(let artist):
                return collectionView.dequeueConfiguredReusableCell(
                    using: artistRegistration, for: indexPath, item: artist
                )
            case .playlist(let playlist):
                return collectionView.dequeueConfiguredReusableCell(
                    using: playlistRegistration, for: indexPath, item: playlist
                )
            case .charts:
                return collectionView.dequeueConfiguredReusableCell(
                    using: chartsRegistration, for: indexPath, item: 0
                )
            }
        }

        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }
    }

    private func bindViewModel() {
        viewModel.snapshotPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                self.collectionView.setCollectionViewLayout(
                    self.createLayout(for: self.viewModel.currentSegment), animated: false
                )
                self.dataSource.apply(snapshot, animatingDifferences: false)
                self.collectionView.backgroundView = self.viewModel.isEmpty ? self.emptyStateView : nil
                self.updateSectionIndex()
            }
            .store(in: &cancellables)

        viewModel.loadingPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLoading in
                guard let self else { return }
                if isLoading {
                    self.loadingOverlay.isHidden = false
                    self.loadingOverlay.alpha = 1
                    self.startLoadingPulse()
                } else {
                    self.stopLoadingPulse()
                    self.navigationController?.setNavigationBarHidden(false, animated: false)
                    UIView.animate(withDuration: 0.5, delay: 0.05, options: .curveEaseOut) {
                        self.loadingOverlay.alpha = 0
                    } completion: { _ in
                        self.loadingOverlay.isHidden = true
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func createLayout(for segment: LibraryViewModel.Segment) -> UICollectionViewCompositionalLayout {
        switch segment {
        case .albums:
            return UICollectionViewCompositionalLayout { [weak self] sectionIndex, _ in
                guard let self else { return nil }
                let hasRecent = self.viewModel.recentlyPlayedAlbums.count > 0
                    && self.dataSource.snapshot().numberOfSections > 1

                if sectionIndex == 0 && hasRecent {
                    let itemSize = NSCollectionLayoutSize(widthDimension: .absolute(110), heightDimension: .estimated(160))
                    let item = NSCollectionLayoutItem(layoutSize: itemSize)
                    let groupSize = NSCollectionLayoutSize(widthDimension: .absolute(110), heightDimension: .estimated(160))
                    let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
                    let section = NSCollectionLayoutSection(group: group)
                    section.orthogonalScrollingBehavior = .continuous
                    section.interGroupSpacing = 10
                    section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
                    return section
                }

                let itemSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0 / 3.0),
                    heightDimension: .estimated(180)
                )
                let item = NSCollectionLayoutItem(layoutSize: itemSize)

                let groupSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .estimated(180)
                )
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, repeatingSubitem: item, count: 3)
                group.interItemSpacing = .fixed(10)

                let section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = 12
                section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
                return section
            }
        case .songs:
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.showsSeparators = true
            config.backgroundColor = .clear
            return UICollectionViewCompositionalLayout.list(using: config)
        case .artists:
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.showsSeparators = true
            config.backgroundColor = .clear
            return UICollectionViewCompositionalLayout.list(using: config)
        case .playlists:
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.showsSeparators = true
            config.backgroundColor = .clear
            config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                guard let self,
                      let item = self.dataSource.itemIdentifier(for: indexPath),
                      case .playlist(let playlist) = item
                else { return nil }
                let deleteAction = UIContextualAction(style: .destructive, title: "Delete") { _, _, completion in
                    do {
                        try DatabaseManager.shared.deletePlaylist(id: playlist.id)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        self.viewModel.refreshPlaylists()
                        completion(true)
                    } catch {
                        AppLogger.error("Failed to delete playlist: \(error.localizedDescription)", category: .database)
                        completion(false)
                    }
                }
                return UISwipeActionsConfiguration(actions: [deleteAction])
            }
            return UICollectionViewCompositionalLayout.list(using: config)
        }
    }

    private func presentSettings() {
        impactLight.impactOccurred()
        let settings = SettingsViewController()
        settings.onImportFiles = { [weak self] in
            self?.importTapped()
        }
        let nav = UINavigationController(rootViewController: settings)
        nav.modalPresentationStyle = .pageSheet
        present(nav, animated: true)
    }

    private func importTapped() {
        impactLight.impactOccurred()
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio])
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    private func buildSongContextMenu(for track: Track) -> UIMenu {
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

        let playNext = UIAction(title: "Play Next", image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")) { [weak self] _ in
            guard let self else { return }
            AudioPlayer.shared.insertNext(track)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            ToastView.show("Playing next", in: self.view, style: .info)
        }

        let addToQueue = UIAction(title: "Add to Queue", image: UIImage(systemName: "text.append")) { [weak self] _ in
            guard let self else { return }
            AudioPlayer.shared.addToQueue(track)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            ToastView.show("Added to queue", in: self.view, style: .info)
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
                        AppLogger.error("Failed to add to playlist: \(error.localizedDescription)", category: .database)
                    }
                }
                playlistActions.append(action)
            }
        } catch {
            AppLogger.error("Failed to fetch playlists: \(error.localizedDescription)", category: .database)
        }

        let newPlaylistAction = UIAction(title: "New Playlist\u{2026}", image: UIImage(systemName: "plus")) { [weak self] _ in
            guard let self else { return }
            let alert = UIAlertController(title: "New Playlist", message: nil, preferredStyle: .alert)
            alert.addTextField { $0.placeholder = "Playlist name"; $0.autocapitalizationType = .words }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Create", style: .default) { _ in
                guard let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespaces),
                      !name.isEmpty else { return }
                do {
                    let playlist = try DatabaseManager.shared.createPlaylist(name: name)
                    if let id = playlist.id {
                        try DatabaseManager.shared.addTrackToPlaylist(playlistId: id, trackFileURL: relativeURL)
                    }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    ToastView.show("Added to \(name)", in: self.view, style: .success)
                } catch {
                    AppLogger.error("Failed to create playlist: \(error.localizedDescription)", category: .database)
                }
            })
            self.present(alert, animated: true)
        }
        playlistActions.append(newPlaylistAction)

        let addToPlaylistMenu = UIMenu(
            title: "Add to Playlist",
            image: UIImage(systemName: "text.badge.plus"),
            children: playlistActions
        )

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
}

extension LibraryViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        impactLight.impactOccurred()

        switch item {
        case .album(let album):
            let detail = AlbumDetailViewController(album: album)
            navigationController?.pushViewController(detail, animated: true)
        case .song(let track):
            AudioPlayer.shared.play(viewModel.sortedSongs, startingAt: viewModel.sortedSongs.firstIndex(of: track) ?? 0)
        case .artist(let artist):
            let albums = viewModel.albumsForArtist(artist.name)
            let vc = ArtistDetailViewController(artistName: artist.name, albums: albums)
            navigationController?.pushViewController(vc, animated: true)
        case .playlist(let playlist):
            let vc = PlaylistDetailViewController(playlistId: playlist.id, playlistName: playlist.name)
            navigationController?.pushViewController(vc, animated: true)
        case .charts:
            let vc = ChartsViewController()
            navigationController?.pushViewController(vc, animated: true)
        }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              let item = dataSource.itemIdentifier(for: indexPath) else { return nil }

        switch item {
        case .album(let album):
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                let playAction = UIAction(title: "Play", image: UIImage(systemName: "play.fill")) { _ in
                    AudioPlayer.shared.play(album.tracks, startingAt: 0)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                let shuffleAction = UIAction(title: "Shuffle", image: UIImage(systemName: "shuffle")) { _ in
                    var shuffled = album.tracks
                    shuffled.shuffle()
                    AudioPlayer.shared.play(shuffled, startingAt: 0)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                let playNextAction = UIAction(title: "Play Next", image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")) { _ in
                    for track in album.tracks.reversed() {
                        AudioPlayer.shared.insertNext(track)
                    }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
                let addToQueueAction = UIAction(title: "Add to Queue", image: UIImage(systemName: "text.append")) { _ in
                    for track in album.tracks {
                        AudioPlayer.shared.addToQueue(track)
                    }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
                let shareAlbum = UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                    guard let self else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    self.shareAlbumViaSonglink(title: album.title, artist: album.artist, from: self.view)
                }
                let shareMenu = UIMenu(options: .displayInline, children: [shareAlbum])
                return UIMenu(children: [playAction, shuffleAction, playNextAction, addToQueueAction, shareMenu])
            }
        case .song(let track):
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                self?.buildSongContextMenu(for: track)
            }
        default:
            return nil
        }
    }
}

extension LibraryViewController: UISearchResultsUpdating {

    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces) ?? ""
        viewModel.search(query: query)
    }
}

extension LibraryViewController: UIDocumentPickerDelegate {

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task { await viewModel.importFiles(from: urls) }
    }
}
