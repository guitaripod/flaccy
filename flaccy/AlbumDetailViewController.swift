import UIKit

final class AlbumDetailViewController: UIViewController {

    private let album: Album
    private let audioPlayer: AudioPlaying
    private var tableView: UITableView!
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)

    init(album: Album, audioPlayer: AudioPlaying = AudioPlayer.shared) {
        self.album = album
        self.audioPlayer = audioPlayer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        setupTableView()

        NotificationCenter.default.addObserver(self, selector: #selector(playbackChanged), name: AudioPlayer.trackDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(playbackChanged), name: AudioPlayer.playbackStateDidChange, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func playbackChanged() {
        tableView.reloadData()
    }

    private func setupTableView() {
        tableView = UITableView(frame: .zero, style: .plain)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.register(AlbumTrackCell.self, forCellReuseIdentifier: AlbumTrackCell.reuseID)
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

        let artworkShadow = UIView()
        artworkShadow.layer.shadowColor = UIColor.black.cgColor
        artworkShadow.layer.shadowOpacity = 0.25
        artworkShadow.layer.shadowOffset = CGSize(width: 0, height: 8)
        artworkShadow.layer.shadowRadius = 20

        let artworkView = UIImageView()
        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.layer.cornerRadius = 12
        artworkView.backgroundColor = .tertiarySystemFill
        artworkView.tintColor = .tertiaryLabel
        artworkView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 60, weight: .ultraLight)

        if let artwork = album.artwork {
            artworkView.image = artwork
        } else {
            artworkView.contentMode = .center
            artworkView.image = UIImage(systemName: "music.note")
        }

        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkShadow.addSubview(artworkView)
        NSLayoutConstraint.activate([
            artworkView.topAnchor.constraint(equalTo: artworkShadow.topAnchor),
            artworkView.leadingAnchor.constraint(equalTo: artworkShadow.leadingAnchor),
            artworkView.trailingAnchor.constraint(equalTo: artworkShadow.trailingAnchor),
            artworkView.bottomAnchor.constraint(equalTo: artworkShadow.bottomAnchor),
            artworkView.heightAnchor.constraint(equalTo: artworkView.widthAnchor),
        ])

        let titleLabel = UILabel()
        titleLabel.text = album.title
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2

        let artistLabel = UILabel()
        artistLabel.text = album.artist
        artistLabel.font = .systemFont(ofSize: 16, weight: .regular)
        artistLabel.textColor = .secondaryLabel
        artistLabel.textAlignment = .center

        let metaLabel = UILabel()
        metaLabel.font = .systemFont(ofSize: 14, weight: .regular)
        metaLabel.textColor = .tertiaryLabel
        metaLabel.textAlignment = .center
        var metaParts: [String] = []
        if let year = album.year, !year.isEmpty { metaParts.append(year) }
        if let genre = album.genre, !genre.isEmpty { metaParts.append(genre) }
        metaLabel.text = metaParts.joined(separator: " \u{00B7} ")
        metaLabel.isHidden = metaParts.isEmpty

        let totalSeconds = album.tracks.reduce(0) { $0 + Int($1.duration) }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let durationText: String
        if hours > 0 {
            durationText = "\(album.tracks.count) tracks \u{00B7} \(hours) hr \(minutes) min"
        } else {
            durationText = "\(album.tracks.count) tracks \u{00B7} \(minutes) min"
        }

        let durationLabel = UILabel()
        durationLabel.font = .systemFont(ofSize: 14, weight: .regular)
        durationLabel.textColor = .tertiaryLabel
        durationLabel.textAlignment = .center
        durationLabel.text = durationText

        let infoStack = UIStackView(arrangedSubviews: [titleLabel, artistLabel, metaLabel, durationLabel])
        infoStack.axis = .vertical
        infoStack.spacing = 4
        infoStack.alignment = .center

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

        let mainStack = UIStackView(arrangedSubviews: [artworkShadow, infoStack, buttonStack])
        mainStack.axis = .vertical
        mainStack.spacing = 16
        mainStack.setCustomSpacing(24, after: infoStack)
        mainStack.alignment = .center
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(mainStack)

        let leading = mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32)
        let trailing = mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -32)
        let bottom = mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24)
        leading.priority = .defaultHigh
        trailing.priority = .defaultHigh
        bottom.priority = .defaultHigh

        let artworkWidth = artworkShadow.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
        artworkWidth.priority = .defaultHigh
        let buttonWidth = buttonStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
        buttonWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            leading, trailing, bottom,
            artworkWidth, buttonWidth,
        ])

        return container
    }

    private func playTapped() {
        impactMedium.impactOccurred()
        audioPlayer.play(album.tracks, startingAt: 0)
    }

    private func shuffleTapped() {
        impactMedium.impactOccurred()
        var shuffled = album.tracks
        shuffled.shuffle()
        audioPlayer.play(shuffled, startingAt: 0)
    }
}

extension AlbumDetailViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        album.tracks.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: AlbumTrackCell.reuseID, for: indexPath) as! AlbumTrackCell
        let track = album.tracks[indexPath.row]
        let isNowPlaying = (audioPlayer.currentTrack?.fileURL == track.fileURL && audioPlayer.isPlaying)
        cell.configure(with: track, index: indexPath.row, isNowPlaying: isNowPlaying)
        return cell
    }
}

extension AlbumDetailViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        impactLight.impactOccurred()
        audioPlayer.play(album.tracks, startingAt: indexPath.row)
    }

    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        let track = album.tracks[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.buildTrackContextMenu(for: track)
        }
    }

    private func buildTrackContextMenu(for track: Track) -> UIMenu {
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
                        AppLogger.error("Failed to add track to playlist: \(error.localizedDescription)", category: .database)
                        ToastView.show("Failed to add to playlist", in: self.view, style: .error)
                    }
                }
                playlistActions.append(action)
            }
        } catch {
            AppLogger.error("Failed to fetch playlists: \(error.localizedDescription)", category: .database)
        }

        let newPlaylistAction = UIAction(
            title: "New Playlist\u{2026}",
            image: UIImage(systemName: "plus")
        ) { [weak self] _ in
            self?.promptNewPlaylistAndAdd(trackFileURL: relativeURL)
        }
        playlistActions.append(newPlaylistAction)

        let addToPlaylistMenu = UIMenu(
            title: "Add to Playlist",
            image: UIImage(systemName: "text.badge.plus"),
            children: playlistActions
        )

        let playNext = UIAction(
            title: "Play Next",
            image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")
        ) { [weak self] _ in
            guard let self else { return }
            AudioPlayer.shared.insertNext(track)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            ToastView.show("Playing next", in: self.view, style: .info)
        }

        let addToQueue = UIAction(
            title: "Add to Queue",
            image: UIImage(systemName: "text.append")
        ) { [weak self] _ in
            guard let self else { return }
            AudioPlayer.shared.addToQueue(track)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            ToastView.show("Added to queue", in: self.view, style: .info)
        }

        return UIMenu(children: [playNext, addToQueue, addToPlaylistMenu])
    }

    private func promptNewPlaylistAndAdd(trackFileURL: String) {
        let alert = UIAlertController(title: "New Playlist", message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "Playlist name"
            textField.autocapitalizationType = .words
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { _ in
            guard let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty else { return }
            do {
                let playlist = try DatabaseManager.shared.createPlaylist(name: name)
                if let playlistId = playlist.id {
                    try DatabaseManager.shared.addTrackToPlaylist(playlistId: playlistId, trackFileURL: trackFileURL)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                AppLogger.error("Failed to create playlist and add track: \(error.localizedDescription)", category: .database)
            }
        })
        present(alert, animated: true)
    }
}

private final class AlbumTrackCell: UITableViewCell {

    static let reuseID = "AlbumTrackCell"

    let numberLabel = UILabel()
    let nowPlayingIcon = UIImageView()
    let trackTitleLabel = UILabel()
    let durationLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear

        numberLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        numberLabel.textColor = .tertiaryLabel
        numberLabel.textAlignment = .center

        nowPlayingIcon.image = UIImage(
            systemName: "speaker.wave.2.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        )
        nowPlayingIcon.tintColor = .systemBlue
        nowPlayingIcon.contentMode = .center
        nowPlayingIcon.isHidden = true

        trackTitleLabel.font = .preferredFont(forTextStyle: .body)
        trackTitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trackTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        durationLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        durationLabel.textColor = .tertiaryLabel
        durationLabel.textAlignment = .right

        let numberContainer = UIView()
        numberContainer.translatesAutoresizingMaskIntoConstraints = false
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        nowPlayingIcon.translatesAutoresizingMaskIntoConstraints = false
        numberContainer.addSubview(numberLabel)
        numberContainer.addSubview(nowPlayingIcon)

        NSLayoutConstraint.activate([
            numberLabel.topAnchor.constraint(equalTo: numberContainer.topAnchor),
            numberLabel.bottomAnchor.constraint(equalTo: numberContainer.bottomAnchor),
            numberLabel.leadingAnchor.constraint(equalTo: numberContainer.leadingAnchor),
            numberLabel.trailingAnchor.constraint(equalTo: numberContainer.trailingAnchor),
            nowPlayingIcon.centerXAnchor.constraint(equalTo: numberContainer.centerXAnchor),
            nowPlayingIcon.centerYAnchor.constraint(equalTo: numberContainer.centerYAnchor),
        ])

        let stack = UIStackView(arrangedSubviews: [numberContainer, trackTitleLabel, durationLabel])
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            numberContainer.widthAnchor.constraint(equalToConstant: 28),
            durationLabel.widthAnchor.constraint(equalToConstant: 48),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with track: Track, index: Int, isNowPlaying: Bool) {
        numberLabel.text = track.trackNumber > 0 ? "\(track.trackNumber)" : "\(index + 1)"
        trackTitleLabel.text = track.title
        let minutes = Int(track.duration) / 60
        let seconds = Int(track.duration) % 60
        durationLabel.text = String(format: "%d:%02d", minutes, seconds)

        numberLabel.isHidden = isNowPlaying
        nowPlayingIcon.isHidden = !isNowPlaying
        trackTitleLabel.textColor = isNowPlaying ? .systemBlue : .label
    }
}
