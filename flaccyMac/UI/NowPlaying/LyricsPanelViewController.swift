import AppKit

/// Synced-lyrics karaoke panel: the current line renders at full alpha and
/// scale while the rest dim and shrink toward the leading edge, the scroll
/// view follows the current line with a three-second grace period after the
/// user scrolls, and clicking a line seeks. Falls back to plain text, an
/// instrumental state, or an empty state.
final class LyricsPanelViewController: NSViewController {

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
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Called when this panel's Now Playing column shows or hides, so a hidden
    /// lyrics column stops re-highlighting lines 4×/sec. Defaults to active for
    /// the always-on window inspector.
    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if active {
            loadForCurrentTrack()
            progressChanged()
        }
    }

    @objc private func trackChanged() {
        loadForCurrentTrack()
    }

    @objc private func userScrolled() {
        guard !isProgrammaticScroll else { return }
        lastUserScroll = Date()
    }

    @objc private func progressChanged() {
        guard isActive, !syncedLines.isEmpty else { return }
        let time = player.currentTime
        var index = -1
        for (offset, line) in syncedLines.enumerated() {
            if line.time <= time { index = offset } else { break }
        }
        guard index != currentLineIndex else { return }
        currentLineIndex = index
        applyLineStyles(animated: true)
        followCurrentLine()
    }

    private func loadForCurrentTrack() {
        guard isViewLoaded, isActive else { return }
        guard let track = player.currentTrack else {
            loadedTrackKey = nil
            showState(icon: "quote.bubble", text: "Nothing playing")
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
            showState(icon: "quote.bubble", text: "No lyrics found")
            return
        }
        if result.isInstrumental {
            showState(icon: "music.note", text: "Instrumental")
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
        showState(icon: "quote.bubble", text: "No lyrics found")
    }

    private func buildLineViews() {
        clearLines()
        for (index, line) in syncedLines.enumerated() {
            let lineView = LyricLineView(text: line.text)
            lineView.onClick = { [weak self] in
                guard let self, index < self.syncedLines.count else { return }
                self.player.seek(to: self.syncedLines[index].time)
                AppLogger.info("Lyrics line seek to \(self.syncedLines[index].time)", category: .ui)
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

    private func followCurrentLine() {
        guard currentLineIndex >= 0, currentLineIndex < lineViews.count else { return }
        guard Date().timeIntervalSince(lastUserScroll) > 3 else { return }
        let lineFrame = lineViews[currentLineIndex].convert(lineViews[currentLineIndex].bounds, to: documentView)
        let targetY = max(0, lineFrame.minY - scrollView.contentView.bounds.height * 0.35)
        isProgrammaticScroll = true
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isProgrammaticScroll = false
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.45
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 1, 0.35, 1)
                context.allowsImplicitAnimation = true
                scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: targetY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }, completionHandler: { [weak self] in
                self?.isProgrammaticScroll = false
            })
        }
    }

    private func scrollToTop() {
        isProgrammaticScroll = true
        scrollView.contentView.setBoundsOrigin(.zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        isProgrammaticScroll = false
    }

    private func showState(icon: String?, text: String) {
        clearLines()
        syncedLines = []
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
