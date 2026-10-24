import AppKit
import MidgarCore
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

    let viewModel = NowPlayingViewModel()
    let player: AudioPlaying = AudioPlayer.shared

    let backdrop = BackdropView()
    let scrim = CAGradientLayer()

    let artworkContainer = NSView()
    let artworkView = NSImageView()
    let artworkPlaceholder = CAGradientLayer()

    let titleLabel = MacMarqueeLabel()
    let artistButton = HoverUnderlineButton()
    let albumLabel = NSTextField(labelWithString: "")
    let badgeLabel = NSTextField(labelWithString: "")
    let badgeContainer = NSView()
    var loveButton: TransportButton!

    var shuffleButton: TransportButton!
    var backFifteenButton: TransportButton!
    var previousButton: TransportButton!
    var playPauseButton: TransportButton!
    var nextButton: TransportButton!
    var forwardFifteenButton: TransportButton!
    var repeatButton: TransportButton!

    let scrubber = MacScrubberView()
    let elapsedLabel = NSTextField(labelWithString: "0:00")
    let remainingLabel = NSTextField(labelWithString: "-0:00")
    var volumeButton: TransportButton!
    let volumeSlider = VolumeSlider()
    let volumeLabel = NSTextField(labelWithString: "")
    var volumeBeforeMute: Float?
    var equalizerButton: TransportButton!
    var equalizerPopover: NSPopover?

    var sleepCapsule: CapsuleButton!
    var shareCapsule: CapsuleButton!
    var lyricsCapsule: CapsuleButton!
    var queueCapsule: CapsuleButton!
    let routePicker = AVRoutePickerView()

    let lyricsColumn = NSView()
    let queueColumn = NSView()
    let lyricsPanel = LyricsPanelViewController()
    let queuePanel = QueuePanelViewController()
    var lyricsShown = NowPlayingLayout.lyricsShown
    var queueShown = NowPlayingLayout.queueShown
    var swapSides = NowPlayingLayout.swapSides
    var body: NSStackView!
    var swapCapsule: TransportButton!
    var lyricsWidthConstraint: NSLayoutConstraint?
    var queueWidthConstraint: NSLayoutConstraint?

    var stateCancellable: AnyCancellable?
    var progressCancellable: AnyCancellable?
    var chaseInFlight = false
    var pendingChaseTime: TimeInterval?
    var chaseGeneration = 0
    var currentPaletteKey: String?
    weak var paletteArtwork: NSImage?
    var currentTrackKey: String?
    var isBreathing = false

    weak var scrimViewRef: NSView?

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
        progressCancellable = viewModel.progressPublisher.sink { [weak self] progress in
            self?.applyProgress(progress)
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(queueChanged), name: AudioPlayer.queueDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(trackChangedForCount), name: AudioPlayer.trackDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(volumeDidChangeExternally), name: AudioPlayer.volumeDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(equalizerChanged), name: EqualizerEngine.stateDidChange, object: nil
        )
        // Restored from the reader's last session, not reset to closed.
        lyricsPanel.setActive(lyricsShown)
        queuePanel.setActive(queueShown)
        refreshCapsuleToggles()
        apply(viewModel.currentState)
        applyProgress(viewModel.currentProgress)
        modesChanged()
        sleepTimerChanged()
        queueChanged()
        refreshVolume()
        equalizerChanged()
        prefetchLyrics()
    }

    @objc func trackChangedForCount() { queueChanged() }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        view.window?.makeFirstResponder(view)
        backdrop.setPaused(false)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        equalizerPopover?.close()
        backdrop.setPaused(true)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        MidgarLog.info("NowPlayingViewController deinit", category: .ui)
    }

    override func cancelOperation(_ sender: Any?) {
        closeTapped()
    }

    func apply(_ state: NowPlayingViewModel.State) {
        let trackKey = "\(state.title)\u{0}\(state.artist)\u{0}\(state.albumTitle)"
        let trackChanged = trackKey != currentTrackKey
        if trackChanged {
            currentTrackKey = trackKey
            chaseGeneration += 1
            pendingChaseTime = nil
            scrubber.abortScrub()
            prefetchLyrics()
        }

        titleLabel.text = state.title.isEmpty ? String(localized: "Nothing Playing") : state.title
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

    func applyProgress(_ progress: NowPlayingViewModel.Progress) {
        scrubber.setProgress(current: progress.currentTime, duration: progress.duration)
        elapsedLabel.stringValue = progress.currentTimeFormatted
        remainingLabel.stringValue = progress.remainingTimeFormatted
    }

    func updatePalette(state: NowPlayingViewModel.State, animated: Bool) {
        let key = "\(state.albumTitle)\u{0}\(state.artist)"
        guard key != currentPaletteKey || (state.artwork != nil && state.artwork !== paletteArtwork) else { return }
        currentPaletteKey = key
        paletteArtwork = state.artwork
        ArtworkPaletteExtractor.palette(
            for: state.artwork,
            cacheKey: key,
            fallbackSeed: state.title.isEmpty ? "flaccy" : "\(state.albumTitle)|\(state.artist)"
        ) { [weak self] palette in
            guard let self, self.currentPaletteKey == key else { return }
            self.backdrop.apply(palette, animated: animated)
        }
    }

    func updateBreathing(paused: Bool) {
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

    func applyArtworkPlaceholder(seed: String) {
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

}
