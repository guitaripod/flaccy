import FlaccyCore
import MidgarCore
import UIKit

/// The Add Songs sheet: the playlist's suggestions first, then every song in
/// the library from A to Z, with a search across titles, artists and albums.
/// Tapping songs ticks them, songs the playlist already holds are marked and
/// cannot be ticked, and Add puts the ticked ones in, in the order they were
/// ticked, as one commit.
final class PlaylistAddSongsViewController: UIViewController {

    private nonisolated enum Section: Hashable, Sendable {
        case suggested
        case songs
    }

    private let playlistId: Int64
    private let playlistName: String
    var suggestions: [Track] = []

    private var tableView: UITableView!
    private var dataSource: UITableViewDiffableDataSource<Section, URL>!
    private var library: [Track] = []
    private var tracksByURL: [URL: Track] = [:]
    private var held: Set<String> = []
    private var picked: [URL] = []
    private var query = ""
    private let searchController = UISearchController(searchResultsController: nil)
    private let selectionFeedback = UISelectionFeedbackGenerator()

    init(playlistId: Int64, playlistName: String) {
        self.playlistId = playlistId
        self.playlistName = playlistName
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = String(localized: "Add to \(playlistName)")
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = String(localized: "Songs, Artists, Albums")
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        setupTable()
        load()
        updateAddButton()
    }

    private func setupTable() {
        tableView = UITableView(frame: .zero, style: .plain)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.keyboardDismissMode = .onDrag
        tableView.register(PlaylistPickCell.self, forCellReuseIdentifier: PlaylistPickCell.reuseID)
        tableView.accessibilityIdentifier = "playlist.addSongs.list"
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        dataSource = UITableViewDiffableDataSource(tableView: tableView) { [weak self] tableView, indexPath, url in
            let cell = tableView.dequeueReusableCell(withIdentifier: PlaylistPickCell.reuseID, for: indexPath) as! PlaylistPickCell
            guard let self, let track = self.tracksByURL[url] else { return cell }
            cell.configure(
                with: track,
                isHeld: self.held.contains(TrackContextMenu.relativePath(for: track)),
                isPicked: self.picked.contains(url)
            )
            return cell
        }
        dataSource.defaultRowAnimation = .fade
    }

    private func load() {
        held = Set(((try? DatabaseManager.shared.fetchPlaylistTracks(playlistId: playlistId)) ?? []).map(\.trackFileURL))
        let all = Library.shared.allTracks
        Task { [weak self] in
            let sorted = await Task.detached(priority: .userInitiated) {
                all.sorted {
                    let order = $0.title.localizedStandardCompare($1.title)
                    return order == .orderedSame ? $0.artist.localizedStandardCompare($1.artist) == .orderedAscending : order == .orderedAscending
                }
            }.value
            guard let self else { return }
            self.library = sorted
            self.tracksByURL = Dictionary((sorted + self.suggestions).map { ($0.fileURL, $0) }, uniquingKeysWith: { first, _ in first })
            self.applySnapshot()
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, URL>()
        let folded = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespaces)
        if folded.isEmpty {
            let suggested = suggestions.map(\.fileURL)
            if !suggested.isEmpty {
                snapshot.appendSections([.suggested])
                snapshot.appendItems(suggested, toSection: .suggested)
            }
            snapshot.appendSections([.songs])
            let shown = Set(suggested)
            snapshot.appendItems(library.map(\.fileURL).filter { !shown.contains($0) }, toSection: .songs)
        } else {
            snapshot.appendSections([.songs])
            snapshot.appendItems(library.filter { track in
                [track.title, track.artist, track.albumTitle].contains {
                    $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(folded)
                }
            }.map(\.fileURL), toSection: .songs)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func updateAddButton() {
        let title = picked.isEmpty ? String(localized: "Add") : String(localized: "Add \(picked.count)")
        let add = UIBarButtonItem(title: title, primaryAction: UIAction { [weak self] _ in self?.addPicked() })
        if #available(iOS 26.0, *) {
            add.style = .prominent
        } else {
            add.style = .done
        }
        add.isEnabled = !picked.isEmpty
        add.accessibilityIdentifier = "playlist.addSongs.add"
        navigationItem.rightBarButtonItem = add
    }

    private func addPicked() {
        let tracks = picked.compactMap { tracksByURL[$0] }
        let presenter = presentingViewController
        dismiss(animated: true) {
            PlaylistWriter.add(tracks, toPlaylist: self.playlistId, named: self.playlistName, in: presenter?.view)
        }
    }
}

extension PlaylistAddSongsViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard let url = dataSource.itemIdentifier(for: indexPath), let track = tracksByURL[url] else { return }
        guard !held.contains(TrackContextMenu.relativePath(for: track)) else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        if let index = picked.firstIndex(of: url) {
            picked.remove(at: index)
        } else {
            picked.append(url)
        }
        selectionFeedback.selectionChanged()
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([url])
        dataSource.apply(snapshot, animatingDifferences: false)
        updateAddButton()
    }

    private func sectionTitle(at section: Int) -> String? {
        guard query.isEmpty, dataSource.snapshot().sectionIdentifiers.count > 1 else { return nil }
        return dataSource.snapshot().sectionIdentifiers[section] == .suggested ? PlaylistCopy.suggestedTitle : String(localized: "Songs")
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let title = sectionTitle(at: section) else { return nil }
        var content = UIListContentConfiguration.prominentInsetGroupedHeader()
        content.text = title
        let header = UITableViewHeaderFooterView()
        header.contentConfiguration = content
        return header
    }
}

extension PlaylistAddSongsViewController: UISearchResultsUpdating {

    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard text != query else { return }
        query = text
        applySnapshot()
    }
}

/// A song in the Add Songs sheet: cover, title and artist, a tick when it is
/// picked, and a note when the playlist already holds it.
final class PlaylistPickCell: UITableViewCell {

    static let reuseID = "PlaylistPickCell"

    private var artworkKey: String?

    func configure(with track: Track, isHeld: Bool, isPicked: Bool) {
        var content = UIListContentConfiguration.subtitleCell()
        content.text = track.title
        content.secondaryText = isHeld ? "\(track.artist) · \(PlaylistCopy.inPlaylist)" : track.artist
        content.secondaryTextProperties.color = .secondaryLabel
        content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
        content.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 44)
        content.imageProperties.cornerRadius = 6
        let key = track.albumTitle + "\u{0}" + track.artist
        artworkKey = key
        content.image = AlbumArtworkCache.shared.thumbnail(forAlbum: track.albumTitle, artist: track.artist)
            ?? UIImage(systemName: "music.note")
        contentConfiguration = content
        if content.image?.isSymbolImage == true {
            AlbumArtworkCache.shared.loadThumbnail(forAlbum: track.albumTitle, artist: track.artist) { [weak self] image in
                guard let self, self.artworkKey == key, let image,
                      var updated = self.contentConfiguration as? UIListContentConfiguration else { return }
                updated.image = image
                self.contentConfiguration = updated
            }
        }
        let symbol = isHeld ? "checkmark.circle.fill" : (isPicked ? "checkmark.circle.fill" : "circle")
        let mark = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22)))
        mark.tintColor = isHeld ? .tertiaryLabel : (isPicked ? .tintColor : .tertiaryLabel)
        accessoryView = mark
        contentView.alpha = isHeld ? 0.5 : 1
        accessibilityTraits = isPicked ? [.button, .selected] : .button
        accessibilityValue = isHeld ? PlaylistCopy.inPlaylist : nil
    }
}
