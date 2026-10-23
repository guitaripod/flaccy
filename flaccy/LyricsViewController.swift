import FlaccyCore
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
    /// One step of Earlier or Later, and the most the correction may reach.
    /// How far a tap on a line seeks before the line's own start, so the first
    /// syllable is not clipped.
    private static let seekLeadIn: TimeInterval = 0.15
    private static let offsetStepMs = 100
    private static let offsetLimitMs = 10_000

    private var tableView: UITableView!
    private var plainTextView: UITextView!
    private var statusLabel: UILabel!
    private var spinner: UIActivityIndicatorView!
    private var document = LyricsDocument()
    private var lyrics: Lyrics?
    private var currentLineIndex: Int = -1
    private var litLines: [Int] = []
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
    private var lastLyricTime: TimeInterval = 0
    private var scrollTarget: CGFloat?
    private var scrollVelocity: CGFloat = 0
    private lazy var retryButton: UIButton = makeRetryButton()
    private lazy var offsetItem = UIAction(title: "", attributes: .disabled) { _ in }
    private lazy var timingButton: UIButton = makeTimingButton()
    private lazy var timingNoteChip: UIButton = makeTimingNoteChip()
    private lazy var timingControls: UIStackView = makeTimingControls()
    private var timingNoteKind: LyricsTimingNoteKind?

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

    private func startTrackObservation() {
        trackObserver = NotificationCenter.default.addObserver(
            forName: AudioPlayer.trackDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleTrackChange() }
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
        timingButton.isHidden = true
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

    private func showStatus(_ words: LyricsStatusCopy.Words, symbol: String) {
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

    private static func symbol(for failure: LyricsFailure) -> String {
        switch failure {
        case .unreachable: return "wifi.exclamationmark"
        case .timedOut: return "hourglass"
        case .busy: return "tortoise"
        case .server, .rejected: return "exclamationmark.triangle"
        }
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

    /// A small button over the lines whose menu shifts the lyrics earlier or
    /// later when they run ahead of or behind the singing. The menu stays open
    /// between presses so a correction can be dialled in by ear.
    private func makeTimingButton() -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "clock")
        config.baseForegroundColor = .white.withAlphaComponent(0.7)
        config.background.backgroundColor = .white.withAlphaComponent(0.12)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 9, bottom: 9, trailing: 9)
        let earlier = UIAction(
            title: String(localized: "Show Lyrics Earlier"),
            image: UIImage(systemName: "minus.circle"),
            attributes: .keepsMenuPresented
        ) { [weak self] _ in
            self?.nudgeOffset(by: -Self.offsetStepMs)
        }
        let later = UIAction(
            title: String(localized: "Show Lyrics Later"),
            image: UIImage(systemName: "plus.circle"),
            attributes: .keepsMenuPresented
        ) { [weak self] _ in
            self?.nudgeOffset(by: Self.offsetStepMs)
        }
        let reset = UIAction(
            title: String(localized: "Reset Timing"),
            image: UIImage(systemName: "arrow.counterclockwise")
        ) { [weak self] _ in
            self?.setOffset(0)
        }
        let button = UIButton(configuration: config)
        button.menu = UIMenu(title: String(localized: "Lyrics Timing"), children: [offsetItem, earlier, later, reset])
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = String(localized: "Lyrics timing")
        button.isHidden = true
        return button
    }

    /// The row in the top corner holding the timing note chip and, right of it,
    /// the timing button. Hidden members collapse, so the button keeps its
    /// corner while the chip comes and goes.
    private func makeTimingControls() -> UIStackView {
        let stack = UIStackView(arrangedSubviews: [timingNoteChip, timingButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
        ])
        return stack
    }

    /// A quiet pill beside the clock that names why the words are not filled
    /// in, and opens the longer reason.
    private func makeTimingNoteChip() -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "info.circle")
        config.imagePlacement = .leading
        config.imagePadding = 5
        config.baseForegroundColor = .white.withAlphaComponent(0.7)
        config.background.backgroundColor = .white.withAlphaComponent(0.12)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.scaled(.footnote, size: 13, weight: .semibold)
            return attributes
        }
        let button = TimingNoteChipButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            self?.presentTimingNote()
        })
        button.accessibilityHint = LyricsTimingNoteCopy.accessibilityHint
        button.isHidden = true
        return button
    }

    /// Computes the note once for the document just applied and shows or hides
    /// the chip to match.
    private func showTimingNote(for document: LyricsDocument) {
        guard let kind = LyricsTimingNote.kind(for: document) else {
            hideTimingNote()
            return
        }
        timingNoteKind = kind
        timingNoteChip.configuration?.title = LyricsTimingNoteCopy.label(for: kind)
        timingNoteChip.isHidden = false
    }

    private func hideTimingNote() {
        timingNoteKind = nil
        timingNoteChip.isHidden = true
        if presentedViewController is TimingNoteViewController {
            dismiss(animated: false)
        }
    }

    private func presentTimingNote() {
        guard let kind = timingNoteKind, presentedViewController == nil else { return }
        lineSelectionFeedback.impactOccurred()
        let note = TimingNoteViewController(kind: kind)
        note.modalPresentationStyle = .popover
        if let popover = note.popoverPresentationController {
            popover.sourceView = timingNoteChip
            popover.sourceRect = timingNoteChip.bounds
            popover.permittedArrowDirections = .up
            popover.delegate = note
        }
        present(note, animated: true)
    }

    private func nudgeOffset(by delta: Int) {
        setOffset((lyrics?.offsetMs ?? 0) + delta)
    }

    private func setOffset(_ offsetMs: Int) {
        guard var lyrics else { return }
        let clamped = min(max(offsetMs, -Self.offsetLimitMs), Self.offsetLimitMs)
        lyrics.offsetMs = clamped
        self.lyrics = lyrics
        offsetItem.title = Self.offsetText(clamped)
        LyricsService.shared.saveOffset(track: trackTitle, artist: artistName, offsetMs: clamped)
        lineSelectionFeedback.impactOccurred()
        needsLineRefresh = true
        syncDisplayLink()
    }

    /// "In sync", or the correction as a signed number of seconds.
    private static func offsetText(_ offsetMs: Int) -> String {
        guard offsetMs != 0 else { return String(localized: "In sync") }
        let seconds = Double(abs(offsetMs)) / 1000
        let sign = offsetMs > 0 ? "+" : "\u{2212}"
        return "\(sign)\(String(format: "%.1f", seconds)) s"
    }

    private func showSyncedLyrics(_ found: Lyrics) {
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
            updateLitLines(at: AudioPlayer.shared.currentTime + Self.lyricLead)
        }
        advanceScroll(by: CGFloat(delta))
        if !playing, scrollTarget == nil {
            stopDisplayLink()
        }
    }

    /// The link runs only while there is something to animate, so a paused or
    /// backgrounded lyrics view costs nothing.
    private func syncDisplayLink() {
        let wanted = document.hasSynced && view.window != nil
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

    /// Lights the lines the clock is on and moves the fill inside them. The
    /// listener's timing correction is applied to the clock, not to the lines.
    private func updateLitLines(at position: TimeInterval) {
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

    private func show(_ line: LyricsLine, time: TimeInterval, in cell: UITableViewCell) {
        if let cell = cell as? LyricCell {
            cell.showProgress(line.progress(at: time))
        } else if let cell = cell as? InterludeCell {
            cell.setLitBeats(line.litBeats(at: time))
        }
    }

    /// Aims the follow spring so the line lands on the anchor. Retargeting
    /// mid-flight keeps the current velocity, so consecutive lines read as one
    /// continuous glide rather than a restart each time.
    private func aimScroll(atRow row: Int) {
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
            applyEmphasis(to: tableView.cellForRow(at: indexPath), row: indexPath.row, animated: animated)
        }
    }

    private func applyEmphasis(to cell: UITableViewCell?, row: Int, animated: Bool) {
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

extension LyricsViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        document.lines.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let line = document.lines[indexPath.row]
        let lit = litLines.contains(indexPath.row)
        if line.isInterlude {
            let cell = tableView.dequeueReusableCell(withIdentifier: InterludeCell.reuseID, for: indexPath) as! InterludeCell
            cell.configure(isCurrent: lit)
            if lit { cell.setLitBeats(line.litBeats(at: lastLyricTime)) }
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: LyricCell.reuseID, for: indexPath) as! LyricCell
        cell.configure(line: line, isCurrent: lit)
        if lit { cell.showProgress(line.progress(at: lastLyricTime)) }
        return cell
    }
}

extension LyricsViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let line = document.lines[indexPath.row]
        lineSelectionFeedback.impactOccurred()
        let target = line.start + (lyrics?.offsetSeconds ?? 0)
        AudioPlayer.shared.seek(to: max(0, target - Self.seekLeadIn))
        scrollResumeWorkItem?.cancel()
        isUserScrolling = false
        needsLineRefresh = true
        aimScroll(atRow: indexPath.row)
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

/// Draws the line being sung with the sung part in one colour and the rest in
/// another, the edge following the words. It sits over the cell's label while a
/// line with timed words is current, and is hidden otherwise.
private final class LyricWipeView: UIView {

    private var layout: LyricWipeLayout?
    private var edge: LyricWipeEdge = .nothing
    private var text = ""
    private var words: [LyricsWord] = []
    private var font = UIFont.systemFont(ofSize: 24, weight: .bold)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func configure(text: String, words: [LyricsWord], font: UIFont) {
        self.text = text
        self.words = words
        self.font = font
        layout = nil
        edge = .nothing
    }

    /// Moves the edge to a clock position, or hides the view for `nil`.
    func show(_ progress: LyricsLineProgress?) {
        guard let progress, !words.isEmpty else {
            isHidden = true
            return
        }
        guard let layout = currentLayout() else { return }
        let next = layout.edge(for: progress)
        if isHidden || next != edge {
            edge = next
            isHidden = false
            setNeedsDisplay()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let layout, abs(layout.width - bounds.width) > 0.5 {
            self.layout = nil
            setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let layout = currentLayout() else { return }
        layout.draw(edge: edge, in: context)
    }

    private func currentLayout() -> LyricWipeLayout? {
        if let layout { return layout }
        guard bounds.width > 1 else { return nil }
        let built = LyricWipeLayout(
            text: text, words: words, font: font, width: bounds.width,
            bright: .white, dim: .white.withAlphaComponent(0.4)
        )
        layout = built
        return built
    }
}

private final class LyricCell: UITableViewCell {

    static let reuseID = "LyricCell"

    private let lyricLabel = UILabel()
    private let wipeView = LyricWipeView()
    private var isCurrentLine = false
    private var isBacking = false
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

        wipeView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(wipeView)

        NSLayoutConstraint.activate([
            lyricLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            lyricLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            lyricLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            lyricLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            wipeView.topAnchor.constraint(equalTo: lyricLabel.topAnchor),
            wipeView.bottomAnchor.constraint(equalTo: lyricLabel.bottomAnchor),
            wipeView.leadingAnchor.constraint(equalTo: lyricLabel.leadingAnchor),
            wipeView.trailingAnchor.constraint(equalTo: lyricLabel.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func configure(line: LyricsLine, isCurrent: Bool) {
        isBacking = line.background
        lyricLabel.font = isBacking
            ? .scaled(.title3, size: 20, weight: .semibold)
            : .scaled(.title2, size: 24, weight: .bold)
        lyricLabel.text = line.text
        wipeView.configure(text: line.text, words: line.words, font: lyricLabel.font)
        showProgress(nil)
        isAccessibilityElement = true
        accessibilityLabel = line.text
        accessibilityValue = isCurrent ? String(localized: "Current line") : nil
        accessibilityHint = String(localized: "Plays from this line")
        accessibilityTraits = .button
        setCurrent(isCurrent, animated: false)
    }

    /// Shows the fill at a clock position, swapping the plain label for the
    /// drawn one, or goes back to the plain label for `nil`.
    func showProgress(_ progress: LyricsLineProgress?) {
        wipeView.show(progress)
        lyricLabel.isHidden = !wipeView.isHidden
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

/// An instrumental stretch: three beats that light one after another across
/// the gap, so a pause in the singing reads as part of the song.
private final class InterludeCell: UITableViewCell {

    static let reuseID = "InterludeCell"

    private let beats: [UIView] = (0..<LyricsDocument.interludeBeats).map { _ in
        let beat = UIView()
        beat.layer.cornerRadius = 5
        beat.backgroundColor = .white
        beat.alpha = InterludeCell.unlitAlpha
        return beat
    }
    private var isCurrentLine = false
    private static let unlitAlpha: CGFloat = 0.25
    private static let dimmedAlpha: CGFloat = 0.35

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        isAccessibilityElement = false

        let stack = UIStackView(arrangedSubviews: beats)
        stack.axis = .horizontal
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
        ])
        for beat in beats {
            beat.widthAnchor.constraint(equalToConstant: 10).isActive = true
            beat.heightAnchor.constraint(equalToConstant: 10).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func configure(isCurrent: Bool) {
        setLitBeats(0)
        setCurrent(isCurrent, animated: false)
    }

    func setCurrent(_ isCurrent: Bool, animated: Bool) {
        isCurrentLine = isCurrent
        let apply = { [self] in
            contentView.alpha = isCurrent ? 1 : Self.dimmedAlpha
        }
        if animated, !UIAccessibility.isReduceMotionEnabled {
            UIViewPropertyAnimator(duration: 0.28, dampingRatio: 0.86, animations: apply).startAnimation()
        } else {
            apply()
        }
    }

    func setLitBeats(_ lit: Int) {
        for (index, beat) in beats.enumerated() {
            let target = index < lit ? 1 : Self.unlitAlpha
            guard beat.alpha != target else { continue }
            if UIAccessibility.isReduceMotionEnabled {
                beat.alpha = target
            } else {
                UIView.animate(withDuration: 0.26) { beat.alpha = target }
            }
        }
    }
}

/// A button whose tap area is at least 44 pt tall however compact it is drawn.
private final class TimingNoteChipButton: UIButton {

    private static let minimumTapHeight: CGFloat = 44

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let missing = max(0, Self.minimumTapHeight - bounds.height)
        return bounds.insetBy(dx: 0, dy: -missing / 2).contains(point)
    }
}

/// The popover behind the timing note chip: what is missing from the lyrics'
/// timing and where better timing comes from.
private final class TimingNoteViewController: UIViewController, UIPopoverPresentationControllerDelegate {

    private static let contentWidth: CGFloat = 280
    private static let padding: CGFloat = 16

    private let kind: LyricsTimingNoteKind

    init(kind: LyricsTimingNoteKind) {
        self.kind = kind
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let title = UILabel()
        title.text = LyricsTimingNoteCopy.title(for: kind)
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = .label
        title.numberOfLines = 0
        title.accessibilityTraits = .header

        let body = UILabel()
        body.text = LyricsTimingNoteCopy.body(for: kind)
        body.font = .preferredFont(forTextStyle: .subheadline)
        body.adjustsFontForContentSizeCategory = true
        body.textColor = .secondaryLabel
        body.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [title, body])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.padding),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.padding),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Self.padding),
            stack.widthAnchor.constraint(equalToConstant: Self.contentWidth - 2 * Self.padding),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        preferredContentSize = view.systemLayoutSizeFitting(
            CGSize(width: Self.contentWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
    }

    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
        .none
    }
}
