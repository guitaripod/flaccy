import AppKit
import AVFoundation
import AVKit
import Combine

/// The immersive Now Playing surface: a full-window overlay with the Metal
/// color-field backdrop, oversized artwork that breathes while paused, the
/// full transport, a chase-seek scrubber, action capsules (sleep timer,
/// Songlink share, AirPlay, lyrics, queue), and glass side panels for lyrics
/// and the queue rendered inside the overlay. Forced dark; Esc closes.
final class NowPlayingViewController: NSViewController {

    enum Panel {
        case lyrics
        case queue
    }

    var onClose: (() -> Void)?

    private let viewModel = NowPlayingViewModel()
    private let player: AudioPlaying = AudioPlayer.shared

    private let backdrop = BackdropView()
    private let scrim = CAGradientLayer()

    private let artworkContainer = NSView()
    private let artworkView = NSImageView()
    private let artworkPlaceholder = CAGradientLayer()

    private let titleLabel = MacMarqueeLabel()
    private let artistButton = HoverUnderlineButton()
    private let albumLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let badgeContainer = NSView()
    private var loveButton: TransportButton!

    private var shuffleButton: TransportButton!
    private var backFifteenButton: TransportButton!
    private var previousButton: TransportButton!
    private var playPauseButton: TransportButton!
    private var nextButton: TransportButton!
    private var forwardFifteenButton: TransportButton!
    private var repeatButton: TransportButton!

    private let scrubber = MacScrubberView()
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let remainingLabel = NSTextField(labelWithString: "-0:00")

    private var sleepCapsule: CapsuleButton!
    private var shareCapsule: CapsuleButton!
    private var lyricsCapsule: CapsuleButton!
    private var queueCapsule: CapsuleButton!
    private let routePicker = AVRoutePickerView()

    private let panelContainer = NSView()
    private let panelTitleLabel = NSTextField(labelWithString: "")
    private let panelContentContainer = NSView()
    private var panelWidthConstraint: NSLayoutConstraint?
    private var lyricsPanel: LyricsPanelViewController?
    private var queuePanel: QueuePanelViewController?
    private(set) var activePanel: Panel?

    private var stateCancellable: AnyCancellable?
    private var chaseInFlight = false
    private var pendingChaseTime: TimeInterval?
    private var chaseGeneration = 0
    private var currentPaletteKey: String?
    private var currentTrackKey: String?
    private var isBreathing = false

    private static let panelWidth: CGFloat = 340

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.appearance = NSAppearance(named: .darkAqua)

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(backdrop)

        scrim.colors = [
            NSColor.black.withAlphaComponent(0.62).cgColor,
            NSColor.black.withAlphaComponent(0.34).cgColor,
            NSColor.black.withAlphaComponent(0.68).cgColor,
        ]
        scrim.locations = [0, 0.5, 1]
        let scrimView = NSView()
        scrimView.wantsLayer = true
        scrimView.layer?.addSublayer(scrim)
        scrimView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrimView)

        let center = buildCenterColumn()
        buildPanelContainer()

        let body = NSStackView(views: [NSView(), center, NSView(), panelContainer])
        body.orientation = .horizontal
        body.distribution = .gravityAreas
        body.alignment = .centerY
        body.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(body)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrimView.topAnchor.constraint(equalTo: root.topAnchor),
            scrimView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrimView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrimView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            body.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            center.centerXAnchor.constraint(equalTo: body.centerXAnchor).with(priority: .defaultHigh),
            panelContainer.topAnchor.constraint(equalTo: body.topAnchor, constant: 12),
            panelContainer.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -12),
        ])

        let closeButton = TransportButton(
            symbolName: "chevron.down", pointSize: 14, accessibilityLabel: "Close Now Playing",
            target: self, action: #selector(closeTapped)
        )
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            closeButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
        ])

        view = root
        scrimViewRef = scrimView
    }

    private weak var scrimViewRef: NSView?

    override func viewDidLayout() {
        super.viewDidLayout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrim.frame = scrimViewRef?.bounds ?? .zero
        artworkPlaceholder.frame = artworkContainer.bounds
        CATransaction.commit()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        stateCancellable = viewModel.statePublisher.sink { [weak self] state in
            self?.apply(state)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(modesChanged), name: AudioPlayer.shuffleRepeatDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(lovedChanged), name: LovedTracksService.didChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(sleepTimerChanged), name: AudioPlayer.sleepTimerDidUpdate, object: nil
        )
        apply(viewModel.currentState)
        modesChanged()
        sleepTimerChanged()
        prefetchLyrics()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(view)
        backdrop.setPaused(false)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        backdrop.setPaused(true)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        AppLogger.info("NowPlayingViewController deinit", category: .ui)
    }

    override func cancelOperation(_ sender: Any?) {
        closeTapped()
    }

    func togglePanel(_ panel: Panel) {
        if activePanel == panel {
            hidePanel()
            return
        }
        activePanel = panel
        let content: NSViewController
        switch panel {
        case .lyrics:
            let controller = lyricsPanel ?? LyricsPanelViewController()
            lyricsPanel = controller
            content = controller
            panelTitleLabel.stringValue = "Lyrics"
        case .queue:
            let controller = queuePanel ?? QueuePanelViewController()
            queuePanel = controller
            content = controller
            panelTitleLabel.stringValue = "Queue"
        }
        for child in children where child is LyricsPanelViewController || child is QueuePanelViewController {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        addChild(content)
        content.view.translatesAutoresizingMaskIntoConstraints = false
        panelContentContainer.subviews.forEach { $0.removeFromSuperview() }
        panelContentContainer.addSubview(content.view)
        NSLayoutConstraint.activate([
            content.view.topAnchor.constraint(equalTo: panelContentContainer.topAnchor),
            content.view.leadingAnchor.constraint(equalTo: panelContentContainer.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: panelContentContainer.trailingAnchor),
            content.view.bottomAnchor.constraint(equalTo: panelContentContainer.bottomAnchor),
        ])
        setPanelVisible(true)
        refreshCapsuleToggles()
    }

    private func hidePanel() {
        activePanel = nil
        setPanelVisible(false)
        refreshCapsuleToggles()
    }

    private func setPanelVisible(_ visible: Bool) {
        let apply = {
            self.panelContainer.isHidden = !visible
            self.panelContainer.alphaValue = visible ? 1 : 0
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            apply()
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.allowsImplicitAnimation = true
                apply()
                self.view.layoutSubtreeIfNeeded()
            }
        }
    }

    private func refreshCapsuleToggles() {
        lyricsCapsule.isActiveToggle = activePanel == .lyrics
        queueCapsule.isActiveToggle = activePanel == .queue
    }

    private func buildCenterColumn() -> NSView {
        configureArtwork()
        configureLabels()
        buildTransportButtons()
        configureScrubber()
        let capsules = buildActionCapsules()

        let transportRow = NSStackView(views: [
            shuffleButton, backFifteenButton, previousButton, playPauseButton,
            nextButton, forwardFifteenButton, repeatButton,
        ])
        transportRow.orientation = .horizontal
        transportRow.spacing = 10
        transportRow.alignment = .centerY

        let timeline = NSStackView(views: [elapsedLabel, scrubber, remainingLabel])
        timeline.orientation = .horizontal
        timeline.spacing = 10

        let titleRow = NSStackView(views: [titleLabel, badgeContainer, loveButton])
        titleRow.orientation = .horizontal
        titleRow.spacing = 10
        titleRow.alignment = .centerY

        let column = NSStackView(views: [
            artworkContainer, titleRow, artistButton, albumLabel, timeline, transportRow, capsules,
        ])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 10
        column.setCustomSpacing(26, after: artworkContainer)
        column.setCustomSpacing(4, after: titleRow)
        column.setCustomSpacing(2, after: artistButton)
        column.setCustomSpacing(18, after: albumLabel)
        column.setCustomSpacing(16, after: timeline)
        column.setCustomSpacing(22, after: transportRow)

        NSLayoutConstraint.activate([
            artworkContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            artworkContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            artworkContainer.heightAnchor.constraint(equalTo: artworkContainer.widthAnchor),
            timeline.widthAnchor.constraint(equalTo: column.widthAnchor),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            scrubber.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        return column
    }

    private func buildPanelContainer() {
        panelTitleLabel.font = .systemFont(ofSize: 14, weight: .bold)
        panelTitleLabel.textColor = .labelColor

        let header = NSStackView(views: [panelTitleLabel])
        header.orientation = .horizontal
        header.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 4, right: 16)

        panelContentContainer.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [header, panelContentContainer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        panelContentContainer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let glass = MacLiquidGlass.surface(hosting: stack, cornerRadius: 20)
        glass.translatesAutoresizingMaskIntoConstraints = false
        panelContainer.addSubview(glass)
        panelContainer.translatesAutoresizingMaskIntoConstraints = false
        let width = panelContainer.widthAnchor.constraint(equalToConstant: Self.panelWidth)
        panelWidthConstraint = width
        NSLayoutConstraint.activate([
            width,
            glass.topAnchor.constraint(equalTo: panelContainer.topAnchor),
            glass.leadingAnchor.constraint(equalTo: panelContainer.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: panelContainer.trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: panelContainer.bottomAnchor),
        ])
        panelContainer.isHidden = true
        panelContainer.alphaValue = 0
    }

    private func configureArtwork() {
        artworkContainer.wantsLayer = true
        artworkContainer.layer?.cornerRadius = 14
        artworkContainer.layer?.cornerCurve = .continuous
        artworkContainer.layer?.masksToBounds = true
        artworkContainer.layer?.addSublayer(artworkPlaceholder)
        artworkContainer.translatesAutoresizingMaskIntoConstraints = false
        artworkView.imageScaling = .scaleProportionallyUpOrDown
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkContainer.addSubview(artworkView)
        NSLayoutConstraint.activate([
            artworkView.topAnchor.constraint(equalTo: artworkContainer.topAnchor),
            artworkView.leadingAnchor.constraint(equalTo: artworkContainer.leadingAnchor),
            artworkView.trailingAnchor.constraint(equalTo: artworkContainer.trailingAnchor),
            artworkView.bottomAnchor.constraint(equalTo: artworkContainer.bottomAnchor),
        ])
        let click = NSClickGestureRecognizer(target: self, action: #selector(togglePlayPause))
        artworkContainer.addGestureRecognizer(click)
    }

    private func configureLabels() {
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.heightAnchor.constraint(equalToConstant: 28).isActive = true

        artistButton.font = .systemFont(ofSize: 15, weight: .medium)
        artistButton.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        artistButton.target = self
        artistButton.action = #selector(artistTapped)

        albumLabel.font = .systemFont(ofSize: 12)
        albumLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        albumLabel.lineBreakMode = .byTruncatingTail
        albumLabel.alignment = .center

        badgeLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        badgeLabel.textColor = NSColor(red: 0.45, green: 0.86, blue: 0.92, alpha: 1)
        badgeContainer.wantsLayer = true
        badgeContainer.layer?.borderColor = NSColor(red: 0.45, green: 0.86, blue: 0.92, alpha: 0.6).cgColor
        badgeContainer.layer?.borderWidth = 1
        badgeContainer.layer?.cornerRadius = 7
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.addSubview(badgeLabel)
        NSLayoutConstraint.activate([
            badgeLabel.leadingAnchor.constraint(equalTo: badgeContainer.leadingAnchor, constant: 6),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeContainer.trailingAnchor, constant: -6),
            badgeLabel.topAnchor.constraint(equalTo: badgeContainer.topAnchor, constant: 3),
            badgeLabel.bottomAnchor.constraint(equalTo: badgeContainer.bottomAnchor, constant: -3),
        ])

        loveButton = TransportButton(
            symbolName: "heart", pointSize: 16, accessibilityLabel: "Love on Last.fm",
            target: self, action: #selector(toggleLove)
        )

        for label in [elapsedLabel, remainingLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = NSColor.white.withAlphaComponent(0.6)
        }
    }

    private func buildTransportButtons() {
        shuffleButton = TransportButton(
            symbolName: "shuffle", pointSize: 15, accessibilityLabel: "Shuffle",
            target: self, action: #selector(toggleShuffle)
        )
        backFifteenButton = TransportButton(
            symbolName: "gobackward.15", pointSize: 16, accessibilityLabel: "Back 15 seconds",
            target: self, action: #selector(skipBackFifteen)
        )
        previousButton = TransportButton(
            symbolName: "backward.fill", pointSize: 20, accessibilityLabel: "Previous",
            target: self, action: #selector(previousTrack)
        )
        playPauseButton = TransportButton(
            symbolName: "play.fill", pointSize: 34, accessibilityLabel: "Play or pause",
            target: self, action: #selector(togglePlayPause)
        )
        playPauseButton.isProminent = true
        playPauseButton.widthAnchor.constraint(equalToConstant: 72).isActive = true
        playPauseButton.heightAnchor.constraint(equalToConstant: 72).isActive = true
        nextButton = TransportButton(
            symbolName: "forward.fill", pointSize: 20, accessibilityLabel: "Next",
            target: self, action: #selector(nextTrack)
        )
        forwardFifteenButton = TransportButton(
            symbolName: "goforward.15", pointSize: 16, accessibilityLabel: "Forward 15 seconds",
            target: self, action: #selector(skipForwardFifteen)
        )
        repeatButton = TransportButton(
            symbolName: "repeat", pointSize: 15, accessibilityLabel: "Repeat",
            target: self, action: #selector(cycleRepeat)
        )
    }

    private func configureScrubber() {
        scrubber.onScrub = { [weak self] time in
            self?.chaseSeek(to: time)
        }
        scrubber.onCommit = { [weak self] time in
            self?.player.seek(to: time)
        }
    }

    private func buildActionCapsules() -> NSView {
        sleepCapsule = CapsuleButton(symbolName: "moon.zzz", title: "Sleep") { [weak self] button in
            self?.showSleepMenu(from: button)
        }
        shareCapsule = CapsuleButton(symbolName: "square.and.arrow.up", title: "Share") { [weak self] button in
            self?.shareCurrentTrack(from: button)
        }
        lyricsCapsule = CapsuleButton(symbolName: "quote.bubble", title: "Lyrics") { [weak self] _ in
            self?.togglePanel(.lyrics)
        }
        queueCapsule = CapsuleButton(symbolName: "list.bullet", title: "Queue") { [weak self] _ in
            self?.togglePanel(.queue)
        }

        routePicker.translatesAutoresizingMaskIntoConstraints = false
        routePicker.widthAnchor.constraint(equalToConstant: 34).isActive = true
        routePicker.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let row = NSStackView(views: [sleepCapsule, shareCapsule, routePicker, lyricsCapsule, queueCapsule])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        return row
    }

    private func apply(_ state: NowPlayingViewModel.State) {
        let trackKey = "\(state.title)\u{0}\(state.artist)\u{0}\(state.albumTitle)"
        let trackChanged = trackKey != currentTrackKey
        if trackChanged {
            currentTrackKey = trackKey
            chaseGeneration += 1
            pendingChaseTime = nil
            scrubber.abortScrub()
            prefetchLyrics()
        }

        titleLabel.text = state.title.isEmpty ? "Nothing Playing" : state.title
        artistButton.title = state.artist
        artistButton.isHidden = state.artist.isEmpty
        albumLabel.stringValue = state.albumTitle
        albumLabel.isHidden = state.albumTitle.isEmpty

        let badge = player.currentTrack?.qualityBadge
        badgeLabel.stringValue = badge ?? ""
        badgeContainer.isHidden = badge == nil
        loveButton.isEnabled = player.currentTrack != nil
        lovedChanged()

        if let artwork = state.artwork {
            artworkView.image = artwork
            artworkPlaceholder.isHidden = true
        } else {
            applyArtworkPlaceholder(seed: "\(state.albumTitle)|\(state.artist)")
        }
        updatePalette(state: state, animated: trackChanged)

        playPauseButton.setSymbol(state.isPlaying ? "pause.fill" : "play.fill", pointSize: 34)
        updateBreathing(paused: !state.isPlaying && player.currentTrack != nil)

        scrubber.setProgress(current: state.currentTime, duration: state.duration)
        elapsedLabel.stringValue = state.currentTimeFormatted
        remainingLabel.stringValue = state.remainingTimeFormatted
    }

    private func updatePalette(state: NowPlayingViewModel.State, animated: Bool) {
        let key = "\(state.albumTitle)\u{0}\(state.artist)"
        guard key != currentPaletteKey else { return }
        currentPaletteKey = key
        ArtworkPaletteExtractor.palette(
            for: state.artwork,
            cacheKey: key,
            fallbackSeed: state.title.isEmpty ? "flaccy" : "\(state.albumTitle)|\(state.artist)"
        ) { [weak self] palette in
            guard let self, self.currentPaletteKey == key else { return }
            self.backdrop.apply(palette, animated: animated)
        }
    }

    private func updateBreathing(paused: Bool) {
        guard paused != isBreathing else { return }
        isBreathing = paused
        artworkContainer.wantsLayer = true
        guard let layer = artworkContainer.layer else { return }
        layer.removeAnimation(forKey: "breathe")
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: artworkContainer.frame.midX, y: artworkContainer.frame.midY)
        if paused {
            let settle = CABasicAnimation(keyPath: "transform.scale")
            settle.fromValue = 1.0
            settle.toValue = 0.94
            settle.duration = reduceMotion ? 0 : 0.4
            settle.fillMode = .forwards
            settle.isRemovedOnCompletion = false
            if reduceMotion {
                layer.setAffineTransform(CGAffineTransform(scaleX: 0.94, y: 0.94))
            } else {
                layer.add(settle, forKey: "settle")
                let breathe = CABasicAnimation(keyPath: "transform.scale")
                breathe.fromValue = 0.94
                breathe.toValue = 0.965
                breathe.duration = 2.4
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                breathe.beginTime = CACurrentMediaTime() + 0.4
                breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(breathe, forKey: "breathe")
            }
        } else {
            layer.removeAnimation(forKey: "settle")
            layer.setAffineTransform(.identity)
        }
    }

    private func applyArtworkPlaceholder(seed: String) {
        artworkView.image = nil
        artworkPlaceholder.isHidden = false
        let (base, second) = PlaceholderGradient.colors(seed: seed)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artworkPlaceholder.colors = [base.cgColor, second.cgColor]
        artworkPlaceholder.startPoint = CGPoint(x: 0, y: 1)
        artworkPlaceholder.endPoint = CGPoint(x: 1, y: 0)
        artworkPlaceholder.frame = artworkContainer.bounds
        CATransaction.commit()
    }

    private func prefetchLyrics() {
        guard let track = player.currentTrack else { return }
        LyricsService.shared.prefetch(track: track.title, artist: track.artist, album: track.albumTitle)
    }

    private func chaseSeek(to time: TimeInterval) {
        guard !chaseInFlight else {
            pendingChaseTime = time
            return
        }
        chaseInFlight = true
        let generation = chaseGeneration
        let target = CMTime(seconds: time, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.12, preferredTimescale: 600)
        player.seekSmooth(to: target, tolerance: tolerance) { [weak self] in
            guard let self else { return }
            self.chaseInFlight = false
            guard generation == self.chaseGeneration, let pending = self.pendingChaseTime else { return }
            self.pendingChaseTime = nil
            self.chaseSeek(to: pending)
        }
    }

    private func showSleepMenu(from button: NSView) {
        let menu = SleepTimerMenuBuilder.build()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func shareCurrentTrack(from button: NSView) {
        guard let track = player.currentTrack else { return }
        let menu = NSMenu()
        let share = menu.addItem(withTitle: "Share via Songlink…", action: #selector(shareSonglink(_:)), keyEquivalent: "")
        share.target = self
        share.representedObject = button
        let copy = menu.addItem(withTitle: "Copy Songlink URL", action: #selector(copySonglink(_:)), keyEquivalent: "")
        copy.target = self
        menu.addItem(.separator())
        let info = menu.addItem(withTitle: "\(track.title) — \(track.artist)", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func shareSonglink(_ sender: NSMenuItem) {
        guard let track = player.currentTrack else { return }
        let anchor = (sender.representedObject as? NSView) ?? shareCapsule
        Task { [weak self] in
            guard let result = await SonglinkService.shared.lookup(title: track.title, artist: track.artist) else {
                MacToast.show("Couldn't find this track on streaming services.", style: .error, in: self?.view.window)
                return
            }
            guard let self, let anchor else { return }
            let picker = NSSharingServicePicker(items: [
                "\(result.title) by \(result.artist)", result.pageURL,
            ])
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
    }

    @objc private func copySonglink(_ sender: NSMenuItem) {
        guard let track = player.currentTrack else { return }
        Task { [weak self] in
            guard let result = await SonglinkService.shared.lookup(title: track.title, artist: track.artist) else {
                MacToast.show("Couldn't find this track on streaming services.", style: .error, in: self?.view.window)
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.pageURL.absoluteString, forType: .string)
            MacToast.show("Songlink copied", style: .success, in: self?.view.window)
        }
    }

    @objc private func artistTapped() {
        guard let track = player.currentTrack else { return }
        LibraryNavigator.revealArtist(LibraryHygiene.primaryArtist(track.artist))
        closeTapped()
    }

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func togglePlayPause() { player.togglePlayPause() }
    @objc private func nextTrack() { player.nextTrack() }
    @objc private func previousTrack() { player.previousTrack() }
    @objc private func toggleShuffle() { player.toggleShuffle() }
    @objc private func cycleRepeat() { player.cycleRepeatMode() }

    @objc private func skipBackFifteen() {
        player.seek(to: max(0, player.currentTime - 15))
    }

    @objc private func skipForwardFifteen() {
        player.seek(to: min(player.duration, player.currentTime + 15))
    }

    @objc private func toggleLove() {
        guard let track = player.currentTrack else { return }
        Task { _ = await LovedTracksService.shared.toggleLove(track: track) }
    }

    @objc private func modesChanged() {
        shuffleButton.isActiveToggle = player.shuffleEnabled
        repeatButton.isActiveToggle = player.repeatMode != .off
        repeatButton.setSymbol(player.repeatMode == .one ? "repeat.1" : "repeat", pointSize: 15)
    }

    @objc private func lovedChanged() {
        guard let track = player.currentTrack else {
            loveButton.setSymbol("heart", pointSize: 16)
            return
        }
        let loved = LovedTracksService.shared.isLoved(track: track)
        loveButton.setSymbol(loved ? "heart.fill" : "heart", pointSize: 16)
        loveButton.contentTintColor = loved
            ? NSColor(red: 1.0, green: 0.28, blue: 0.42, alpha: 1)
            : .secondaryLabelColor
    }

    @objc private func sleepTimerChanged() {
        if let remaining = player.sleepTimerRemaining {
            let total = Int(remaining)
            sleepCapsule.title = String(format: "%d:%02d", total / 60, total % 60)
            sleepCapsule.isActiveToggle = true
        } else if player.sleepAtEndOfTrack {
            sleepCapsule.title = "End of track"
            sleepCapsule.isActiveToggle = true
        } else {
            sleepCapsule.title = "Sleep"
            sleepCapsule.isActiveToggle = false
        }
    }
}

/// Shared sleep-timer menu used by the immersive view, the transport bar, and
/// the menu bar extra; items dispatch straight to the player.
@MainActor
enum SleepTimerMenuBuilder {

    static func build() -> NSMenu {
        let menu = NSMenu()
        for minutes in [15, 30, 45, 60, 90] {
            let item = menu.addItem(
                withTitle: "\(minutes) minutes", action: #selector(SleepTimerMenuTarget.setMinutes(_:)), keyEquivalent: ""
            )
            item.tag = minutes
            item.target = SleepTimerMenuTarget.shared
        }
        menu.addItem(.separator())
        let endOfTrack = menu.addItem(
            withTitle: "End of Track", action: #selector(SleepTimerMenuTarget.endOfTrack(_:)), keyEquivalent: ""
        )
        endOfTrack.target = SleepTimerMenuTarget.shared
        endOfTrack.state = AudioPlayer.shared.sleepAtEndOfTrack ? .on : .off
        let active = AudioPlayer.shared.sleepTimerRemaining != nil || AudioPlayer.shared.sleepAtEndOfTrack
        if active {
            menu.addItem(.separator())
            let cancel = menu.addItem(
                withTitle: "Cancel Timer", action: #selector(SleepTimerMenuTarget.cancel(_:)), keyEquivalent: ""
            )
            cancel.target = SleepTimerMenuTarget.shared
        }
        return menu
    }
}

final class SleepTimerMenuTarget: NSObject {

    @MainActor static let shared = SleepTimerMenuTarget()

    @MainActor @objc func setMinutes(_ sender: NSMenuItem) {
        AudioPlayer.shared.setSleepTimer(minutes: sender.tag)
        AppLogger.info("Sleep timer set: \(sender.tag) minutes", category: .playback)
    }

    @MainActor @objc func endOfTrack(_ sender: NSMenuItem) {
        AudioPlayer.shared.setSleepTimerEndOfTrack()
        AppLogger.info("Sleep timer set: end of track", category: .playback)
    }

    @MainActor @objc func cancel(_ sender: NSMenuItem) {
        AudioPlayer.shared.cancelSleepTimer()
        AppLogger.info("Sleep timer cancelled", category: .playback)
    }
}

/// Glass action capsule with an SF Symbol and a short title; highlights while
/// toggled active.
final class CapsuleButton: NSControl {

    var onTap: ((CapsuleButton) -> Void)?

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    var isActiveToggle = false {
        didSet { refreshBackground() }
    }

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let background = NSView()
    private var isHovered = false

    init(symbolName: String, title: String, onTap: @escaping (CapsuleButton) -> Void) {
        self.onTap = onTap
        super.init(frame: .zero)
        wantsLayer = true

        background.wantsLayer = true
        background.layer?.cornerRadius = 15
        background.layer?.cornerCurve = .continuous
        background.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        icon.contentTintColor = .labelColor
        label.stringValue = title
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .labelColor

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refreshBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refreshBackground()
    }

    override func mouseDown(with event: NSEvent) {
        onTap?(self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func refreshBackground() {
        let alpha: CGFloat = isActiveToggle ? 0.28 : (isHovered ? 0.18 : 0.1)
        background.layer?.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
    }
}

/// Borderless text button that underlines on hover, used for the artist name.
final class HoverUnderlineButton: NSButton {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        setButtonType(.momentaryChange)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        applyUnderline(true)
    }

    override func mouseExited(with event: NSEvent) {
        applyUnderline(false)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func applyUnderline(_ underlined: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 15),
            .foregroundColor: contentTintColor ?? .labelColor,
            .underlineStyle: underlined ? NSUnderlineStyle.single.rawValue : 0,
        ]
        attributedTitle = NSAttributedString(string: title, attributes: attributes)
    }
}

private extension NSLayoutConstraint {
    func with(priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
