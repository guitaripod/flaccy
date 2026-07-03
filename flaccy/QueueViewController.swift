import UIKit

final class QueueViewController: UIViewController, SonglinkShareable {

    private enum Section: Int, CaseIterable {
        case history
        case nowPlaying
        case upNext
    }

    private let backdropView = PaletteGradientView()
    private let tableView = UITableView(frame: .zero, style: .grouped)
    private let headerTitleLabel = UILabel()
    private let headerSubtitleLabel = UILabel()
    private let shuffleButton = UIButton(type: .system)
    private let repeatButton = UIButton(type: .system)
    private let clearButton = UIButton(type: .system)
    private var shuffleCapsule: GlassCapsule?
    private var repeatCapsule: GlassCapsule?
    private var clearCapsule: GlassCapsule?
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let reorderFeedback = UISelectionFeedbackGenerator()
    private var lastPaletteKey: String?
    private var hasAnimatedAppearance = false
    private let embeddedInNowPlaying: Bool

    init(embeddedInNowPlaying: Bool = false) {
        self.embeddedInNowPlaying = embeddedInNowPlaying
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        navigationController?.overrideUserInterfaceStyle = .dark
        view.backgroundColor = embeddedInNowPlaying ? .clear : .black

        if !embeddedInNowPlaying {
            setupNavigationBar()
            setupBackdrop()
        }
        setupTableView()
        setupControlsBar()
        setupHeaderTitle()
        reload()
        updatePalette()

        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: AudioPlayer.queueDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(trackDidChange), name: AudioPlayer.trackDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(playbackStateDidChange), name: AudioPlayer.playbackStateDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateShuffleRepeat), name: AudioPlayer.shuffleRepeatDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateHeaderSubtitle), name: AudioPlayer.playbackProgressDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: LovedTracksService.didChange, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        prepareAppearanceAnimationIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        runAppearanceAnimationIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        backdropView.frame = view.bounds
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupNavigationBar() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationController?.navigationBar.tintColor = .white

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                self?.dismiss(animated: true)
            }
        )
    }

    private func setupBackdrop() {
        backdropView.frame = view.bounds
        view.addSubview(backdropView)
    }

    private func setupHeaderTitle() {
        headerTitleLabel.text = "Queue"
        headerTitleLabel.font = .scaled(.headline, size: 17, weight: .semibold)
        headerTitleLabel.adjustsFontForContentSizeCategory = true
        headerTitleLabel.textColor = .white
        headerTitleLabel.textAlignment = .center

        headerSubtitleLabel.font = .scaled(.caption1, size: 12, weight: .medium)
        headerSubtitleLabel.adjustsFontForContentSizeCategory = true
        headerSubtitleLabel.textColor = .white.withAlphaComponent(0.55)
        headerSubtitleLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [headerTitleLabel, headerSubtitleLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 1
        navigationItem.titleView = stack
        updateHeaderSubtitle()
    }

    private func setupTableView() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(QueueTrackCell.self, forCellReuseIdentifier: QueueTrackCell.reuseID)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.showsVerticalScrollIndicator = false
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.allowsSelectionDuringEditing = true
        tableView.setEditing(true, animated: false)
        view.addSubview(tableView)
    }

    private func setupControlsBar() {
        let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)

        shuffleButton.setImage(UIImage(systemName: "shuffle", withConfiguration: config), for: .normal)
        shuffleButton.accessibilityLabel = "Shuffle"
        shuffleButton.addAction(UIAction { _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            AudioPlayer.shared.toggleShuffle()
        }, for: .touchUpInside)

        repeatButton.setImage(UIImage(systemName: "repeat", withConfiguration: config), for: .normal)
        repeatButton.accessibilityLabel = "Repeat"
        repeatButton.addAction(UIAction { _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            AudioPlayer.shared.cycleRepeatMode()
        }, for: .touchUpInside)

        var clearConfig = UIButton.Configuration.plain()
        clearConfig.image = UIImage(systemName: "xmark.circle", withConfiguration: config)
        clearConfig.imagePadding = 6
        clearConfig.attributedTitle = AttributedString(
            "Clear",
            attributes: AttributeContainer([.font: UIFont.scaled(.subheadline, size: 14, weight: .semibold)])
        )
        clearButton.configuration = clearConfig
        clearButton.tintColor = .white.withAlphaComponent(0.85)
        clearButton.accessibilityLabel = "Clear queue"
        clearButton.addAction(UIAction { [weak self] _ in self?.clearTapped() }, for: .touchUpInside)

        let shuffle = GlassCapsule(hosting: shuffleButton)
        let repeats = GlassCapsule(hosting: repeatButton)
        let clear = GlassCapsule(hosting: clearButton)
        shuffleCapsule = shuffle
        repeatCapsule = repeats
        clearCapsule = clear

        updateShuffleRepeat()

        let capsules = embeddedInNowPlaying ? [clear] : [shuffle, repeats, clear]
        let stack = UIStackView(arrangedSubviews: capsules)
        stack.distribution = .fillEqually
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),

            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: stack.topAnchor, constant: -8),
        ])
    }

    private var historyTracks: ArraySlice<Track> {
        let player = AudioPlayer.shared
        guard player.currentTrack != nil, player.currentIndex > 0 else { return [] }
        return player.queue[..<player.currentIndex]
    }

    private var upNextTracks: ArraySlice<Track> {
        let player = AudioPlayer.shared
        guard !player.queue.isEmpty, player.currentIndex + 1 < player.queue.count else { return [] }
        return player.queue[(player.currentIndex + 1)...]
    }

    private func clearTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let alert = UIAlertController(title: "Clear Queue", message: "Stop playback and remove all tracks?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { _ in
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            AudioPlayer.shared.clearQueue()
        })
        present(alert, animated: true)
    }

    @objc private func reload() {
        tableView.reloadData()
        clearCapsule?.isUserInteractionEnabled = !AudioPlayer.shared.queue.isEmpty
        clearButton.tintColor = AudioPlayer.shared.queue.isEmpty
            ? .white.withAlphaComponent(0.35)
            : .white.withAlphaComponent(0.85)
        updateHeaderSubtitle()
        updateEmptyState()
    }

    @objc private func trackDidChange() {
        reload()
        updatePalette()
    }

    @objc private func playbackStateDidChange() {
        guard let cell = nowPlayingCell() else { return }
        cell.setPlaying(AudioPlayer.shared.isPlaying)
    }

    private func nowPlayingCell() -> QueueTrackCell? {
        let indexPath = IndexPath(row: 0, section: Section.nowPlaying.rawValue)
        guard AudioPlayer.shared.currentTrack != nil else { return nil }
        return tableView.cellForRow(at: indexPath) as? QueueTrackCell
    }

    private func updatePalette() {
        guard !embeddedInNowPlaying else { return }
        guard let track = AudioPlayer.shared.currentTrack else {
            backdropView.apply(ArtworkPaletteExtractor.fallbackPalette(seed: "flaccy"), animated: hasAnimatedAppearance)
            return
        }
        let key = "\(track.albumTitle)\0\(track.artist)"
        guard key != lastPaletteKey else { return }
        lastPaletteKey = key
        let artwork = track.artwork ?? AlbumArtworkCache.shared.artwork(forAlbum: track.albumTitle, artist: track.artist)
        let animated = hasAnimatedAppearance
        ArtworkPaletteExtractor.palette(
            for: artwork,
            cacheKey: key,
            fallbackSeed: "\(track.title)\(track.artist)"
        ) { [weak self] palette in
            self?.backdropView.apply(palette, animated: animated)
        }
    }

    @objc private func updateHeaderSubtitle() {
        let player = AudioPlayer.shared
        guard !player.queue.isEmpty else {
            headerSubtitleLabel.text = nil
            headerSubtitleLabel.isHidden = true
            return
        }
        let count = player.queue.count
        let currentRemaining = max(0, player.duration - player.currentTime)
        let remaining = currentRemaining + upNextTracks.reduce(0) { $0 + $1.duration }
        let tracksPart = count == 1 ? "1 track" : "\(count) tracks"
        headerSubtitleLabel.text = "\(tracksPart) · \(Self.formatRemaining(remaining)) left"
        headerSubtitleLabel.isHidden = false
    }

    private static func formatRemaining(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(interval / 60)
        if totalMinutes >= 60 {
            return "\(totalMinutes / 60) hr \(totalMinutes % 60) min"
        }
        return totalMinutes >= 1 ? "\(totalMinutes) min" : "\(Int(interval)) sec"
    }

    private func updateEmptyState() {
        let isEmpty = AudioPlayer.shared.queue.isEmpty && AudioPlayer.shared.currentTrack == nil
        tableView.backgroundView = isEmpty ? makeEmptyBackgroundView() : nil
    }

    private func makeEmptyBackgroundView() -> UIView {
        let container = UIView()

        let iconView = UIImageView(image: UIImage(systemName: "list.bullet"))
        iconView.tintColor = .white.withAlphaComponent(0.3)
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .thin)
        iconView.contentMode = .scaleAspectFit

        let label = UILabel()
        label.text = "Queue is empty"
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white.withAlphaComponent(0.55)
        label.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [iconView, label])
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
    }

    @objc private func updateShuffleRepeat() {
        let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let shuffleActive = AudioPlayer.shared.shuffleEnabled
        shuffleButton.tintColor = shuffleActive ? .white : .white.withAlphaComponent(0.55)
        shuffleButton.accessibilityValue = shuffleActive ? "On" : "Off"
        shuffleCapsule?.setActive(shuffleActive, animated: hasAnimatedAppearance)

        switch AudioPlayer.shared.repeatMode {
        case .off:
            repeatButton.setImage(UIImage(systemName: "repeat", withConfiguration: config), for: .normal)
            repeatButton.tintColor = .white.withAlphaComponent(0.55)
            repeatButton.accessibilityValue = "Off"
            repeatCapsule?.setActive(false, animated: hasAnimatedAppearance)
            repeatCapsule?.setBadge(nil)
        case .all:
            repeatButton.setImage(UIImage(systemName: "repeat", withConfiguration: config), for: .normal)
            repeatButton.tintColor = .white
            repeatButton.accessibilityValue = "All"
            repeatCapsule?.setActive(true, animated: hasAnimatedAppearance)
            repeatCapsule?.setBadge("ALL")
        case .one:
            repeatButton.setImage(UIImage(systemName: "repeat.1", withConfiguration: config), for: .normal)
            repeatButton.tintColor = .white
            repeatButton.accessibilityValue = "One"
            repeatCapsule?.setActive(true, animated: hasAnimatedAppearance)
            repeatCapsule?.setBadge("1")
        }
    }

    private func prepareAppearanceAnimationIfNeeded() {
        guard !hasAnimatedAppearance, !UIAccessibility.isReduceMotionEnabled else { return }
        tableView.alpha = 0
        tableView.transform = CGAffineTransform(translationX: 0, y: 16)
    }

    private func runAppearanceAnimationIfNeeded() {
        guard !hasAnimatedAppearance else { return }
        hasAnimatedAppearance = true
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let animator = UIViewPropertyAnimator(duration: 0.32, dampingRatio: 0.84) { [self] in
            tableView.alpha = 1
            tableView.transform = .identity
        }
        animator.startAnimation()
    }
}

extension QueueViewController: UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else { return 0 }
        switch section {
        case .history: return historyTracks.count
        case .nowPlaying: return AudioPlayer.shared.currentTrack != nil ? 1 : 0
        case .upNext: return upNextTracks.count
        }
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let section = Section(rawValue: section), let title = headerTitle(for: section) else { return nil }
        let label = UILabel()
        label.text = title.uppercased()
        label.font = .scaled(.caption1, size: 12, weight: .semibold)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white.withAlphaComponent(0.5)
        label.translatesAutoresizingMaskIntoConstraints = false
        let container = UIView()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        return container
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        guard let section = Section(rawValue: section), headerTitle(for: section) != nil else { return .leastNonzeroMagnitude }
        return 34
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        .leastNonzeroMagnitude
    }

    private func headerTitle(for section: Section) -> String? {
        switch section {
        case .history: return historyTracks.isEmpty ? nil : "History"
        case .nowPlaying: return AudioPlayer.shared.currentTrack != nil ? "Now Playing" : nil
        case .upNext: return upNextTracks.isEmpty ? nil : "Up Next"
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: QueueTrackCell.reuseID, for: indexPath) as! QueueTrackCell
        let player = AudioPlayer.shared

        guard let section = Section(rawValue: indexPath.section) else { return cell }
        switch section {
        case .history:
            let history = Array(historyTracks)
            if indexPath.row < history.count {
                cell.configure(with: history[indexPath.row], style: .history)
            }
        case .nowPlaying:
            if let track = player.currentTrack {
                cell.configure(with: track, style: .nowPlaying(isPlaying: player.isPlaying))
            }
        case .upNext:
            let upNext = Array(upNextTracks)
            if indexPath.row < upNext.count {
                cell.configure(with: upNext[indexPath.row], style: .upcoming)
            }
        }

        return cell
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        track(at: indexPath) != nil
    }

    func track(at indexPath: IndexPath) -> Track? {
        guard let section = Section(rawValue: indexPath.section) else { return nil }
        switch section {
        case .history:
            let history = Array(historyTracks)
            return indexPath.row < history.count ? history[indexPath.row] : nil
        case .nowPlaying:
            return AudioPlayer.shared.currentTrack
        case .upNext:
            let upNext = Array(upNextTracks)
            return indexPath.row < upNext.count ? upNext[indexPath.row] : nil
        }
    }

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        Section(rawValue: indexPath.section) == .upNext
    }

    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        guard sourceIndexPath.section == Section.upNext.rawValue,
              destinationIndexPath.section == Section.upNext.rawValue else { return }

        reorderFeedback.selectionChanged()
        let player = AudioPlayer.shared
        let sourceQueueIndex = player.currentIndex + 1 + sourceIndexPath.row
        let destQueueIndex = player.currentIndex + 1 + destinationIndexPath.row

        AudioPlayer.shared.moveInQueue(from: sourceQueueIndex, to: destQueueIndex)
    }

    func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath, toProposedIndexPath proposedDestinationIndexPath: IndexPath) -> IndexPath {
        if proposedDestinationIndexPath.section != Section.upNext.rawValue {
            return IndexPath(row: 0, section: Section.upNext.rawValue)
        }
        return proposedDestinationIndexPath
    }
}

extension QueueViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        guard let section = Section(rawValue: indexPath.section) else { return }
        switch section {
        case .history:
            impactLight.impactOccurred()
            AudioPlayer.shared.jumpToIndex(indexPath.row)
        case .nowPlaying:
            break
        case .upNext:
            impactLight.impactOccurred()
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
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
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

    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let track = track(at: indexPath) else { return nil }
        let loved = LovedTracksService.shared.isLoved(track: track)

        let love = UIContextualAction(style: .normal, title: loved ? "Unlove" : "Love") { _, _, completion in
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            Task { await LovedTracksService.shared.toggleLove(track: track) }
            completion(true)
        }
        love.image = UIImage(systemName: loved ? "heart.slash.fill" : "heart.fill")
        love.backgroundColor = LoveButton.lovedTint

        let config = UISwipeActionsConfiguration(actions: [love])
        config.performsFirstActionWithFullSwipe = true
        return config
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard Section(rawValue: indexPath.section) == .upNext else { return nil }

        let remove = UIContextualAction(style: .destructive, title: "Remove") { _, _, completion in
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            let queueIndex = AudioPlayer.shared.currentIndex + 1 + indexPath.row
            AudioPlayer.shared.removeFromQueue(at: queueIndex)
            completion(true)
        }
        remove.image = UIImage(systemName: "trash.fill")

        return UISwipeActionsConfiguration(actions: [remove])
    }

    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        .none
    }

    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        false
    }
}

/// Three vertical bars that bounce while playback is active — the queue's
/// now-playing indicator. Freezes at a low, static level while paused and
/// under Reduce Motion.
final class PlayingBarsView: UIView {

    private let barLayers: [CALayer] = (0..<3).map { _ in CALayer() }
    private var isAnimating = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        for bar in barLayers {
            bar.backgroundColor = UIColor.white.cgColor
            bar.cornerRadius = 1.25
            layer.addSublayer(bar)
        }
        isAccessibilityElement = false
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: 16, height: 14)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let barWidth: CGFloat = 2.5
        let gap = (bounds.width - barWidth * 3) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in barLayers.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: bounds.height)
            bar.position = CGPoint(x: barWidth / 2 + CGFloat(index) * (barWidth + gap), y: bounds.height / 2)
            bar.anchorPoint = CGPoint(x: 0.5, y: 1)
            bar.position.y = bounds.height
        }
        CATransaction.commit()
        if isAnimating {
            restartAnimation()
        } else {
            applyIdleScale()
        }
    }

    func setPlaying(_ playing: Bool) {
        let shouldAnimate = playing && !UIAccessibility.isReduceMotionEnabled
        guard shouldAnimate != isAnimating else { return }
        isAnimating = shouldAnimate
        if shouldAnimate {
            restartAnimation()
        } else {
            stopAnimation()
        }
    }

    @objc private func applicationDidBecomeActive() {
        if isAnimating { restartAnimation() }
    }

    private func restartAnimation() {
        let durations: [CFTimeInterval] = [0.55, 0.42, 0.62]
        let peaks: [CGFloat] = [0.95, 0.7, 0.85]
        for (index, bar) in barLayers.enumerated() {
            bar.removeAnimation(forKey: "bounce")
            let bounce = CABasicAnimation(keyPath: "transform.scale.y")
            bounce.fromValue = 0.25
            bounce.toValue = peaks[index]
            bounce.duration = durations[index]
            bounce.autoreverses = true
            bounce.repeatCount = .infinity
            bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.add(bounce, forKey: "bounce")
        }
    }

    private func stopAnimation() {
        for bar in barLayers {
            bar.removeAnimation(forKey: "bounce")
        }
        applyIdleScale()
    }

    private func applyIdleScale() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in barLayers {
            bar.transform = CATransform3DMakeScale(1, 0.3, 1)
        }
        CATransaction.commit()
    }
}

final class QueueTrackCell: UITableViewCell {

    enum Style {
        case history
        case nowPlaying(isPlaying: Bool)
        case upcoming
    }

    static let reuseID = "QueueTrackCell"

    private let highlightView = UIView()
    private let artworkView = UIImageView()
    private let trackTitleLabel = UILabel()
    private let trackArtistLabel = UILabel()
    private let durationLabel = UILabel()
    private let playingBars = PlayingBarsView()
    private let qualityBadge = QualityBadgeView(size: .compact)
    private let lovedIndicator = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none

        highlightView.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        highlightView.layer.cornerRadius = 14
        highlightView.layer.cornerCurve = .continuous
        highlightView.isHidden = true
        highlightView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(highlightView)

        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.layer.cornerRadius = 8
        artworkView.layer.cornerCurve = .continuous
        artworkView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        artworkView.tintColor = UIColor.white.withAlphaComponent(0.35)

        playingBars.isHidden = true
        playingBars.setContentHuggingPriority(.required, for: .horizontal)

        trackTitleLabel.font = .preferredFont(forTextStyle: .body)
        trackTitleLabel.adjustsFontForContentSizeCategory = true
        trackTitleLabel.textColor = .white
        trackTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        trackArtistLabel.font = .preferredFont(forTextStyle: .caption1)
        trackArtistLabel.adjustsFontForContentSizeCategory = true
        trackArtistLabel.textColor = .white.withAlphaComponent(0.55)
        trackArtistLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        durationLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        durationLabel.textColor = .white.withAlphaComponent(0.4)
        durationLabel.setContentHuggingPriority(.required, for: .horizontal)

        lovedIndicator.image = UIImage(
            systemName: "heart.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        )
        lovedIndicator.tintColor = LoveButton.lovedTint
        lovedIndicator.contentMode = .center
        lovedIndicator.isHidden = true
        lovedIndicator.isAccessibilityElement = false
        lovedIndicator.setContentHuggingPriority(.required, for: .horizontal)

        let textStack = UIStackView(arrangedSubviews: [trackTitleLabel, trackArtistLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        let mainStack = UIStackView(arrangedSubviews: [
            artworkView, playingBars, textStack, qualityBadge, lovedIndicator, durationLabel,
        ])
        mainStack.spacing = 10
        mainStack.alignment = .center
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(mainStack)

        NSLayoutConstraint.activate([
            artworkView.widthAnchor.constraint(equalToConstant: 44),
            artworkView.heightAnchor.constraint(equalToConstant: 44),
            playingBars.widthAnchor.constraint(equalToConstant: 16),
            playingBars.heightAnchor.constraint(equalToConstant: 14),

            highlightView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            highlightView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            highlightView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            highlightView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),

            mainStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            mainStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            mainStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            mainStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var currentArtworkKey: String?

    func configure(with track: Track, style: Style) {
        trackTitleLabel.text = track.title
        trackArtistLabel.text = track.artist
        loadArtwork(for: track)

        qualityBadge.configure(with: track)
        let loved = LovedTracksService.shared.isLoved(track: track)
        lovedIndicator.isHidden = !loved

        let total = Int(track.duration)
        durationLabel.text = String(format: "%d:%02d", total / 60, total % 60)

        var stateValue: String?
        switch style {
        case .history:
            highlightView.isHidden = true
            playingBars.isHidden = true
            playingBars.setPlaying(false)
            contentView.alpha = 0.45
            stateValue = "Played earlier"
            accessibilityHint = "Plays this track again"
        case .nowPlaying(let isPlaying):
            highlightView.isHidden = false
            playingBars.isHidden = false
            playingBars.setPlaying(isPlaying)
            contentView.alpha = 1
            stateValue = isPlaying ? "Now playing" : "Paused"
            accessibilityHint = nil
        case .upcoming:
            highlightView.isHidden = true
            playingBars.isHidden = true
            playingBars.setPlaying(false)
            contentView.alpha = 1
            stateValue = nil
            accessibilityHint = "Plays this track"
        }
        accessibilityLabel = "\(track.title), \(track.artist)"
        accessibilityValue = [stateValue, loved ? "Loved" : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
        isAccessibilityElement = true
    }

    func setPlaying(_ playing: Bool) {
        playingBars.setPlaying(playing)
        accessibilityValue = playing ? "Now playing" : "Paused"
    }

    private func loadArtwork(for track: Track) {
        let requestedKey = track.albumTitle + "\u{0}" + track.artist
        currentArtworkKey = requestedKey

        let cached = track.artwork
            ?? AlbumArtworkCache.shared.artwork(forAlbum: track.albumTitle, artist: track.artist)

        if let artwork = cached {
            artworkView.contentMode = .scaleAspectFill
            artworkView.image = artwork
        } else {
            artworkView.contentMode = .center
            artworkView.image = UIImage(systemName: "music.note")
            AlbumArtworkCache.shared.loadArtwork(forAlbum: track.albumTitle, artist: track.artist) { [weak self] image in
                guard let self, let image, self.currentArtworkKey == requestedKey else { return }
                self.artworkView.contentMode = .scaleAspectFill
                self.artworkView.image = image
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentArtworkKey = nil
        artworkView.image = nil
        lovedIndicator.isHidden = true
        qualityBadge.configure(with: nil)
        highlightView.isHidden = true
        playingBars.isHidden = true
        playingBars.setPlaying(false)
        contentView.alpha = 1
    }
}
