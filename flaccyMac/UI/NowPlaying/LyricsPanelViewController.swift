import AppKit

/// Synced-lyrics karaoke panel: the current line renders at full alpha and
/// scale while the rest dim and shrink toward the leading edge, the scroll
/// view follows the current line with a three-second grace period after the
/// user scrolls, and clicking a line seeks. Falls back to plain text, an
/// instrumental state, or an empty state.
final class LyricsPanelViewController: NSViewController {

    /// How far ahead of the clock a line lights up. The player reports the
    /// position it has rendered, not the one you are hearing, and the emphasis
    /// still has to animate in — without a lead the line always arrives late.
    private static let lyricLead: TimeInterval = 0.22
    /// Where the active line sits in the viewport — slightly above center, the
    /// way every good lyrics view frames the line you are about to sing.
    private static let activeLineAnchor: CGFloat = 0.42
    /// Angular frequency of the critically damped follow spring, in rad/s.
    private static let scrollResponse: CGFloat = 15
    /// Frame deltas are clamped before integrating so a stalled frame can't blow
    /// the spring up.
    private static let maxFrameDelta: CFTimeInterval = 1.0 / 30
    /// 60 Hz, the rate the lyric emphasis and the follow spring are integrated at.
    private static let frameInterval: TimeInterval = 1.0 / 60

    private let player: AudioPlaying = AudioPlayer.shared

    private let scrollView = NSScrollView()
    private let linesStack = NSStackView()
    private let documentView = FlippedView()
    private let plainTextView = NSTextField(wrappingLabelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let stateIcon = NSImageView()
    private let spinner = NSProgressIndicator()

    private var lineViews: [LyricLineView] = []
    private var syncedLines: [LyricLine] = []
    private var currentLineIndex = -1
    private var loadGeneration = 0
    private var loadedTrackKey: String?
    private var lastUserScroll: Date = .distantPast
    private var isProgrammaticScroll = false
    private var isActive = true
    private var ticker: Timer?
    private var lastFrameTime: CFTimeInterval = 0
    private var needsLineRefresh = false
    private var scrollTarget: CGFloat?
    private var scrollVelocity: CGFloat = 0

    override func loadView() {
        view = NSView()

        linesStack.orientation = .vertical
        linesStack.alignment = .leading
        linesStack.spacing = 14
        linesStack.edgeInsets = NSEdgeInsets(top: 24, left: 20, bottom: 200, right: 20)
        linesStack.translatesAutoresizingMaskIntoConstraints = false

        plainTextView.font = .systemFont(ofSize: 15, weight: .medium)
        plainTextView.textColor = .labelColor
        plainTextView.isSelectable = true
        plainTextView.translatesAutoresizingMaskIntoConstraints = false

        documentView.addSubview(linesStack)
        documentView.addSubview(plainTextView)
        NSLayoutConstraint.activate([
            linesStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            linesStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            linesStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            linesStack.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor),
            plainTextView.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 24),
            plainTextView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 20),
            plainTextView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -20),
            plainTextView.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor, constant: -24),
        ])

        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        stateIcon.symbolConfiguration = .init(pointSize: 28, weight: .light)
        stateIcon.contentTintColor = .tertiaryLabelColor
        stateLabel.font = .systemFont(ofSize: 13)
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.alignment = .center
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let stateStack = NSStackView(views: [stateIcon, stateLabel, spinner])
        stateStack.orientation = .vertical
        stateStack.spacing = 8
        stateStack.alignment = .centerX
        stateStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stateStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stateStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stateStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(trackChanged), name: AudioPlayer.trackDidChange, object: nil)
        center.addObserver(self, selector: #selector(progressChanged), name: AudioPlayer.playbackProgressDidChange, object: nil)
        center.addObserver(self, selector: #selector(playbackStateChanged), name: AudioPlayer.playbackStateDidChange, object: nil)
        center.addObserver(
            self, selector: #selector(userScrolled),
            name: NSScrollView.willStartLiveScrollNotification, object: scrollView
        )
        center.addObserver(
            self, selector: #selector(userScrolled),
            name: NSScrollView.didLiveScrollNotification, object: scrollView
        )
        loadForCurrentTrack()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        loadForCurrentTrack()
        syncDisplayLink()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        stopDisplayLink()
    }

    /// End padding scales with the viewport so the first and last lines can
    /// reach the anchor instead of being pinned to an edge.
    override func viewDidLayout() {
        super.viewDidLayout()
        let viewport = scrollView.contentView.bounds.height
        guard viewport > 1 else { return }
        linesStack.edgeInsets = NSEdgeInsets(
            top: max(24, viewport * Self.activeLineAnchor),
            left: 20,
            bottom: max(24, viewport * (1 - Self.activeLineAnchor)),
            right: 20
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        ticker?.invalidate()
    }

    /// Called when this panel's Now Playing column shows or hides, so a hidden
    /// lyrics column stops tracking lines every frame. Defaults to active for
    /// the always-on window inspector.
    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if active {
            loadForCurrentTrack()
            progressChanged()
        } else {
            stopDisplayLink()
        }
    }

    @objc private func trackChanged() {
        loadForCurrentTrack()
    }

    @objc private func userScrolled() {
        guard !isProgrammaticScroll else { return }
        lastUserScroll = Date()
        cancelScroll()
    }

    /// Re-evaluates the active line and advances the follow spring every frame
    /// rather than on the player's quarter-second tick — a line change is only
    /// ever a frame late, and the scroll is a glide instead of a series of hops.
    @objc private func step() {
        let now = CACurrentMediaTime()
        let previous = lastFrameTime
        lastFrameTime = now
        let delta = previous == 0 ? Self.maxFrameDelta : min(max(now - previous, 0), Self.maxFrameDelta)

        if player.isPlaying || needsLineRefresh {
            needsLineRefresh = false
            updateCurrentLine(at: player.currentTime + Self.lyricLead)
        }
        advanceScroll(by: CGFloat(delta))
        if !player.isPlaying, scrollTarget == nil {
            stopDisplayLink()
        }
    }

    private func updateCurrentLine(at time: TimeInterval) {
        var index = -1
        for (offset, line) in syncedLines.enumerated() {
            if line.time <= time { index = offset } else { break }
        }
        guard index != currentLineIndex else { return }
        currentLineIndex = index
        applyLineStyles(animated: true)
        followCurrentLine()
    }

    @objc private func playbackStateChanged() {
        syncDisplayLink()
    }

    @objc private func progressChanged() {
        // A seek moves the clock without a frame of playback behind it.
        needsLineRefresh = true
        syncDisplayLink()
    }

    /// The link runs only while there is something to animate: a hidden or
    /// paused panel with a settled scroll costs nothing.
    private func syncDisplayLink() {
        let wanted = isActive && !syncedLines.isEmpty && view.window != nil
            && (player.isPlaying || scrollTarget != nil || needsLineRefresh)
        if wanted {
            startDisplayLink()
        } else {
            stopDisplayLink()
        }
    }

    /// A run-loop ticker rather than a `CADisplayLink`: AppKit pauses a view's
    /// display link whenever its app isn't frontmost, and a music player spends
    /// most of its life in a window you are not clicking on — the lyrics would
    /// simply stop moving. `.common` mode keeps it running through menu tracking
    /// and live resize too.
    private func startDisplayLink() {
        guard ticker == nil else { return }
        lastFrameTime = 0
        let timer = Timer(timeInterval: Self.frameInterval, target: self, selector: #selector(step), userInfo: nil, repeats: true)
        timer.tolerance = Self.frameInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopDisplayLink() {
        ticker?.invalidate()
        ticker = nil
    }

    private func loadForCurrentTrack() {
        guard isViewLoaded, isActive else { return }
        guard let track = player.currentTrack else {
            loadedTrackKey = nil
            showState(icon: "quote.bubble", text: String(localized: "Nothing playing"))
            return
        }
        let key = "\(track.title)\u{0}\(track.artist)"
        guard key != loadedTrackKey else { return }
        loadedTrackKey = key
        loadGeneration += 1
        let generation = loadGeneration

        syncedLines = []
        currentLineIndex = -1
        clearLines()
        plainTextView.isHidden = true
        showState(icon: nil, text: "")
        spinner.startAnimation(nil)

        Task { [weak self] in
            let result = await LyricsService.shared.fetchLyrics(
                track: track.title, artist: track.artist, album: track.albumTitle
            )
            guard let self, self.loadGeneration == generation else { return }
            self.spinner.stopAnimation(nil)
            self.render(result)
        }
    }

    private func render(_ result: LyricsResult?) {
        guard let result else {
            showState(icon: "quote.bubble", text: String(localized: "No lyrics found"))
            return
        }
        if result.isInstrumental {
            showState(icon: "music.note", text: String(localized: "Instrumental"))
            return
        }
        if let lines = result.syncedLines, !lines.isEmpty {
            hideState()
            syncedLines = lines
            buildLineViews()
            progressChanged()
            return
        }
        if let plain = result.plainText, !plain.isEmpty {
            hideState()
            plainTextView.stringValue = plain
            plainTextView.isHidden = false
            scrollToTop()
            return
        }
        showState(icon: "quote.bubble", text: String(localized: "No lyrics found"))
    }

    private func buildLineViews() {
        clearLines()
        for (index, line) in syncedLines.enumerated() {
            let lineView = LyricLineView(text: line.text)
            lineView.onClick = { [weak self] in
                guard let self, index < self.syncedLines.count else { return }
                // Nudge back a beat so the first syllable isn't clipped.
                let time = max(0, self.syncedLines[index].time - 0.15)
                self.player.seek(to: time)
                self.lastUserScroll = .distantPast
                AppLogger.info("Lyrics line seek to \(time)", category: .ui)
            }
            linesStack.addArrangedSubview(lineView)
            lineView.widthAnchor.constraint(equalTo: linesStack.widthAnchor, constant: -40).isActive = true
            lineViews.append(lineView)
        }
        applyLineStyles(animated: false)
        scrollToTop()
    }

    private func clearLines() {
        lineViews.forEach { $0.removeFromSuperview() }
        lineViews = []
    }

    private func applyLineStyles(animated: Bool) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let apply = {
            for (index, lineView) in self.lineViews.enumerated() {
                lineView.setCurrent(index == self.currentLineIndex, reduceMotion: reduceMotion)
            }
        }
        guard animated, !reduceMotion else {
            apply()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            context.allowsImplicitAnimation = true
            apply()
        }
    }

    /// Aims the follow spring at the active line. The target comes from the
    /// line's real geometry, so wrapped lines don't drift it out of step, and
    /// retargeting mid-flight keeps the current velocity — consecutive lines
    /// read as one continuous glide rather than a restart each time.
    private func followCurrentLine() {
        guard currentLineIndex >= 0, currentLineIndex < lineViews.count else { return }
        guard Date().timeIntervalSince(lastUserScroll) > 3 else { return }
        let line = lineViews[currentLineIndex]
        let frame = line.convert(line.bounds, to: documentView)
        let viewport = scrollView.contentView.bounds.height
        guard viewport > 1 else { return }
        let target = frame.midY - viewport * Self.activeLineAnchor
        scrollTarget = min(max(target, 0), maxScrollOffset)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            settleScroll(at: scrollTarget ?? 0)
        } else {
            syncDisplayLink()
        }
    }

    /// One frame of a critically damped spring toward the aimed-at offset.
    private func advanceScroll(by delta: CGFloat) {
        guard let target = scrollTarget else { return }
        let value = scrollView.contentView.bounds.origin.y
        let distance = target - value
        if abs(distance) < 0.5, abs(scrollVelocity) < 4 {
            settleScroll(at: target)
            return
        }
        let response = Self.scrollResponse
        scrollVelocity += (response * response * distance - 2 * response * scrollVelocity) * delta
        scrollTo(value + scrollVelocity * delta)
    }

    private func settleScroll(at offset: CGFloat) {
        scrollTo(offset)
        scrollTarget = nil
        scrollVelocity = 0
    }

    private func cancelScroll() {
        scrollTarget = nil
        scrollVelocity = 0
    }

    private func scrollTo(_ offset: CGFloat) {
        isProgrammaticScroll = true
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        isProgrammaticScroll = false
    }

    private var maxScrollOffset: CGFloat {
        max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
    }

    private func scrollToTop() {
        cancelScroll()
        scrollTo(0)
    }

    private func showState(icon: String?, text: String) {
        clearLines()
        syncedLines = []
        cancelScroll()
        stopDisplayLink()
        plainTextView.isHidden = true
        stateLabel.stringValue = text
        stateLabel.isHidden = text.isEmpty
        if let icon {
            stateIcon.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            stateIcon.isHidden = false
        } else {
            stateIcon.isHidden = true
        }
    }

    private func hideState() {
        stateLabel.isHidden = true
        stateIcon.isHidden = true
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One clickable lyric line; current-line emphasis animates alpha and a
/// leading-anchored scale.
final class LyricLineView: NSView {

    var onClick: (() -> Void)?

    private let label = NSTextField(wrappingLabelWithString: "")

    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        label.stringValue = text
        label.font = .systemFont(ofSize: 17, weight: .bold)
        label.textColor = .labelColor
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setCurrent(_ current: Bool, reduceMotion: Bool) {
        alphaValue = current ? 1 : 0.35
        guard let layer else { return }
        layer.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer.position = CGPoint(x: frame.minX, y: frame.midY)
        let scale: CGFloat = current || reduceMotion ? 1 : 0.86
        layer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
    }

    @objc private func clicked() {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
