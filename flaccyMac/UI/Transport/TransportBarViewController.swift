import AppKit
import AVFoundation
import AVKit

/// The floating glass transport bar pinned to the bottom of the main window:
/// transport cluster on the left, now-playing card with scrubber in the
/// center, volume / AirPlay / panel toggles on the right. Seeks while
/// dragging chase the pointer through `seekSmooth`, mirroring the iOS
/// scrubber's in-flight coalescing so the audio pipeline never queues seeks.
final class TransportBarViewController: NSViewController {

    private let player: AudioPlaying = AudioPlayer.shared

    private var shuffleButton: TransportButton!
    private var previousButton: TransportButton!
    private var playPauseButton: TransportButton!
    private var nextButton: TransportButton!
    private var repeatButton: TransportButton!
    private var loveButton: TransportButton!
    private var queueButton: TransportButton!
    private var lyricsButton: TransportButton!
    private var nowPlayingButton: TransportButton!
    private var sleepTimerButton: TransportButton!
    private let sleepCountdownLabel = NSTextField(labelWithString: "")

    private let artworkView = NSImageView()
    private let artworkContainer = NSView()
    private let artworkPlaceholder = CAGradientLayer()
    private let titleLabel = MacMarqueeLabel()
    private let artistLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let badgeContainer = NSView()
    private let scrubber = MacScrubberView()
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let remainingLabel = NSTextField(labelWithString: "-0:00")
    private let volumeSlider = VolumeSlider()
    private let routePicker = AVRoutePickerView()

    private var chaseInFlight = false
    private var pendingChaseTime: TimeInterval?
    private var chaseGeneration = 0
    private var currentArtworkKey: String?

    override func loadView() {
        let content = NSView()
        buildControls()

        let transportCluster = NSStackView(views: [
            shuffleButton, previousButton, playPauseButton, nextButton, repeatButton,
        ])
        transportCluster.orientation = .horizontal
        transportCluster.spacing = 2

        configureArtwork()
        configureNowPlayingCard()

        let timeline = NSStackView(views: [elapsedLabel, scrubber, remainingLabel])
        timeline.orientation = .horizontal
        timeline.spacing = 8

        let trackText = NSStackView(views: [titleRow(), artistLabel])
        trackText.orientation = .vertical
        trackText.alignment = .leading
        trackText.spacing = 0

        let cardTop = NSStackView(views: [artworkContainer, trackText, loveButton])
        cardTop.orientation = .horizontal
        cardTop.spacing = 10
        cardTop.alignment = .centerY

        let card = NSStackView(views: [cardTop, timeline])
        card.orientation = .vertical
        card.spacing = 2
        card.alignment = .leading

        configureVolume()
        let volumeIcon = NSImageView(image: NSImage(
            systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Volume"
        ) ?? NSImage())
        volumeIcon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        volumeIcon.contentTintColor = .secondaryLabelColor

        sleepCountdownLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        sleepCountdownLabel.textColor = .secondaryLabelColor
        sleepCountdownLabel.isHidden = true

        let rightCluster = NSStackView(views: [
            volumeIcon, volumeSlider, routePicker, sleepTimerButton, sleepCountdownLabel,
            queueButton, lyricsButton, nowPlayingButton,
        ])
        rightCluster.orientation = .horizontal
        rightCluster.spacing = 6
        rightCluster.alignment = .centerY

        let bar = NSStackView(views: [transportCluster, card, rightCluster])
        bar.orientation = .horizontal
        bar.spacing = 20
        bar.alignment = .centerY
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        bar.setHuggingPriority(.defaultLow, for: .horizontal)

        let glass = MacLiquidGlass.surface(hosting: bar, cornerRadius: 20)
        glass.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: content.topAnchor),
            glass.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            trackText.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            artworkContainer.widthAnchor.constraint(equalToConstant: 44),
            artworkContainer.heightAnchor.constraint(equalToConstant: 44),
            volumeSlider.widthAnchor.constraint(equalToConstant: 90),
            routePicker.widthAnchor.constraint(equalToConstant: 30),
            routePicker.heightAnchor.constraint(equalToConstant: 24),
            scrubber.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        view = content
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observePlayback()
        refreshEverything()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func buildControls() {
        shuffleButton = TransportButton(
            symbolName: "shuffle", pointSize: 13, accessibilityLabel: "Shuffle",
            target: self, action: #selector(toggleShuffle)
        )
        previousButton = TransportButton(
            symbolName: "backward.fill", pointSize: 15, accessibilityLabel: "Previous",
            target: self, action: #selector(previousTrack)
        )
        playPauseButton = TransportButton(
            symbolName: "play.fill", pointSize: 22, accessibilityLabel: "Play or pause",
            target: self, action: #selector(togglePlayPause)
        )
        playPauseButton.isProminent = true
        nextButton = TransportButton(
            symbolName: "forward.fill", pointSize: 15, accessibilityLabel: "Next",
            target: self, action: #selector(nextTrack)
        )
        repeatButton = TransportButton(
            symbolName: "repeat", pointSize: 13, accessibilityLabel: "Repeat",
            target: self, action: #selector(cycleRepeat)
        )
        loveButton = TransportButton(
            symbolName: "heart", pointSize: 13, accessibilityLabel: "Love on Last.fm",
            target: self, action: #selector(toggleLove)
        )
        queueButton = TransportButton(
            symbolName: "list.bullet", pointSize: 13, accessibilityLabel: "Toggle queue",
            target: self, action: #selector(toggleQueue)
        )
        lyricsButton = TransportButton(
            symbolName: "quote.bubble", pointSize: 13, accessibilityLabel: "Toggle lyrics",
            target: self, action: #selector(toggleLyrics)
        )
        nowPlayingButton = TransportButton(
            symbolName: "arrow.up.left.and.arrow.down.right", pointSize: 12,
            accessibilityLabel: "Now Playing",
            target: self, action: #selector(toggleNowPlaying)
        )
        sleepTimerButton = TransportButton(
            symbolName: "moon.zzz", pointSize: 13, accessibilityLabel: "Sleep timer",
            target: self, action: #selector(showSleepTimerMenu)
        )
    }

    private func configureArtwork() {
        artworkContainer.wantsLayer = true
        artworkContainer.layer?.cornerRadius = 8
        artworkContainer.layer?.cornerCurve = .continuous
        artworkContainer.layer?.masksToBounds = true
        artworkContainer.translatesAutoresizingMaskIntoConstraints = false
        artworkPlaceholder.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        artworkContainer.layer?.addSublayer(artworkPlaceholder)
        artworkView.imageScaling = .scaleProportionallyUpOrDown
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkContainer.addSubview(artworkView)
        NSLayoutConstraint.activate([
            artworkView.topAnchor.constraint(equalTo: artworkContainer.topAnchor),
            artworkView.leadingAnchor.constraint(equalTo: artworkContainer.leadingAnchor),
            artworkView.trailingAnchor.constraint(equalTo: artworkContainer.trailingAnchor),
            artworkView.bottomAnchor.constraint(equalTo: artworkContainer.bottomAnchor),
        ])
    }

    private func configureNowPlayingCard() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.heightAnchor.constraint(equalToConstant: 17).isActive = true

        artistLabel.font = .systemFont(ofSize: 11)
        artistLabel.textColor = .secondaryLabelColor
        artistLabel.lineBreakMode = .byTruncatingTail

        badgeLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        badgeLabel.textColor = .secondaryLabelColor
        badgeContainer.wantsLayer = true
        badgeContainer.layer?.borderColor = NSColor.tertiaryLabelColor.cgColor
        badgeContainer.layer?.borderWidth = 1
        badgeContainer.layer?.cornerRadius = 6
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.addSubview(badgeLabel)
        NSLayoutConstraint.activate([
            badgeLabel.leadingAnchor.constraint(equalTo: badgeContainer.leadingAnchor, constant: 5),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeContainer.trailingAnchor, constant: -5),
            badgeLabel.topAnchor.constraint(equalTo: badgeContainer.topAnchor, constant: 2),
            badgeLabel.bottomAnchor.constraint(equalTo: badgeContainer.bottomAnchor, constant: -2),
        ])

        for label in [elapsedLabel, remainingLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            label.textColor = .tertiaryLabelColor
        }

        scrubber.onScrub = { [weak self] time in
            self?.chaseSeek(to: time)
        }
        scrubber.onCommit = { [weak self] time in
            self?.player.seek(to: time)
        }
    }

    private func titleRow() -> NSView {
        let row = NSStackView(views: [titleLabel, badgeContainer])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func configureVolume() {
        volumeSlider.minValue = 0
        volumeSlider.maxValue = 1
        volumeSlider.controlSize = .small
        volumeSlider.doubleValue = Double(player.volume)
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
        volumeSlider.toolTip = "Volume"
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        routePicker.translatesAutoresizingMaskIntoConstraints = false
    }

    private func observePlayback() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(trackChanged), name: AudioPlayer.trackDidChange, object: nil)
        center.addObserver(self, selector: #selector(stateChanged), name: AudioPlayer.playbackStateDidChange, object: nil)
        center.addObserver(self, selector: #selector(progressChanged), name: AudioPlayer.playbackProgressDidChange, object: nil)
        center.addObserver(self, selector: #selector(modesChanged), name: AudioPlayer.shuffleRepeatDidChange, object: nil)
        center.addObserver(self, selector: #selector(queueChanged), name: AudioPlayer.queueDidChange, object: nil)
        center.addObserver(self, selector: #selector(lovedChanged), name: LovedTracksService.didChange, object: nil)
        center.addObserver(self, selector: #selector(volumeDidChangeExternally), name: AudioPlayer.volumeDidChange, object: nil)
        center.addObserver(self, selector: #selector(sleepTimerChanged), name: AudioPlayer.sleepTimerDidUpdate, object: nil)
    }

    private func refreshEverything() {
        trackChanged()
        stateChanged()
        modesChanged()
        queueChanged()
        sleepTimerChanged()
    }

    @objc private func sleepTimerChanged() {
        if let remaining = AudioPlayer.shared.sleepTimerRemaining {
            let total = Int(remaining)
            sleepCountdownLabel.stringValue = String(format: "%d:%02d", total / 60, total % 60)
            sleepCountdownLabel.isHidden = false
            sleepTimerButton.isActiveToggle = true
            sleepTimerButton.setSymbol("moon.zzz.fill", pointSize: 13)
        } else if AudioPlayer.shared.sleepAtEndOfTrack {
            sleepCountdownLabel.stringValue = "end"
            sleepCountdownLabel.isHidden = false
            sleepTimerButton.isActiveToggle = true
            sleepTimerButton.setSymbol("moon.zzz.fill", pointSize: 13)
        } else {
            sleepCountdownLabel.isHidden = true
            sleepTimerButton.isActiveToggle = false
            sleepTimerButton.setSymbol("moon.zzz", pointSize: 13)
        }
    }

    @objc private func showSleepTimerMenu() {
        let menu = SleepTimerMenuBuilder.build()
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: sleepTimerButton.bounds.height + 6),
            in: sleepTimerButton
        )
    }

    @objc private func trackChanged() {
        chaseGeneration += 1
        pendingChaseTime = nil
        scrubber.abortScrub()

        guard let track = player.currentTrack else {
            titleLabel.text = "Nothing Playing"
            artistLabel.stringValue = "Pick an album to start listening"
            badgeContainer.isHidden = true
            loveButton.isEnabled = false
            applyArtworkPlaceholder(seed: "flaccy")
            progressChanged()
            return
        }
        loveButton.isEnabled = true
        titleLabel.text = track.title
        artistLabel.stringValue = track.artist
        artistLabel.toolTip = "\(track.artist) — \(track.albumTitle)"
        badgeLabel.stringValue = track.qualityBadge ?? ""
        badgeContainer.isHidden = track.qualityBadge == nil
        refreshArtwork(for: track)
        refreshLove()
        progressChanged()
    }

    @objc private func stateChanged() {
        playPauseButton.setSymbol(player.isPlaying ? "pause.fill" : "play.fill", pointSize: 22)
    }

    @objc private func progressChanged() {
        let current = player.currentTime
        let duration = player.duration
        scrubber.setProgress(current: current, duration: duration)
        elapsedLabel.stringValue = Self.format(current)
        remainingLabel.stringValue = "-\(Self.format(max(0, duration - current)))"
    }

    @objc private func modesChanged() {
        shuffleButton.isActiveToggle = player.shuffleEnabled
        repeatButton.isActiveToggle = player.repeatMode != .off
        repeatButton.setSymbol(player.repeatMode == .one ? "repeat.1" : "repeat", pointSize: 13)
    }

    @objc private func queueChanged() {
        let hasQueue = !player.queue.isEmpty
        previousButton.isEnabled = hasQueue
        nextButton.isEnabled = hasQueue
        playPauseButton.isEnabled = hasQueue
        shuffleButton.isEnabled = hasQueue
        repeatButton.isEnabled = hasQueue
        if player.currentTrack == nil { trackChanged() }
    }

    @objc private func lovedChanged() {
        refreshLove()
    }

    @objc private func volumeDidChangeExternally() {
        volumeSlider.doubleValue = Double(player.volume)
    }

    private func refreshLove() {
        guard let track = player.currentTrack else {
            loveButton.setSymbol("heart", pointSize: 13)
            loveButton.isActiveToggle = false
            return
        }
        let loved = LovedTracksService.shared.isLoved(track: track)
        loveButton.setSymbol(loved ? "heart.fill" : "heart", pointSize: 13)
        loveButton.contentTintColor = loved
            ? NSColor(red: 1.0, green: 0.28, blue: 0.42, alpha: 1)
            : .secondaryLabelColor
    }

    private func refreshArtwork(for track: Track) {
        let key = "\(track.albumTitle)\u{0}\(track.artist)"
        currentArtworkKey = key
        if let cached = track.artwork
            ?? AlbumArtworkCache.shared.thumbnail(forAlbum: track.albumTitle, artist: track.artist) {
            showArtwork(cached)
            return
        }
        applyArtworkPlaceholder(seed: "\(track.albumTitle)|\(track.artist)")
        AlbumArtworkCache.shared.loadThumbnail(forAlbum: track.albumTitle, artist: track.artist) { [weak self] image in
            guard let self, self.currentArtworkKey == key, let image else { return }
            self.showArtwork(image)
        }
    }

    private func showArtwork(_ image: NSImage) {
        artworkView.image = image
        artworkPlaceholder.isHidden = true
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

    /// Coalesces drag-seeks: at most one seek is in flight, the newest target
    /// waits as the single pending value, and a track change invalidates the
    /// generation so a stale completion can never fire a leftover seek.
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

    @objc private func togglePlayPause() { player.togglePlayPause() }
    @objc private func nextTrack() { player.nextTrack() }
    @objc private func previousTrack() { player.previousTrack() }
    @objc private func toggleShuffle() { player.toggleShuffle() }
    @objc private func cycleRepeat() { player.cycleRepeatMode() }

    @objc private func toggleLove() {
        guard let track = player.currentTrack else { return }
        Task { _ = await LovedTracksService.shared.toggleLove(track: track) }
    }

    @objc private func volumeChanged() {
        player.volume = Float(volumeSlider.doubleValue)
    }

    @objc private func toggleQueue() {
        NotificationCenter.default.post(name: .flaccyToggleQueue, object: nil)
    }

    @objc private func toggleLyrics() {
        NotificationCenter.default.post(name: .flaccyToggleLyrics, object: nil)
    }

    @objc private func toggleNowPlaying() {
        NotificationCenter.default.post(name: .flaccyToggleNowPlaying, object: nil)
    }

    private static func format(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
