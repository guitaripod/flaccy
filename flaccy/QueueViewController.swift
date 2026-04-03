import UIKit

final class QueueViewController: UIViewController, SonglinkShareable {

    private enum Section: Int, CaseIterable {
        case nowPlaying
        case upNext
    }

    private let tableView = UITableView(frame: .zero, style: .grouped)
    private let shuffleButton = UIButton(type: .system)
    private let repeatButton = UIButton(type: .system)
    private let impactLight = UIImpactFeedbackGenerator(style: .light)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Queue"

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Clear", style: .plain, target: self, action: #selector(clearTapped)
        )
        navigationItem.rightBarButtonItem?.tintColor = .systemRed

        setupTableView()
        setupControlsBar()
        updateClearButton()

        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: AudioPlayer.queueDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: AudioPlayer.trackDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateShuffleRepeat), name: AudioPlayer.shuffleRepeatDidChange, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupTableView() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(QueueTrackCell.self, forCellReuseIdentifier: QueueTrackCell.reuseID)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.allowsSelectionDuringEditing = true
        tableView.setEditing(true, animated: false)
        view.addSubview(tableView)
    }

    private func setupControlsBar() {
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)

        shuffleButton.setImage(UIImage(systemName: "shuffle", withConfiguration: config), for: .normal)
        shuffleButton.addAction(UIAction { _ in AudioPlayer.shared.toggleShuffle() }, for: .touchUpInside)

        repeatButton.setImage(UIImage(systemName: "repeat", withConfiguration: config), for: .normal)
        repeatButton.addAction(UIAction { _ in AudioPlayer.shared.cycleRepeatMode() }, for: .touchUpInside)

        updateShuffleRepeat()

        let spacer = UIView()
        let stack = UIStackView(arrangedSubviews: [shuffleButton, spacer, repeatButton])
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        let bar = UIView()
        bar.backgroundColor = .secondarySystemBackground
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        view.addSubview(bar)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -12),

            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: bar.topAnchor),
        ])
    }

    private var upNextTracks: ArraySlice<Track> {
        let player = AudioPlayer.shared
        guard !player.queue.isEmpty, player.currentIndex + 1 < player.queue.count else { return [] }
        return player.queue[(player.currentIndex + 1)...]
    }

    private func updateClearButton() {
        navigationItem.rightBarButtonItem?.isEnabled = !AudioPlayer.shared.queue.isEmpty
    }

    @objc private func clearTapped() {
        let alert = UIAlertController(title: "Clear Queue", message: "Stop playback and remove all tracks?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { _ in
            AudioPlayer.shared.clearQueue()
        })
        present(alert, animated: true)
    }

    @objc private func reload() {
        tableView.reloadData()
        updateClearButton()
    }

    @objc private func updateShuffleRepeat() {
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        shuffleButton.tintColor = AudioPlayer.shared.shuffleEnabled ? .systemBlue : .secondaryLabel

        let mode = AudioPlayer.shared.repeatMode
        switch mode {
        case .off:
            repeatButton.setImage(UIImage(systemName: "repeat", withConfiguration: config), for: .normal)
            repeatButton.tintColor = .secondaryLabel
        case .all:
            repeatButton.setImage(UIImage(systemName: "repeat", withConfiguration: config), for: .normal)
            repeatButton.tintColor = .systemBlue
        case .one:
            repeatButton.setImage(UIImage(systemName: "repeat.1", withConfiguration: config), for: .normal)
            repeatButton.tintColor = .systemBlue
        }
    }
}

extension QueueViewController: UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .nowPlaying: return AudioPlayer.shared.currentTrack != nil ? "Now Playing" : nil
        case .upNext: return upNextTracks.isEmpty ? nil : "Up Next"
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else { return 0 }
        switch section {
        case .nowPlaying: return AudioPlayer.shared.currentTrack != nil ? 1 : 0
        case .upNext: return upNextTracks.count
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: QueueTrackCell.reuseID, for: indexPath) as! QueueTrackCell
        let player = AudioPlayer.shared

        guard let section = Section(rawValue: indexPath.section) else { return cell }
        switch section {
        case .nowPlaying:
            if let track = player.currentTrack {
                cell.configure(with: track, isCurrentTrack: true, isPlaying: player.isPlaying)
            }
        case .upNext:
            let upNext = Array(upNextTracks)
            if indexPath.row < upNext.count {
                cell.configure(with: upNext[indexPath.row], isCurrentTrack: false, isPlaying: false)
            }
        }

        return cell
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        guard let section = Section(rawValue: indexPath.section) else { return false }
        return section == .upNext
    }

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        guard let section = Section(rawValue: indexPath.section) else { return false }
        return section == .upNext
    }

    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        guard sourceIndexPath.section == Section.upNext.rawValue,
              destinationIndexPath.section == Section.upNext.rawValue else { return }

        let player = AudioPlayer.shared
        let sourceQueueIndex = player.currentIndex + 1 + sourceIndexPath.row
        let destQueueIndex = player.currentIndex + 1 + destinationIndexPath.row

        AudioPlayer.shared.moveInQueue(from: sourceQueueIndex, to: destQueueIndex)
    }

    func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath, toProposedIndexPath proposedDestinationIndexPath: IndexPath) -> IndexPath {
        if proposedDestinationIndexPath.section == Section.nowPlaying.rawValue {
            return IndexPath(row: 0, section: Section.upNext.rawValue)
        }
        return proposedDestinationIndexPath
    }
}

extension QueueViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        impactLight.impactOccurred()

        guard let section = Section(rawValue: indexPath.section) else { return }
        switch section {
        case .nowPlaying:
            break
        case .upNext:
            let queueIndex = AudioPlayer.shared.currentIndex + 1 + indexPath.row
            AudioPlayer.shared.jumpToIndex(queueIndex)
        }
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let section = Section(rawValue: indexPath.section), section == .upNext else { return nil }
        let upNext = Array(upNextTracks)
        guard indexPath.row < upNext.count else { return nil }
        let track = upNext[indexPath.row]

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let viewArtist = UIAction(title: "Go to Artist", image: UIImage(systemName: "person")) { _ in
                guard let self else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                let artistAlbums = Library.shared.albums.filter { $0.artist == track.artist }
                let vc = ArtistDetailViewController(artistName: track.artist, albums: artistAlbums)
                self.dismiss(animated: true) {
                    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                          let rootVC = scene.windows.first?.rootViewController,
                          let nav = rootVC.children.compactMap({ $0 as? UINavigationController }).first else { return }
                    nav.pushViewController(vc, animated: true)
                }
            }
            let removeAction = UIAction(title: "Remove", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                let queueIndex = AudioPlayer.shared.currentIndex + 1 + indexPath.row
                AudioPlayer.shared.removeFromQueue(at: queueIndex)
            }
            let share = UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                guard let self else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                self.shareTrackViaSonglink(title: track.title, artist: track.artist, from: self.view)
            }
            let shareMenu = UIMenu(options: .displayInline, children: [share])
            return UIMenu(children: [viewArtist, removeAction, shareMenu])
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard Section(rawValue: indexPath.section) == .upNext else { return nil }

        let remove = UIContextualAction(style: .destructive, title: "Remove") { _, _, completion in
            let queueIndex = AudioPlayer.shared.currentIndex + 1 + indexPath.row
            AudioPlayer.shared.removeFromQueue(at: queueIndex)
            completion(true)
        }

        return UISwipeActionsConfiguration(actions: [remove])
    }

    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        .none
    }

    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        false
    }
}

final class QueueTrackCell: UITableViewCell {

    static let reuseID = "QueueTrackCell"

    private let artworkView = UIImageView()
    private let trackTitleLabel = UILabel()
    private let trackArtistLabel = UILabel()
    private let durationLabel = UILabel()
    private let nowPlayingIcon = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.layer.cornerRadius = 4
        artworkView.backgroundColor = .tertiarySystemFill
        artworkView.tintColor = .tertiaryLabel

        let indicatorConfig = UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        nowPlayingIcon.image = UIImage(systemName: "speaker.wave.2.fill", withConfiguration: indicatorConfig)
        nowPlayingIcon.tintColor = .systemBlue
        nowPlayingIcon.contentMode = .center
        nowPlayingIcon.isHidden = true

        trackTitleLabel.font = .preferredFont(forTextStyle: .body)
        trackTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        trackArtistLabel.font = .preferredFont(forTextStyle: .caption1)
        trackArtistLabel.textColor = .secondaryLabel
        trackArtistLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        durationLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        durationLabel.textColor = .tertiaryLabel
        durationLabel.setContentHuggingPriority(.required, for: .horizontal)

        let textStack = UIStackView(arrangedSubviews: [trackTitleLabel, trackArtistLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        let mainStack = UIStackView(arrangedSubviews: [artworkView, nowPlayingIcon, textStack, durationLabel])
        mainStack.spacing = 10
        mainStack.alignment = .center
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(mainStack)

        NSLayoutConstraint.activate([
            artworkView.widthAnchor.constraint(equalToConstant: 44),
            artworkView.heightAnchor.constraint(equalToConstant: 44),
            nowPlayingIcon.widthAnchor.constraint(equalToConstant: 20),

            mainStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            mainStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            mainStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            mainStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with track: Track, isCurrentTrack: Bool, isPlaying: Bool) {
        trackTitleLabel.text = track.title
        trackArtistLabel.text = track.artist

        if let artwork = track.artwork {
            artworkView.contentMode = .scaleAspectFill
            artworkView.image = artwork
        } else {
            artworkView.contentMode = .center
            artworkView.image = UIImage(systemName: "music.note")
        }

        let total = Int(track.duration)
        durationLabel.text = String(format: "%d:%02d", total / 60, total % 60)

        nowPlayingIcon.isHidden = !isCurrentTrack

        if isCurrentTrack {
            trackTitleLabel.textColor = .systemBlue
            trackArtistLabel.textColor = .systemBlue
            nowPlayingIcon.image = UIImage(
                systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
            )
        } else {
            trackTitleLabel.textColor = .label
            trackArtistLabel.textColor = .secondaryLabel
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkView.image = nil
        nowPlayingIcon.isHidden = true
        trackTitleLabel.textColor = .label
        trackArtistLabel.textColor = .secondaryLabel
    }
}
