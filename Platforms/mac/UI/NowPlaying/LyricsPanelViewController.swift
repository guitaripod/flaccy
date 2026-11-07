import AppKit
import MidgarCore
import FlaccyCore

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
    private let stateTitle = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(wrappingLabelWithString: "")
    private let stateIcon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let retryButton = NSButton(title: "", target: nil, action: nil)
    private let timingButton = NSButton()
    private let shareButton = NSButton()
    private let meaningButton = NSButton()
    private var meaningPopover: NSPopover?
    private var shareableLyrics: Lyrics?
    private let timingNoteChip = NSButton()
    private var timingNoteKind: LyricsTimingNoteKind?
    private var timingNotePopover: NSPopover?
    private static let offsetStepMs = 100
    private static let offsetLimitMs = 10_000
    private static let seekLeadIn: TimeInterval = 0.15
    private static let stateWidth: CGFloat = 300
    private static let timingNoteFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

    private var lineViews: [LyricRowView] = []
    private var document = LyricsDocument()
    private var lyrics: Lyrics?
    private var litLines: [Int] = []
    private var lastLyricTime: TimeInterval = 0
    private var currentLineIndex = -1
    private var loadGeneration = 0
    private var lyricsLoad: LyricsLoad?
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
            plainTextView.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 44),
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
        stateTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        stateTitle.textColor = .labelColor
        stateTitle.alignment = .center
        stateTitle.lineBreakMode = .byWordWrapping
        stateTitle.maximumNumberOfLines = 3
        stateTitle.preferredMaxLayoutWidth = Self.stateWidth
        stateLabel.font = .systemFont(ofSize: 12.5)
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.alignment = .center
        stateLabel.preferredMaxLayoutWidth = Self.stateWidth
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        retryButton.title = String(localized: "Try Again")
        retryButton.bezelStyle = .accessoryBarAction
        retryButton.controlSize = .large
        retryButton.isHidden = true
        retryButton.target = self
        retryButton.action = #selector(retryLoad)

        timingButton.image = NSImage(systemSymbolName: "clock", accessibilityDescription: String(localized: "Lyrics timing"))
        timingButton.imagePosition = .imageOnly
        timingButton.isBordered = false
        timingButton.contentTintColor = .tertiaryLabelColor
        timingButton.toolTip = String(localized: "Lyrics timing")
        timingButton.isHidden = true
        timingButton.target = self
        timingButton.action = #selector(showTimingMenu(_:))

        timingNoteChip.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        timingNoteChip.imagePosition = .imageLeading
        timingNoteChip.bezelStyle = .accessoryBarAction
        timingNoteChip.controlSize = .small
        timingNoteChip.contentTintColor = .secondaryLabelColor
        timingNoteChip.isHidden = true
        timingNoteChip.target = self
        timingNoteChip.action = #selector(toggleTimingNote(_:))

        shareButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: LyricShareCopy.sheetTitle)
        shareButton.imagePosition = .imageOnly
        shareButton.isBordered = false
        shareButton.contentTintColor = .tertiaryLabelColor
        shareButton.toolTip = LyricShareCopy.sheetTitle
        shareButton.isHidden = true
        shareButton.target = self
        shareButton.action = #selector(shareLyricsTapped)

        meaningButton.image = NSImage(systemSymbolName: "text.book.closed", accessibilityDescription: LyricsMeaningCopy.buttonTitle)
        meaningButton.imagePosition = .imageOnly
        meaningButton.isBordered = false
        meaningButton.contentTintColor = .tertiaryLabelColor
        meaningButton.toolTip = LyricsMeaningCopy.buttonTitle
        meaningButton.isHidden = true
        meaningButton.target = self
        meaningButton.action = #selector(meaningTapped(_:))

        let timingControls = NSStackView(views: [meaningButton, shareButton, timingNoteChip, timingButton])
        timingControls.orientation = .horizontal
        timingControls.alignment = .centerY
        timingControls.spacing = 6
        timingControls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(timingControls)

        let stateStack = NSStackView(views: [stateIcon, stateTitle, stateLabel, spinner, retryButton])
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
            stateStack.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48),
            timingControls.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            timingControls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
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

    isolated deinit {
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

    @objc private func retryLoad() {
        retryButton.isHidden = true
        loadedTrackKey = nil
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
            updateLitLines(at: player.currentTime + Self.lyricLead)
        }
        advanceScroll(by: CGFloat(delta))
        if !player.isPlaying, scrollTarget == nil {
            stopDisplayLink()
        }
    }

    /// Lights the lines the clock is on and moves the fill inside them. The
    /// listener's timing correction is applied to the clock, not to the lines.
    private func updateLitLines(at position: TimeInterval) {
        guard let lyrics, document.hasSynced else { return }
        let time = lyrics.songTime(at: position)
        lastLyricTime = time
        let primary = document.primaryIndex(at: time) ?? -1
        let lit = document.highlighted(at: time)
        if primary != currentLineIndex || lit != litLines {
            let moved = primary != currentLineIndex
            currentLineIndex = primary
            litLines = lit
            applyLineStyles(animated: true)
            if moved { followCurrentLine() }
        }
        for index in lit where index < lineViews.count {
            lineViews[index].show(document.lines[index], time: time)
        }
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
        let wanted = isActive && document.hasSynced && view.window != nil
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
            showState(icon: "quote.bubble", words: LyricsStatusCopy.idle)
            return
        }
        let key = "\(track.title)\u{0}\(track.artist)"
        guard key != loadedTrackKey else { return }
        loadedTrackKey = key
        loadGeneration += 1
        let generation = loadGeneration

        document = LyricsDocument()
        lyrics = nil
        shareableLyrics = nil
        litLines = []
        currentLineIndex = -1
        clearLines()
        plainTextView.isHidden = true
        showState(icon: nil, words: nil)
        spinner.startAnimation(nil)

        let updates = LyricsService.shared.lyricsUpdates(
            track: track.title, artist: track.artist, album: track.albumTitle,
            fileURL: track.fileURL, duration: track.duration
        )
        lyricsLoad = LyricsLoad(Task { [weak self] in
            for await outcome in updates {
                guard let self, self.loadGeneration == generation else { return }
                self.spinner.stopAnimation(nil)
                self.render(outcome, song: track.title)
            }
        })
    }

    private func render(_ outcome: LyricsOutcome, song: String) {
        let found: Lyrics
        switch outcome {
        case .found(let result):
            found = result
        case .missing:
            showState(icon: "quote.bubble", words: LyricsStatusCopy.missing(song: song))
            return
        case .failed(let failure):
            showState(icon: Self.icon(for: failure), words: LyricsStatusCopy.failed(failure))
            retryButton.isHidden = false
            return
        }
        if found.document.instrumental {
            showState(icon: "music.note", words: LyricsStatusCopy.instrumental)
            return
        }
        if found.document.hasSynced {
            hideState()
            lyrics = found
            shareableLyrics = found
            shareButton.isHidden = false
            meaningButton.isHidden = MeaningPrompt.sungLines(found.document).isEmpty
            document = found.document
            timingButton.isHidden = false
            showTimingNote(for: found.document)
            buildLineViews()
            progressChanged()
            return
        }
        if let plain = found.document.plain, !plain.isEmpty {
            hideState()
            plainTextView.stringValue = plain
            plainTextView.isHidden = false
            shareableLyrics = found
            shareButton.isHidden = false
            meaningButton.isHidden = MeaningPrompt.sungLines(found.document).isEmpty
            showTimingNote(for: found.document)
            scrollToTop()
            return
        }
        showState(icon: "quote.bubble", words: LyricsStatusCopy.missing(song: song))
    }

    private static func icon(for failure: LyricsFailure) -> String {
        switch failure {
        case .unreachable: return "wifi.exclamationmark"
        case .timedOut: return "hourglass"
        case .busy: return "tortoise"
        case .server, .rejected: return "exclamationmark.triangle"
        }
    }

    private func buildLineViews() {
        clearLines()
        for (index, line) in document.lines.enumerated() {
            let lineView: LyricRowView = line.isInterlude ? InterludeLineView() : LyricLineView(line: line)
            lineView.onClick = { [weak self] in
                guard let self, index < self.document.lines.count else { return }
                let start = self.document.lines[index].start + (self.lyrics?.offsetSeconds ?? 0)
                let time = max(0, start - Self.seekLeadIn)
                self.player.seek(to: time)
                self.lastUserScroll = .distantPast
                MidgarLog.info("Lyrics line seek to \(time)", category: .ui)
            }
            lineView.contextMenuProvider = { [weak self] in self?.lineMenu(forLine: index) }
            linesStack.addArrangedSubview(lineView)
            lineView.widthAnchor.constraint(equalTo: linesStack.widthAnchor, constant: -40).isActive = true
            lineViews.append(lineView)
        }
        applyLineStyles(animated: false)
        scrollToTop()
    }

    @objc private func shareLyricsTapped() {
        openShare(line: nil)
    }

    @objc private func shareFromLine(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        openShare(line: index)
    }

    /// Opens the share window on the lyrics showing for the playing track,
    /// with the clip starting at `line` when one was picked.
    private func openShare(line: Int?) {
        guard let current = lyrics ?? shareableLyrics,
              let session = LyricShareSession.forCurrentTrack(lyrics: current, line: line)
        else {
            MacToast.show(LyricShareCopy.nothingToShare, style: .error, in: view.window)
            return
        }
        LyricShareWindowController.present(session, from: view.window)
    }

    /// The right-click menu of a sung line: what it means, and a clip
    /// starting from it. An instrumental stretch has none: there is nothing
    /// to sing in it.
    private func lineMenu(forLine index: Int) -> NSMenu? {
        guard MeaningPrompt.focus(document, index: index) != nil else { return nil }
        let menu = NSMenu()
        let explain = menu.addItem(withTitle: LyricsMeaningCopy.explainLine, action: #selector(explainLine(_:)), keyEquivalent: "")
        explain.image = NSImage(systemSymbolName: "text.book.closed", accessibilityDescription: nil)
        explain.target = self
        explain.representedObject = index
        if LyricShareClip.isSelectable(index, in: document) {
            let share = menu.addItem(withTitle: LyricShareCopy.fromLine, action: #selector(shareFromLine(_:)), keyEquivalent: "")
            share.image = NSImage(systemSymbolName: "quote.bubble", accessibilityDescription: nil)
            share.target = self
            share.representedObject = index
        }
        return menu
    }

    @objc private func meaningTapped(_ sender: NSButton) {
        showMeaning(line: nil)
    }

    @objc private func explainLine(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        showMeaning(line: index)
    }

    /// Opens the Meaning popover on line `line`, beside it, or on the whole
    /// song under the corner button, for the lyrics showing. Returns the
    /// popover so a capture can find its window.
    @discardableResult
    func showMeaning(line: Int?) -> NSPopover? {
        meaningPopover?.close()
        guard let current = lyrics ?? shareableLyrics, let track = player.currentTrack else { return nil }
        let anchor: NSView
        let edge: NSRectEdge
        if let line {
            guard line < lineViews.count else { return nil }
            anchor = lineViews[line]
            edge = .minX
        } else {
            anchor = meaningButton
            edge = .maxY
        }
        meaningPopover = MacLyricsMeaningViewController.show(
            song: MeaningSong(title: track.title, artist: track.artist, album: track.albumTitle),
            document: current.document, line: line, relativeTo: anchor, edge: edge)
        return meaningPopover
    }

    private func clearLines() {
        lineViews.forEach { $0.removeFromSuperview() }
        lineViews = []
    }

    private func applyLineStyles(animated: Bool) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let apply = {
            for (index, lineView) in self.lineViews.enumerated() {
                let lit = self.litLines.contains(index)
                lineView.setCurrent(lit, reduceMotion: reduceMotion)
                if !lit { lineView.clearProgress() }
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

    /// Computes the note once for the document just applied and shows or hides
    /// the chip to match.
    private func showTimingNote(for document: LyricsDocument) {
        guard let kind = LyricsTimingNote.kind(for: document) else {
            hideTimingNote()
            return
        }
        timingNoteKind = kind
        timingNoteChip.attributedTitle = NSAttributedString(
            string: LyricsTimingNoteCopy.label(for: kind),
            attributes: [.font: Self.timingNoteFont, .foregroundColor: NSColor.secondaryLabelColor]
        )
        timingNoteChip.toolTip = LyricsTimingNoteCopy.title(for: kind)
        timingNoteChip.setAccessibilityLabel(LyricsTimingNoteCopy.label(for: kind))
        timingNoteChip.setAccessibilityHelp(LyricsTimingNoteCopy.accessibilityHint)
        timingNoteChip.isHidden = false
    }

    private func hideTimingNote() {
        timingNoteKind = nil
        timingNoteChip.isHidden = true
        timingNotePopover?.close()
    }

    @objc private func toggleTimingNote(_ sender: NSButton) {
        if let popover = timingNotePopover, popover.isShown {
            popover.close()
            return
        }
        guard let kind = timingNoteKind else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = TimingNoteViewController(kind: kind)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        timingNotePopover = popover
    }

    /// A menu under the clock button that shifts the lyrics earlier or later
    /// when they run ahead of or behind the singing.
    @objc private func showTimingMenu(_ sender: NSButton) {
        guard let lyrics else { return }
        let menu = NSMenu()
        let status = NSMenuItem(title: Self.offsetText(lyrics.offsetMs), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        let earlier = NSMenuItem(title: String(localized: "Show Lyrics Earlier"), action: #selector(nudgeEarlier), keyEquivalent: "")
        let later = NSMenuItem(title: String(localized: "Show Lyrics Later"), action: #selector(nudgeLater), keyEquivalent: "")
        let reset = NSMenuItem(title: String(localized: "Reset Timing"), action: #selector(resetTiming), keyEquivalent: "")
        for item in [earlier, later, reset] {
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func nudgeEarlier() {
        setOffset((lyrics?.offsetMs ?? 0) - Self.offsetStepMs)
    }

    @objc private func nudgeLater() {
        setOffset((lyrics?.offsetMs ?? 0) + Self.offsetStepMs)
    }

    @objc private func resetTiming() {
        setOffset(0)
    }

    private func setOffset(_ offsetMs: Int) {
        guard var lyrics, let track = player.currentTrack else { return }
        lyrics.offsetMs = min(max(offsetMs, -Self.offsetLimitMs), Self.offsetLimitMs)
        self.lyrics = lyrics
        LyricsService.shared.saveOffset(track: track.title, artist: track.artist, offsetMs: lyrics.offsetMs)
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

    private func showState(icon: String?, words: LyricsStatusCopy.Words?) {
        retryButton.isHidden = true
        timingButton.isHidden = true
        shareButton.isHidden = true
        meaningButton.isHidden = true
        meaningPopover?.close()
        shareableLyrics = nil
        hideTimingNote()
        clearLines()
        document = LyricsDocument()
        lyrics = nil
        litLines = []
        cancelScroll()
        stopDisplayLink()
        plainTextView.isHidden = true
        stateTitle.stringValue = words?.title ?? ""
        stateTitle.isHidden = words == nil
        stateLabel.stringValue = words?.body ?? ""
        stateLabel.isHidden = words == nil
        if let icon {
            stateIcon.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            stateIcon.isHidden = false
        } else {
            stateIcon.isHidden = true
        }
    }

    private func hideState() {
        retryButton.isHidden = true
        stateTitle.isHidden = true
        stateLabel.isHidden = true
        stateIcon.isHidden = true
    }
}

/// The popover behind the timing note chip: what is missing from the lyrics'
/// timing and where better timing comes from.
private final class TimingNoteViewController: NSViewController {

    private static let contentWidth: CGFloat = 280
    private static let padding: CGFloat = 14

    private let kind: LyricsTimingNoteKind

    init(kind: LyricsTimingNoteKind) {
        self.kind = kind
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func loadView() {
        let textWidth = Self.contentWidth - 2 * Self.padding

        let title = NSTextField(wrappingLabelWithString: LyricsTimingNoteCopy.title(for: kind))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.preferredMaxLayoutWidth = textWidth

        let body = NSTextField(wrappingLabelWithString: LyricsTimingNoteCopy.body(for: kind))
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = textWidth

        let stack = NSStackView(views: [title, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: Self.padding, left: Self.padding, bottom: Self.padding, right: Self.padding)
        stack.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        view = stack
    }
}
