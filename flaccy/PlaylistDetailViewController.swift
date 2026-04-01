import UIKit

final class PlaylistDetailViewController: UIViewController {

    private let playlistId: Int64
    private let playlistName: String
    private let audioPlayer: AudioPlaying
    private let db = DatabaseManager.shared
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)

    private var tableView: UITableView!
    private var tracks: [Track] = []
    private var playlistTrackRecords: [PlaylistTrackRecord] = []

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
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadTracks()
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView.setEditing(editing, animated: animated)
    }

    private func setupTableView() {
        tableView = UITableView(frame: .zero, style: .plain)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.tableHeaderView = buildHeaderView()
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
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

    private func buildHeaderView() -> UIView {
        let container = UIView()

        let iconView = UIImageView(image: UIImage(systemName: "music.note.list"))
        iconView.tintColor = .tintColor
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 48, weight: .thin)
        iconView.contentMode = .scaleAspectFit

        let playButton = UIButton(configuration: .filled())
        playButton.configuration?.title = "Play"
        playButton.configuration?.image = UIImage(systemName: "play.fill")
        playButton.configuration?.imagePadding = 6
        playButton.configuration?.cornerStyle = .capsule
        playButton.addAction(UIAction { [weak self] _ in self?.playTapped() }, for: .touchUpInside)

        let shuffleButton = UIButton(configuration: .tinted())
        shuffleButton.configuration?.title = "Shuffle"
        shuffleButton.configuration?.image = UIImage(systemName: "shuffle")
        shuffleButton.configuration?.imagePadding = 6
        shuffleButton.configuration?.cornerStyle = .capsule
        shuffleButton.addAction(UIAction { [weak self] _ in self?.shuffleTapped() }, for: .touchUpInside)

        let buttonStack = UIStackView(arrangedSubviews: [playButton, shuffleButton])
        buttonStack.axis = .horizontal
        buttonStack.spacing = 12
        buttonStack.distribution = .fillEqually

        let mainStack = UIStackView(arrangedSubviews: [iconView, buttonStack])
        mainStack.axis = .vertical
        mainStack.spacing = 20
        mainStack.alignment = .center
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(mainStack)

        let leading = mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32)
        let trailing = mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -32)
        let bottom = mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24)
        leading.priority = .defaultHigh
        trailing.priority = .defaultHigh
        bottom.priority = .defaultHigh

        let buttonWidth = buttonStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
        buttonWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            leading, trailing, bottom,
            buttonWidth,
        ])

        return container
    }

    private func loadTracks() {
        do {
            playlistTrackRecords = try db.fetchPlaylistTracks(playlistId: playlistId)
            let allDBTracks = try db.fetchAllTracks()
            let tracksByURL = Dictionary(allDBTracks.map { ($0.fileURL, $0) }, uniquingKeysWith: { first, _ in first })
            let albumsWithTracks = try db.fetchAlbumsWithTracks()

            var artworkByAlbumKey = [String: UIImage]()
            for (albumInfo, albumTracks) in albumsWithTracks {
                guard let first = albumTracks.first else { continue }
                let key = "\(first.albumTitle)\0\(first.artist)"
                if let data = albumInfo?.coverArtData, let img = UIImage(data: data) {
                    artworkByAlbumKey[key] = img
                } else if let data = first.artworkData, let img = UIImage(data: data) {
                    artworkByAlbumKey[key] = img
                }
            }

            tracks = playlistTrackRecords.compactMap { playlistTrack in
                guard let record = tracksByURL[playlistTrack.trackFileURL] else { return nil }
                let key = "\(record.albumTitle)\0\(record.artist)"
                return Track.from(record: record, artwork: artworkByAlbumKey[key])
            }

            tableView.reloadData()
        } catch {
            AppLogger.error("Failed to load playlist tracks: \(error.localizedDescription)", category: .database)
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
        let cell = UITableViewCell(style: .default, reuseIdentifier: "PlaylistTrackRow")
        cell.selectionStyle = .default
        cell.backgroundColor = .clear

        let track = tracks[indexPath.row]

        let titleLabel = UILabel()
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.text = track.title
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let artistLabel = UILabel()
        artistLabel.font = .preferredFont(forTextStyle: .caption1)
        artistLabel.textColor = .secondaryLabel
        artistLabel.text = track.artist

        let infoStack = UIStackView(arrangedSubviews: [titleLabel, artistLabel])
        infoStack.axis = .vertical
        infoStack.spacing = 2

        let minutes = Int(track.duration) / 60
        let seconds = Int(track.duration) % 60
        let durationLabel = UILabel()
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        durationLabel.textColor = .tertiaryLabel
        durationLabel.textAlignment = .right
        durationLabel.text = String(format: "%d:%02d", minutes, seconds)

        let stack = UIStackView(arrangedSubviews: [infoStack, durationLabel])
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            durationLabel.widthAnchor.constraint(equalToConstant: 48),
            stack.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
        ])

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
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            AppLogger.error("Failed to remove track from playlist: \(error.localizedDescription)", category: .database)
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
                AppLogger.error("Failed to reorder playlist track: \(error.localizedDescription)", category: .database)
            }
        }
        impactLight.impactOccurred()
    }
}

extension PlaylistDetailViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        impactLight.impactOccurred()
        audioPlayer.play(tracks, startingAt: indexPath.row)
    }
}
