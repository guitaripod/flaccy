import FlaccyCore
import MidgarCore
import UIKit

/// The Search tab. It asks the Library's own view model for matches, so a
/// query finds exactly what the Library's segments would, and shows albums,
/// artists, songs and playlists together.
final class SearchViewController: UIViewController {

    nonisolated enum Section: Int, CaseIterable, Sendable {
        case albums
        case artists
        case songs
        case playlists

        var title: String {
            switch self {
            case .albums: String(localized: "Albums")
            case .artists: String(localized: "Artists")
            case .songs: String(localized: "Songs")
            case .playlists: String(localized: "Playlists")
            }
        }
    }

    private static let songLimit = 100
    private static let debounce: Duration = .milliseconds(150)

    private let libraryViewModel: LibraryViewModel
    private let searchController = UISearchController(searchResultsController: nil)
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, SearchItem>!
    private var results = LibraryViewModel.SearchResults()
    private var query = ""
    private var searchTask: Task<Void, Never>?
    private let impact = UIImpactFeedbackGenerator(style: .light)

    init(libraryViewModel: LibraryViewModel) {
        self.libraryViewModel = libraryViewModel
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Search")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.hidesSearchBarWhenScrolling = false
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = String(localized: "Albums, Artists, Songs")
        navigationItem.searchController = searchController
        definesPresentationContext = true

        setupCollectionView()
        setupDataSource()
        refreshPlaceholder()
        NotificationCenter.default.addObserver(
            self, selector: #selector(libraryDidChange), name: Library.didUpdateNotification, object: nil
        )
    }

    @objc private func libraryDidChange() {
        guard !query.isEmpty else { return }
        runSearch()
    }

    private func setupCollectionView() {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.showsSeparators = false
        configuration.headerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.list(using: configuration)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .onDrag
        collectionView.contentInsetAdjustmentBehavior = .always
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupDataSource() {
        let cellRegistration = UICollectionView.CellRegistration<SearchResultCell, SearchItem> { cell, _, item in
            cell.configure(with: item)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: item)
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            guard let section = self?.dataSource.sectionIdentifier(for: indexPath.section) else { return }
            var content = UIListContentConfiguration.prominentInsetGroupedHeader()
            content.text = section.title
            content.textProperties.font = .scaled(.title3, size: 20, weight: .bold)
            content.textProperties.color = .label
            header.contentConfiguration = content
            header.accessibilityTraits = .header
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }
    }

    #if DEBUG
    func demoSearch(query text: String) {
        loadViewIfNeeded()
        searchController.searchBar.text = text
        searchController.isActive = false
        query = text
        results = libraryViewModel.searchResults(for: text)
        applyResults()
    }
    #endif

    private func runSearch() {
        searchTask?.cancel()
        let pending = query
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self, pending == self.query else { return }
            self.results = self.libraryViewModel.searchResults(for: pending)
            self.applyResults()
        }
    }

    private func applyResults() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, SearchItem>()
        if !results.albums.isEmpty {
            snapshot.appendSections([.albums])
            snapshot.appendItems(results.albums.map { .album($0) })
        }
        if !results.artists.isEmpty {
            snapshot.appendSections([.artists])
            snapshot.appendItems(results.artists.map { .artist($0, cover: libraryViewModel.firstAlbum(forArtist: $0.name)) })
        }
        if !results.songs.isEmpty {
            snapshot.appendSections([.songs])
            snapshot.appendItems(results.songs.prefix(Self.songLimit).map { .song($0) })
        }
        if !results.playlists.isEmpty {
            snapshot.appendSections([.playlists])
            snapshot.appendItems(results.playlists.map { .playlist($0) })
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        refreshPlaceholder()
    }

    private func refreshPlaceholder() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.image = UIImage(systemName: "magnifyingglass")
            configuration.text = SearchCopy.prompt
            configuration.secondaryText = SearchCopy.promptDetail
            contentUnavailableConfiguration = configuration
        } else if results.isEmpty {
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.search()
        } else {
            contentUnavailableConfiguration = nil
        }
    }
}

extension SearchViewController: UISearchResultsUpdating {

    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text ?? ""
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchTask?.cancel()
            results = LibraryViewModel.SearchResults()
            applyResults()
        } else {
            runSearch()
        }
    }
}

extension SearchViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        impact.impactOccurred()
        switch item {
        case .album(let album):
            navigationController?.pushViewController(AlbumDetailViewController(album: album), animated: true)
        case .artist(let artist, _):
            let albums = libraryViewModel.albumsForArtist(artist.name)
            navigationController?.pushViewController(
                ArtistDetailViewController(artistName: artist.name, albums: albums.credited, appearsOn: albums.appearsOn),
                animated: true
            )
        case .song(let track):
            let songs = Array(results.songs.prefix(Self.songLimit))
            AudioPlayer.shared.play(songs, startingAt: songs.firstIndex(of: track) ?? 0)
        case .playlist(let playlist):
            navigationController?.pushViewController(
                PlaylistDetailViewController(playlistId: playlist.id, playlistName: playlist.name),
                animated: true
            )
        }
    }
}
