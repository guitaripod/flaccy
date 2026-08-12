import UIKit

final class LyricsViewController: UIViewController {

    /// How far ahead of the clock a line lights up. The player reports the
    /// position it has rendered, not the one you are hearing, and the emphasis
    /// still has to animate in — without a lead the line always arrives late.
    private static let lyricLead: TimeInterval = 0.22
    /// Where the active line sits in the viewport — slightly above center, the
    /// way every good lyrics view frames the line you are about to sing.
    private static let activeLineAnchor: CGFloat = 0.42
    /// Angular frequency of the critically damped follow spring, in rad/s.
    private static let scrollResponse: CGFloat = 15
    /// Frame deltas are clamped before integrating so a stalled frame can't
    /// blow the spring up.
    private static let maxFrameDelta: CFTimeInterval = 1.0 / 30

    private var tableView: UITableView!
    private var plainTextView: UITextView!
    private var statusLabel: UILabel!
    private var spinner: UIActivityIndicatorView!
    private var lyrics: [LyricLine] = []
    private var currentLineIndex: Int = -1
    private var trackTitle: String
    private var artistName: String
    private var albumName: String
    private var progressObserver: NSObjectProtocol?
    private var trackObserver: NSObjectProtocol?
    private var loadGeneration = 0
    private var isUserScrolling = false
    private var scrollResumeWorkItem: DispatchWorkItem?
    private let lineSelectionFeedback = UIImpactFeedbackGenerator(style: .light)
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = 0
    private var needsLineRefresh = false
    private var scrollTarget: CGFloat?
    private var scrollVelocity: CGFloat = 0
    private lazy var retryButton: UIButton = makeRetryButton()

    init(track: String, artist: String, album: String) {
        self.trackTitle = track
        self.artistName = artist
        self.albumName = album
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .clear
        setupContent()
        startTrackObservation()
        loadLyrics()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let observer = progressObserver {
            NotificationCenter.default.removeObserver(observer)
            progressObserver = nil
        }
        if let observer = trackObserver {
            NotificationCenter.default.removeObserver(observer)
            trackObserver = nil
        }
        stopDisplayLink()
    }

    /// End padding scales with the viewport so the first and last lines can
    /// reach the anchor instead of being pinned to an edge.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !lyrics.isEmpty, view.bounds.height > 1 else { return }
        tableView.contentInset = UIEdgeInsets(
            top: view.bounds.height * Self.activeLineAnchor,
            left: 0,
            bottom: view.bounds.height * (1 - Self.activeLineAnchor),
            right: 0
        )
    }

    private func startTrackObservation() {
        trackObserver = NotificationCenter.default.addObserver(
            forName: AudioPlayer.trackDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleTrackChange()
        }
    }

    private func handleTrackChange() {
        guard let track = AudioPlayer.shared.currentTrack else { return }
        guard track.title != trackTitle || track.artist != artistName || track.albumTitle != albumName else { return }
        trackTitle = track.title
        artistName = track.artist
        albumName = track.albumTitle
        resetContent()
        loadLyrics()
    }

    private func resetContent() {
        stopDisplayLink()
        cancelScroll()
        retryButton.isHidden = true
        lyrics = []
        currentLineIndex = -1
        tableView.isHidden = true
        tableView.reloadData()
        plainTextView.isHidden = true
        statusLabel.isHidden = true
    }

    private func setupContent() {
        spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        statusLabel = UILabel()
        statusLabel.font = .scaled(.title3, size: 20, weight: .medium)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .white.withAlphaComponent(0.5)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
        ])

        tableView = UITableView(frame: .zero, style: .plain)
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.showsVerticalScrollIndicator = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(LyricCell.self, forCellReuseIdentifier: LyricCell.reuseID)
        tableView.isHidden = true
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])

        plainTextView = UITextView()
        plainTextView.backgroundColor = .clear
        plainTextView.isEditable = false
        plainTextView.textContainerInset = UIEdgeInsets(top: 28, left: 28, bottom: 48, right: 28)
        plainTextView.isHidden = true
        plainTextView.showsVerticalScrollIndicator = false
        plainTextView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(plainTextView)

        NSLayoutConstraint.activate([
            plainTextView.topAnchor.constraint(equalTo: view.topAnchor),
            plainTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            plainTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            plainTextView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    private func loadLyrics() {
        loadGeneration += 1
        let generation = loadGeneration
        spinner.startAnimating()

        let current = AudioPlayer.shared.currentTrack
        let matchesCurrent = current?.title == trackTitle && current?.artist == artistName
        Task {
            let outcome = await LyricsService.shared.fetchLyrics(
                track: trackTitle,
                artist: artistName,
                album: albumName,
                fileURL: matchesCurrent ? current?.fileURL : nil,
                duration: matchesCurrent ? (current?.duration ?? 0) : 0
            )
            guard generation == loadGeneration else { return }
            spinner.stopAnimating()

            let result: LyricsResult
            switch outcome {
            case .found(let found):
                result = found
            case .missing:
                showStatus(String(localized: "No lyrics available"))
                return
            case .failed:
                showStatus(String(localized: "Couldn't reach lrclib.net"))
                retryButton.isHidden = false
                return
            }

            if result.isInstrumental {
                showInstrumental()
                return
            }

            if let syncedLines = result.syncedLines, !syncedLines.isEmpty {
                showSyncedLyrics(syncedLines)
            } else if let plain = result.plainText, !plain.isEmpty {
                showPlainLyrics(plain)
            } else {
                showStatus(String(localized: "No lyrics available"))
            }
        }
    }

    private func showStatus(_ text: String) {
        statusLabel.text = text
        statusLabel.isHidden = false
    }

    /// A network failure is recoverable, so it gets a way to recover — a miss
    /// is permanent until lrclib grows the song and gets none.
    private func makeRetryButton() -> UIButton {
        var config = UIButton.Configuration.borderedProminent()
        config.title = String(localized: "Try Again")
        config.cornerStyle = .capsule
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            self?.retryButton.isHidden = true
            self?.statusLabel.isHidden = true
            self?.loadLyrics()
        })
        button.isHidden = true
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
        ])
        return button
    }

    private func showInstrumental() {
        let attachment = NSTextAttachment()
        attachment.image = UIImage(
            systemName: "music.note",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 32, weight: .medium)
        )?.withTintColor(.white.withAlphaComponent(0.5), renderingMode: .alwaysOriginal)

        let attributed = NSMutableAttributedString(attachment: attachment)
        attributed.append(NSAttributedString(
            string: String(localized: "\nInstrumental"),
            attributes: [
                .font: UIFont.scaled(.title3, size: 20, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.5),
            ]
        ))

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: attributed.length))

        statusLabel.attributedText = attributed
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = false
    }

    private func showSyncedLyrics(_ lines: [LyricLine]) {
        lyrics = lines
        tableView.isHidden = false
        tableView.reloadData()

        view.setNeedsLayout()
        view.layoutIfNeeded()

        startProgressObservation()
        needsLineRefresh = true
        syncDisplayLink()
        animateContentAppearance(tableView)
    }

    private func showPlainLyrics(_ text: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 9
        paragraph.paragraphSpacing = 14
        plainTextView.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.scaled(.title3, size: 21, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.85),
                .paragraphStyle: paragraph,
            ]
        )
        plainTextView.isHidden = false
        animateContentAppearance(plainTextView)
    }

    /// Springs freshly-loaded lyric content in with a short fade-and-rise,
    /// skipped under Reduce Motion.
    private func animateContentAppearance(_ content: UIView) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        content.alpha = 0
        content.transform = CGAffineTransform(translationX: 0, y: 14)
        let animator = UIViewPropertyAnimator(duration: 0.32, dampingRatio: 0.84) {
            content.alpha = 1
            content.transform = .identity
        }
        animator.startAnimation()
    }

    /// A seek moves the clock without a frame of playback behind it, so the
    /// line has to be re-found even while paused.
    private func startProgressObservation() {
        guard progressObserver == nil else { return }
        progressObserver = NotificationCenter.default.addObserver(
            forName: AudioPlayer.playbackProgressDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.needsLineRefresh = true
            self?.syncDisplayLink()
        }
    }

    /// Re-evaluates the active line and advances the follow spring once per
    /// displayed frame rather than on the player's quarter-second tick — a line
    /// change is only ever a frame late, and the scroll is a glide instead of a
    /// hop per line.
    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let previous = lastFrameTime
        lastFrameTime = now
        let delta = previous == 0
            ? Self.maxFrameDelta
            : min(max(now - previous, 0), Self.maxFrameDelta)

        let playing = AudioPlayer.shared.isPlaying
        if playing || needsLineRefresh {
            needsLineRefresh = false
            updateCurrentLine(at: AudioPlayer.shared.currentTime + Self.lyricLead)
        }
        advanceScroll(by: CGFloat(delta))
        if !playing, scrollTarget == nil {
            stopDisplayLink()
        }
    }

    /// The link runs only while there is something to animate, so a paused or
    /// backgrounded lyrics view costs nothing.
    private func syncDisplayLink() {
        let wanted = !lyrics.isEmpty && view.window != nil
            && (AudioPlayer.shared.isPlaying || scrollTarget != nil || needsLineRefresh)
        if wanted { startDisplayLink() } else { stopDisplayLink() }
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        lastFrameTime = 0
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func updateCurrentLine(at time: TimeInterval) {
        guard !lyrics.isEmpty else { return }
        var newIndex = -1
        for (index, line) in lyrics.enumerated() {
            if line.time <= time {
                newIndex = index
            } else {
                break
            }
        }
        setCurrentLine(newIndex, scrolls: !isUserScrolling)
    }

    private func setCurrentLine(_ newIndex: Int, scrolls: Bool) {
        guard newIndex != currentLineIndex else { return }
        currentLineIndex = newIndex
        applyEmphasisToVisibleCells(animated: true)

        guard newIndex >= 0, scrolls else { return }
        aimScroll(atRow: newIndex)
    }

    /// Aims the follow spring so the line lands on the anchor. Retargeting
    /// mid-flight keeps the current velocity, so consecutive lines read as one
    /// continuous glide rather than a restart each time.
    private func aimScroll(atRow row: Int) {
        guard row < lyrics.count, tableView.bounds.height > 1 else { return }
        let rect = tableView.rectForRow(at: IndexPath(row: row, section: 0))
        let anchor = tableView.bounds.height * Self.activeLineAnchor
        let lowest = -tableView.adjustedContentInset.top
        let highest = max(
            lowest,
            tableView.contentSize.height + tableView.adjustedContentInset.bottom - tableView.bounds.height
        )
        scrollTarget = min(max(rect.midY - anchor, lowest), highest)
        syncDisplayLink()
    }

    /// One frame of a critically damped spring toward the aimed-at offset.
    private func advanceScroll(by delta: CGFloat) {
        guard let target = scrollTarget else { return }
        let value = tableView.contentOffset.y
        let distance = target - value
        if abs(distance) < 0.5, abs(scrollVelocity) < 4 {
            tableView.contentOffset.y = target
            cancelScroll()
            return
        }
        let response = Self.scrollResponse
        scrollVelocity += (response * response * distance - 2 * response * scrollVelocity) * delta
        tableView.contentOffset.y = value + scrollVelocity * delta
    }

    private func cancelScroll() {
        scrollTarget = nil
        scrollVelocity = 0
    }

    private func applyEmphasisToVisibleCells(animated: Bool) {
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard let cell = tableView.cellForRow(at: indexPath) as? LyricCell else { continue }
            cell.setCurrent(indexPath.row == currentLineIndex, animated: animated)
        }
    }
}

extension LyricsViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        lyrics.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: LyricCell.reuseID, for: indexPath) as! LyricCell
        cell.configure(text: lyrics[indexPath.row].text, isCurrent: indexPath.row == currentLineIndex)
        return cell
    }
}

extension LyricsViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let line = lyrics[indexPath.row]
        lineSelectionFeedback.impactOccurred()
        // Nudge back a beat so the first syllable isn't clipped.
        AudioPlayer.shared.seek(to: max(0, line.time - 0.15))
        scrollResumeWorkItem?.cancel()
        isUserScrolling = false
        setCurrentLine(indexPath.row, scrolls: true)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        scrollResumeWorkItem?.cancel()
        isUserScrolling = true
        cancelScroll()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            scheduleScrollResume()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scheduleScrollResume()
    }

    private func scheduleScrollResume() {
        scrollResumeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.isUserScrolling = false
        }
        scrollResumeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }
}

private final class LyricCell: UITableViewCell {

    static let reuseID = "LyricCell"

    private let lyricLabel = UILabel()
    private var isCurrentLine = false
    private static let dimmedScale: CGFloat = 0.86
    private static let dimmedAlpha: CGFloat = 0.35

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none

        lyricLabel.numberOfLines = 0
        lyricLabel.font = .scaled(.title2, size: 24, weight: .bold)
        lyricLabel.adjustsFontForContentSizeCategory = true
        lyricLabel.textColor = .white
        lyricLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(lyricLabel)

        NSLayoutConstraint.activate([
            lyricLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            lyricLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            lyricLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            lyricLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func configure(text: String, isCurrent: Bool) {
        lyricLabel.text = text
        isAccessibilityElement = true
        accessibilityLabel = text
        accessibilityValue = isCurrent ? String(localized: "Current line") : nil
        accessibilityHint = String(localized: "Plays from this line")
        accessibilityTraits = .button
        setCurrent(isCurrent, animated: false)
    }

    func setCurrent(_ isCurrent: Bool, animated: Bool) {
        guard isCurrent != isCurrentLine || !animated else { return }
        isCurrentLine = isCurrent
        accessibilityValue = isCurrent ? String(localized: "Current line") : nil
        let apply = { [self] in
            lyricLabel.alpha = isCurrent ? 1 : Self.dimmedAlpha
            lyricLabel.transform = isCurrent ? .identity : Self.dimmedTransform(width: lyricLabel.bounds.width)
        }
        if animated, !UIAccessibility.isReduceMotionEnabled {
            let animator = UIViewPropertyAnimator(duration: 0.28, dampingRatio: 0.86, animations: apply)
            animator.startAnimation()
        } else {
            apply()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !isCurrentLine, lyricLabel.transform != .identity {
            lyricLabel.transform = Self.dimmedTransform(width: lyricLabel.bounds.width)
        }
    }

    /// Scales the label down around its leading edge so dimmed lines shrink
    /// toward the margin the way Apple Music's lyrics do.
    private static func dimmedTransform(width: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: -width * (1 - dimmedScale) / 2, y: 0)
            .scaledBy(x: dimmedScale, y: dimmedScale)
    }
}
