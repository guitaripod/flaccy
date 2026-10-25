import FlaccyCore
import UIKit

final class LyricsViewController: UIViewController {

    /// How far ahead of the clock a line lights up. The player reports the
    /// position it has rendered, not the one you are hearing, and the emphasis
    /// still has to animate in — without a lead the line always arrives late.
    static let lyricLead: TimeInterval = 0.22
    /// Where the active line sits in the viewport — slightly above center, the
    /// way every good lyrics view frames the line you are about to sing.
    static let activeLineAnchor: CGFloat = 0.42
    /// Angular frequency of the critically damped follow spring, in rad/s.
    static let scrollResponse: CGFloat = 15
    /// Frame deltas are clamped before integrating so a stalled frame can't
    /// blow the spring up.
    static let maxFrameDelta: CFTimeInterval = 1.0 / 30
    /// One step of Earlier or Later, and the most the correction may reach.
    /// How far a tap on a line seeks before the line's own start, so the first
    /// syllable is not clipped.
    static let seekLeadIn: TimeInterval = 0.15
    static let offsetStepMs = 100
    static let offsetLimitMs = 10_000

    var tableView: UITableView!
    var plainTextView: UITextView!
    var statusLabel: UILabel!
    var spinner: UIActivityIndicatorView!
    var document = LyricsDocument()
    var lyrics: Lyrics?
    var currentLineIndex: Int = -1
    var litLines: [Int] = []
    var trackTitle: String
    var artistName: String
    var albumName: String
    var progressObserver: NSObjectProtocol?
    var trackObserver: NSObjectProtocol?
    var loadGeneration = 0
    var isUserScrolling = false
    var scrollResumeWorkItem: DispatchWorkItem?
    let lineSelectionFeedback = UIImpactFeedbackGenerator(style: .light)
    var displayLink: CADisplayLink?
    var lastFrameTime: CFTimeInterval = 0
    var needsLineRefresh = false
    var lastLyricTime: TimeInterval = 0
    var scrollTarget: CGFloat?
    var scrollVelocity: CGFloat = 0
    lazy var retryButton: UIButton = makeRetryButton()
    lazy var offsetItem = UIAction(title: "", attributes: .disabled) { _ in }
    lazy var timingButton: UIButton = makeTimingButton()
    lazy var shareButton: UIButton = makeShareButton()
    lazy var timingNoteChip: UIButton = makeTimingNoteChip()
    lazy var timingControls: UIStackView = makeTimingControls()
    var timingNoteKind: LyricsTimingNoteKind?

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
        guard !document.lines.isEmpty, view.bounds.height > 1 else { return }
        tableView.contentInset = UIEdgeInsets(
            top: view.bounds.height * Self.activeLineAnchor,
            left: 0,
            bottom: view.bounds.height * (1 - Self.activeLineAnchor),
            right: 0
        )
    }

    func startTrackObservation() {
        trackObserver = NotificationCenter.default.addObserver(
            forName: AudioPlayer.trackDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleTrackChange() }
        }
    }

    func handleTrackChange() {
        guard let track = AudioPlayer.shared.currentTrack else { return }
        guard track.title != trackTitle || track.artist != artistName || track.albumTitle != albumName else { return }
        trackTitle = track.title
        artistName = track.artist
        albumName = track.albumTitle
        resetContent()
        loadLyrics()
    }

    func resetContent() {
        stopDisplayLink()
        cancelScroll()
        retryButton.isHidden = true
        timingButton.isHidden = true
        shareButton.isHidden = true
        hideTimingNote()
        document = LyricsDocument()
        lyrics = nil
        currentLineIndex = -1
        litLines = []
        tableView.isHidden = true
        tableView.reloadData()
        plainTextView.isHidden = true
        statusLabel.isHidden = true
    }

    func setupContent() {
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
            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 40),
            statusLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -40),
        ])

        tableView = UITableView(frame: .zero, style: .plain)
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.showsVerticalScrollIndicator = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(LyricCell.self, forCellReuseIdentifier: LyricCell.reuseID)
        tableView.register(InterludeCell.self, forCellReuseIdentifier: InterludeCell.reuseID)
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
        plainTextView.textContainerInset = UIEdgeInsets(top: 64, left: 28, bottom: 48, right: 28)
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

        view.bringSubviewToFront(timingControls)
    }

    func loadLyrics() {
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

            let found: Lyrics
            switch outcome {
            case .found(let result):
                found = result
            case .missing:
                showStatus(LyricsStatusCopy.missing(song: trackTitle), symbol: "quote.bubble")
                return
            case .failed(let failure):
                showStatus(LyricsStatusCopy.failed(failure), symbol: Self.symbol(for: failure))
                retryButton.isHidden = false
                return
            }

            if found.document.instrumental {
                showStatus(LyricsStatusCopy.instrumental, symbol: "music.note")
                return
            }

            if found.document.hasSynced || found.document.plain != nil {
                lyrics = found
                shareButton.isHidden = !isCurrentTrack
            }
            if found.document.hasSynced {
                showSyncedLyrics(found)
                showTimingNote(for: found.document)
            } else if let plain = found.document.plain, !plain.isEmpty {
                showPlainLyrics(plain)
                showTimingNote(for: found.document)
            } else {
                showStatus(LyricsStatusCopy.missing(song: trackTitle), symbol: "quote.bubble")
            }
        }
    }

    /// Sharing reads the song's audio, so it is offered only for the track
    /// that is playing.
    var isCurrentTrack: Bool {
        guard let track = AudioPlayer.shared.currentTrack else { return false }
        return track.title == trackTitle && track.artist == artistName
    }

    func showStatus(_ words: LyricsStatusCopy.Words, symbol: String) {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.paragraphSpacing = 8

        let attachment = NSTextAttachment()
        attachment.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 32, weight: .medium)
        )?.withTintColor(.white.withAlphaComponent(0.5), renderingMode: .alwaysOriginal)

        let attributed = NSMutableAttributedString(attachment: attachment)
        attributed.append(NSAttributedString(
            string: "\n" + words.title,
            attributes: [
                .font: UIFont.scaled(.title3, size: 20, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.8),
            ]
        ))
        attributed.append(NSAttributedString(
            string: "\n" + words.body,
            attributes: [
                .font: UIFont.scaled(.subheadline, size: 15, weight: .regular),
                .foregroundColor: UIColor.white.withAlphaComponent(0.55),
            ]
        ))
        attributed.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: attributed.length))

        statusLabel.attributedText = attributed
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = false
    }

    static func symbol(for failure: LyricsFailure) -> String {
        switch failure {
        case .unreachable: return "wifi.exclamationmark"
        case .timedOut: return "hourglass"
        case .busy: return "tortoise"
        case .server, .rejected: return "exclamationmark.triangle"
        }
    }

    /// A network failure is recoverable, so it gets a way to recover — a miss
    /// is permanent until lrclib grows the song and gets none.
    func makeRetryButton() -> UIButton {
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

    func showSyncedLyrics(_ found: Lyrics) {
        lyrics = found
        document = found.document
        currentLineIndex = -1
        litLines = []
        offsetItem.title = Self.offsetText(found.offsetMs)
        timingButton.isHidden = false
        tableView.isHidden = false
        tableView.reloadData()

        view.setNeedsLayout()
        view.layoutIfNeeded()

        startProgressObservation()
        needsLineRefresh = true
        syncDisplayLink()
        animateContentAppearance(tableView)
    }

    func showPlainLyrics(_ text: String) {
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
    func animateContentAppearance(_ content: UIView) {
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
    func startProgressObservation() {
        guard progressObserver == nil else { return }
        progressObserver = NotificationCenter.default.addObserver(
            forName: AudioPlayer.playbackProgressDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.needsLineRefresh = true
                self?.syncDisplayLink()
            }
        }
    }

    /// Re-evaluates the lit lines and advances the follow spring once per
    /// displayed frame rather than on the player's quarter-second tick — a line
    /// change is only ever a frame late, and the scroll is a glide instead of a
    /// hop per line.
    @objc func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let previous = lastFrameTime
        lastFrameTime = now
        let delta = previous == 0
            ? Self.maxFrameDelta
            : min(max(now - previous, 0), Self.maxFrameDelta)

        let playing = AudioPlayer.shared.isPlaying
        if playing || needsLineRefresh {
            needsLineRefresh = false
            updateLitLines(at: AudioPlayer.shared.currentTime + Self.lyricLead)
        }
        advanceScroll(by: CGFloat(delta))
        if !playing, scrollTarget == nil {
            stopDisplayLink()
        }
    }

    /// The link runs only while there is something to animate, so a paused or
    /// backgrounded lyrics view costs nothing.
    func syncDisplayLink() {
        let wanted = document.hasSynced && view.window != nil
            && (AudioPlayer.shared.isPlaying || scrollTarget != nil || needsLineRefresh)
        if wanted { startDisplayLink() } else { stopDisplayLink() }
    }

    func startDisplayLink() {
        guard displayLink == nil else { return }
        lastFrameTime = 0
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// Lights the lines the clock is on and moves the fill inside them. The
    /// listener's timing correction is applied to the clock, not to the lines.
    func updateLitLines(at position: TimeInterval) {
        guard document.hasSynced, let lyrics else { return }
        let time = lyrics.songTime(at: position)
        lastLyricTime = time
        let primary = document.primaryIndex(at: time) ?? -1
        let lit = document.highlighted(at: time)
        if primary != currentLineIndex || lit != litLines {
            let previous = currentLineIndex
            currentLineIndex = primary
            litLines = lit
            applyEmphasisToVisibleCells(animated: true)
            if primary != previous, primary >= 0, !isUserScrolling {
                aimScroll(atRow: primary)
            }
        }
        for index in lit {
            guard let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0)) else { continue }
            show(document.lines[index], time: time, in: cell)
        }
    }

    func show(_ line: LyricsLine, time: TimeInterval, in cell: UITableViewCell) {
        if let cell = cell as? LyricCell {
            cell.showProgress(line.progress(at: time))
        } else if let cell = cell as? InterludeCell {
            cell.setLitBeats(line.litBeats(at: time))
        }
    }

    /// Aims the follow spring so the line lands on the anchor. Retargeting
    /// mid-flight keeps the current velocity, so consecutive lines read as one
    /// continuous glide rather than a restart each time.
    func aimScroll(atRow row: Int) {
        guard row < document.lines.count, tableView.bounds.height > 1 else { return }
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
    func advanceScroll(by delta: CGFloat) {
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

    func cancelScroll() {
        scrollTarget = nil
        scrollVelocity = 0
    }

    func applyEmphasisToVisibleCells(animated: Bool) {
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            applyEmphasis(to: tableView.cellForRow(at: indexPath), row: indexPath.row, animated: animated)
        }
    }

    func applyEmphasis(to cell: UITableViewCell?, row: Int, animated: Bool) {
        let lit = litLines.contains(row)
        if let cell = cell as? LyricCell {
            cell.setCurrent(lit, animated: animated)
            if !lit { cell.showProgress(nil) }
        } else if let cell = cell as? InterludeCell {
            cell.setCurrent(lit, animated: animated)
            if !lit { cell.setLitBeats(0) }
        }
    }
}
