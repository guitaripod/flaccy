import Combine
import UIKit

final class ChartsViewController: UIViewController {

    private let viewModel = ChartsViewModel()
    private let audioPlayer: AudioPlaying
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)

    private var tableView: UITableView!
    private var segmentedControl: UISegmentedControl!
    private var subtitleLabel: UILabel!
    private var playButton: UIButton!
    private var shuffleButton: UIButton!
    private var spinner: UIActivityIndicatorView!
    private var cancellables = Set<AnyCancellable>()

    init(audioPlayer: AudioPlaying = AudioPlayer.shared) {
        self.audioPlayer = audioPlayer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Last.fm Charts"
        navigationItem.largeTitleDisplayMode = .never

        setupTableView()
        bindViewModel()

        Task {
            await viewModel.loadChart(period: .week)
        }
    }

    private func setupTableView() {
        tableView = UITableView(frame: .zero, style: .plain)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.tableHeaderView = buildHeaderView()

        let refreshControl = UIRefreshControl()
        refreshControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            Task {
                await self.viewModel.loadChart(period: self.viewModel.selectedPeriod)
                self.tableView.refreshControl?.endRefreshing()
            }
        }, for: .valueChanged)
        tableView.refreshControl = refreshControl

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

        let iconView = UIImageView(image: UIImage(systemName: "chart.bar.fill"))
        iconView.tintColor = UIColor(red: 0.84, green: 0.09, blue: 0.09, alpha: 1.0)
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 48, weight: .thin)
        iconView.contentMode = .scaleAspectFit

        subtitleLabel = UILabel()
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center

        segmentedControl = UISegmentedControl(items: ChartPeriod.allCases.map { $0.shortName })
        segmentedControl.selectedSegmentIndex = 0
        segmentedControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.impactLight.impactOccurred()
            let period = ChartPeriod.allCases[self.segmentedControl.selectedSegmentIndex]
            Task { await self.viewModel.loadChart(period: period) }
        }, for: .valueChanged)

        playButton = UIButton(configuration: .filled())
        playButton.configuration?.title = "Play"
        playButton.configuration?.image = UIImage(systemName: "play.fill")
        playButton.configuration?.imagePadding = 6
        playButton.configuration?.cornerStyle = .capsule
        playButton.addAction(UIAction { [weak self] _ in self?.playTapped() }, for: .touchUpInside)

        shuffleButton = UIButton(configuration: .tinted())
        shuffleButton.configuration?.title = "Shuffle"
        shuffleButton.configuration?.image = UIImage(systemName: "shuffle")
        shuffleButton.configuration?.imagePadding = 6
        shuffleButton.configuration?.cornerStyle = .capsule
        shuffleButton.addAction(UIAction { [weak self] _ in self?.shuffleTapped() }, for: .touchUpInside)

        let buttonStack = UIStackView(arrangedSubviews: [playButton, shuffleButton])
        buttonStack.axis = .horizontal
        buttonStack.spacing = 12
        buttonStack.distribution = .fillEqually

        spinner = UIActivityIndicatorView(style: .medium)
        spinner.hidesWhenStopped = true

        let mainStack = UIStackView(arrangedSubviews: [iconView, subtitleLabel, segmentedControl, buttonStack, spinner])
        mainStack.axis = .vertical
        mainStack.spacing = 16
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
        let segmentWidth = segmentedControl.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
        segmentWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            leading, trailing, bottom,
            buttonWidth, segmentWidth,
        ])

        return container
    }

    private func bindViewModel() {
        viewModel.itemsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                guard let self else { return }
                self.updateSubtitle()
                self.updateButtons()
                self.tableView.reloadData()
            }
            .store(in: &cancellables)

        viewModel.loadingPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLoading in
                guard let self else { return }
                if isLoading {
                    self.spinner.startAnimating()
                } else {
                    self.spinner.stopAnimating()
                }
            }
            .store(in: &cancellables)
    }

    private func updateSubtitle() {
        let matched = viewModel.matchedCount
        let total = viewModel.totalCount
        if total == 0 {
            subtitleLabel.text = "No chart data"
        } else {
            subtitleLabel.text = "\(matched) of \(total) tracks in your library"
        }
    }

    private func updateButtons() {
        let hasMatches = viewModel.matchedCount > 0
        playButton.isEnabled = hasMatches
        shuffleButton.isEnabled = hasMatches
    }

    private func playTapped() {
        guard !viewModel.matchedTracks.isEmpty else { return }
        impactMedium.impactOccurred()
        audioPlayer.play(viewModel.matchedTracks, startingAt: 0)
    }

    private func shuffleTapped() {
        guard !viewModel.matchedTracks.isEmpty else { return }
        impactMedium.impactOccurred()
        var shuffled = viewModel.matchedTracks
        shuffled.shuffle()
        audioPlayer.play(shuffled, startingAt: 0)
    }

    private func matchedTrackIndex(for indexPath: IndexPath) -> Int? {
        let item = viewModel.items[indexPath.row]
        guard item.matchedTrack != nil else { return nil }
        var matchIndex = 0
        for i in 0..<indexPath.row {
            if viewModel.items[i].matchedTrack != nil {
                matchIndex += 1
            }
        }
        return matchIndex
    }

    private func relativeURL(for track: Track) -> String {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL
        let trackPath = track.fileURL.standardizedFileURL.path
        let docsPath = docsDir.path
        if trackPath.hasPrefix(docsPath) {
            let rel = String(trackPath.dropFirst(docsPath.count))
            return rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
        }
        return track.fileURL.lastPathComponent
    }

    private func buildTrackContextMenu(for track: Track) -> UIMenu {
        let relURL = relativeURL(for: track)

        var playlistActions: [UIMenuElement] = []
        do {
            let playlists = try DatabaseManager.shared.fetchAllPlaylists()
            for playlist in playlists {
                guard let playlistId = playlist.id else { continue }
                let action = UIAction(title: playlist.name, image: UIImage(systemName: "music.note.list")) { [weak self] _ in
                    guard let self else { return }
                    do {
                        try DatabaseManager.shared.addTrackToPlaylist(playlistId: playlistId, trackFileURL: relURL)
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
                        try DatabaseManager.shared.addTrackToPlaylist(playlistId: id, trackFileURL: relURL)
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
}

extension ChartsViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        viewModel.items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: "ChartRow")
        cell.backgroundColor = .clear
        cell.contentView.subviews.forEach { $0.removeFromSuperview() }

        let item = viewModel.items[indexPath.row]
        let isMatched = item.matchedTrack != nil

        let rankLabel = UILabel()
        rankLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        rankLabel.textColor = isMatched ? .tintColor : .quaternaryLabel
        rankLabel.text = "\(item.rank)"
        rankLabel.textAlignment = .center
        rankLabel.widthAnchor.constraint(equalToConstant: 32).isActive = true

        let titleLabel = UILabel()
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.textColor = isMatched ? .label : .tertiaryLabel
        titleLabel.text = item.trackName
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let artistLabel = UILabel()
        artistLabel.font = .preferredFont(forTextStyle: .caption1)
        artistLabel.textColor = isMatched ? .secondaryLabel : .quaternaryLabel
        artistLabel.text = item.artistName

        let infoStack = UIStackView(arrangedSubviews: [titleLabel, artistLabel])
        infoStack.axis = .vertical
        infoStack.spacing = 2

        let playsLabel = UILabel()
        playsLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        playsLabel.textColor = isMatched ? .secondaryLabel : .quaternaryLabel
        playsLabel.textAlignment = .right

        if item.playCount >= 1000 {
            let thousands = Double(item.playCount) / 1000.0
            playsLabel.text = String(format: "%.1fK", thousands)
        } else {
            playsLabel.text = "\(item.playCount)"
        }

        let stack = UIStackView(arrangedSubviews: [rankLabel, infoStack, playsLabel])
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            playsLabel.widthAnchor.constraint(equalToConstant: 44),
            stack.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
        ])

        cell.selectionStyle = isMatched ? .default : .none

        return cell
    }
}

extension ChartsViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let startIndex = matchedTrackIndex(for: indexPath) else { return }
        impactLight.impactOccurred()
        audioPlayer.play(viewModel.matchedTracks, startingAt: startIndex)
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let track = viewModel.items[indexPath.row].matchedTrack else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.buildTrackContextMenu(for: track)
        }
    }
}
