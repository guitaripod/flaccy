import AVFoundation
import AVKit
import Combine
import MediaPlayer
import UIKit

final class NowPlayingViewController: UIViewController, SonglinkShareable {

    private let viewModel = NowPlayingViewModel()
    private var cancellables = Set<AnyCancellable>()

    private let backdropView = NowPlayingBackdropView()
    private let scrimLayer = CAGradientLayer()
    private let artworkView = UIImageView()
    private let artworkContainer = UIView()
    private let titleMarquee = MarqueeLabel()
    private let artistAvatarButton = UIButton(type: .custom)
    private let artistButton = UIButton(type: .system)
    private let dashLabel = UILabel()
    private let albumLabel = UILabel()
    private let playingFromLabel = UILabel()
    private let progressSlider = UISlider()
    private let currentTimeLabel = UILabel()
    private let remainingTimeLabel = UILabel()
    private let scrubBubble = UIView()
    private let scrubBubbleLabel = UILabel()
    private let skipBackButton = UIButton(type: .system)
    private let previousButton = UIButton(type: .system)
    private let playPauseButton = UIButton(type: .custom)
    private let playPauseIconView = UIImageView()
    private let nextButton = UIButton(type: .system)
    private let skipForwardButton = UIButton(type: .system)
    private let volumeView = MPVolumeView()
    private let shuffleButton = UIButton(type: .system)
    private let repeatButton = UIButton(type: .system)
    private let airplayButton = AVRoutePickerView(frame: .zero)
    private let sleepTimerButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private let lyricsButton = UIButton(type: .system)
    private let queueButton = UIButton(type: .system)

    private var shuffleCapsule: GlassCapsule?
    private var repeatCapsule: GlassCapsule?
    private var sleepTimerCapsule: GlassCapsule?
    private var queueCapsule: GlassCapsule?
    private var actionCapsules: [UIView] = []
    private let actionRowContainer = UIStackView()

    private var artistImageTask: Task<Void, Never>?
    private var currentArtistKey: String?

    private var isSliderDragging = false
    private var isSeeking = false
    private var chaseTime: TimeInterval = 0
    private var lastTrackKey: String?
    private var lastIsPlaying: Bool?
    private var hasAppliedInitialState = false
    private var hasAnimatedAppearance = false
    private var isSwipeAnimating = false
    private var breatheAnimator: UIViewPropertyAnimator?
    private var artworkRestScale: CGFloat = 1

    private lazy var smallThumb = makeThumbImage(size: 6)
    private lazy var largeThumb = makeThumbImage(size: 20)

    private static let pausedArtworkScale: CGFloat = 0.86
    private static let playIconConfig = UIImage.SymbolConfiguration(pointSize: 44, weight: .bold)

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        configureSheet()
        setupBackdrop()
        setupUI()
        setupAccessibilityOrder()
        bindViewModel()
        applyState(viewModel.currentState)
        hasAppliedInitialState = true
        updateShuffleRepeatState()
        updateSleepTimerButton()
        updateQueueBadge()

        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.relayoutActionRow()
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(shuffleRepeatDidChange), name: AudioPlayer.shuffleRepeatDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(queueDidChange), name: AudioPlayer.queueDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(pauseBackdrop), name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(resumeBackdrop), name: UIApplication.willEnterForegroundNotification, object: nil
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        resumeBackdrop()
        prepareAppearanceAnimationIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        runAppearanceAnimationIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        backdropView.setPaused(true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        backdropView.frame = view.bounds
        scrimLayer.frame = view.bounds
        artworkContainer.layer.shadowPath = UIBezierPath(
            roundedRect: artworkContainer.bounds, cornerRadius: 20
        ).cgPath
    }

    private func configureSheet() {
        sheetPresentationController?.prefersGrabberVisible = true
        sheetPresentationController?.preferredCornerRadius = 32
    }

    private func setupBackdrop() {
        backdropView.frame = view.bounds
        view.addSubview(backdropView)
        scrimLayer.colors = [
            UIColor.black.withAlphaComponent(0.35).cgColor,
            UIColor.black.withAlphaComponent(0.12).cgColor,
            UIColor.black.withAlphaComponent(0.45).cgColor,
        ]
        scrimLayer.locations = [0, 0.45, 1]
        view.layer.addSublayer(scrimLayer)
    }

    private func setupUI() {
        setupArtwork()
        setupInfoBlock()
        setupScrubber()
        setupTransport()

        let infoStack = UIStackView(arrangedSubviews: [titleMarquee, makeArtistAlbumRow(), playingFromLabel])
        infoStack.axis = .vertical
        infoStack.spacing = 4

        let sliderStack = UIStackView(arrangedSubviews: [progressSlider, makeTimeRow()])
        sliderStack.axis = .vertical
        sliderStack.spacing = 4

        let transportStack = UIStackView(arrangedSubviews: [
            skipBackButton, previousButton, playPauseButton, nextButton, skipForwardButton,
        ])
        transportStack.distribution = .equalSpacing
        transportStack.alignment = .center

        let mainStack = UIStackView(arrangedSubviews: [
            artworkContainer, infoStack, sliderStack, transportStack, makeVolumeRow(), makeActionRow(),
        ])
        mainStack.axis = .vertical
        mainStack.spacing = 22
        mainStack.setCustomSpacing(26, after: artworkContainer)
        mainStack.setCustomSpacing(28, after: transportStack)
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mainStack)

        setupScrubBubble()

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            mainStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            mainStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            mainStack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            artworkView.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, multiplier: 0.42),
        ])
    }

    private func setupArtwork() {
        artworkContainer.layer.shadowColor = UIColor.black.cgColor
        artworkContainer.layer.shadowOpacity = 0.45
        artworkContainer.layer.shadowOffset = CGSize(width: 0, height: 14)
        artworkContainer.layer.shadowRadius = 34

        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.layer.cornerRadius = 20
        artworkView.layer.cornerCurve = .continuous
        artworkView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        artworkView.image = UIImage(systemName: "music.note")
        artworkView.tintColor = UIColor.white.withAlphaComponent(0.35)
        artworkView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 48, weight: .ultraLight)
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkContainer.addSubview(artworkView)
        artworkContainer.isAccessibilityElement = true
        artworkContainer.accessibilityLabel = "Album artwork"
        artworkContainer.accessibilityHint = "Swipe left or right with two fingers to change track"

        let artworkSquare = artworkView.heightAnchor.constraint(equalTo: artworkView.widthAnchor)
        artworkSquare.priority = .defaultHigh
        artworkContainer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        NSLayoutConstraint.activate([
            artworkView.topAnchor.constraint(equalTo: artworkContainer.topAnchor),
            artworkView.leadingAnchor.constraint(equalTo: artworkContainer.leadingAnchor),
            artworkView.trailingAnchor.constraint(equalTo: artworkContainer.trailingAnchor),
            artworkView.bottomAnchor.constraint(equalTo: artworkContainer.bottomAnchor),
            artworkSquare,
        ])

        artworkContainer.isUserInteractionEnabled = true
        let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeLeft))
        swipeLeft.direction = .left
        artworkContainer.addGestureRecognizer(swipeLeft)
        let swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeRight))
        swipeRight.direction = .right
        artworkContainer.addGestureRecognizer(swipeRight)

        let tilt = UILongPressGestureRecognizer(target: self, action: #selector(handleTilt(_:)))
        tilt.minimumPressDuration = 0.18
        artworkContainer.addGestureRecognizer(tilt)

        artworkContainer.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    private func setupInfoBlock() {
        titleMarquee.font = .scaled(.title3, size: 21, weight: .bold)
        titleMarquee.textColor = .white
        titleMarquee.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleMarquee.addInteraction(UIContextMenuInteraction(delegate: self))

        artistAvatarButton.contentMode = .scaleAspectFill
        artistAvatarButton.imageView?.contentMode = .scaleAspectFill
        artistAvatarButton.clipsToBounds = true
        artistAvatarButton.layer.cornerRadius = 11
        artistAvatarButton.isHidden = true
        artistAvatarButton.accessibilityLabel = "Artist photo"
        artistAvatarButton.accessibilityHint = "Shows the artist's albums"
        artistAvatarButton.addAction(UIAction { [weak self] _ in self?.navigateToArtist() }, for: .touchUpInside)
        NSLayoutConstraint.activate([
            artistAvatarButton.widthAnchor.constraint(equalToConstant: 22),
            artistAvatarButton.heightAnchor.constraint(equalToConstant: 22),
        ])

        artistButton.titleLabel?.font = .scaled(.callout, size: 16, weight: .semibold)
        artistButton.titleLabel?.adjustsFontForContentSizeCategory = true
        artistButton.setTitleColor(.white.withAlphaComponent(0.85), for: .normal)
        artistButton.contentHorizontalAlignment = .leading
        artistButton.setContentHuggingPriority(.required, for: .horizontal)
        artistButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        artistButton.accessibilityHint = "Shows the artist's albums"
        artistButton.addAction(UIAction { [weak self] _ in self?.navigateToArtist() }, for: .touchUpInside)

        dashLabel.text = " — "
        dashLabel.font = .scaled(.callout, size: 16, weight: .regular)
        dashLabel.adjustsFontForContentSizeCategory = true
        dashLabel.textColor = .white.withAlphaComponent(0.55)
        dashLabel.setContentHuggingPriority(.required, for: .horizontal)
        dashLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        albumLabel.font = .scaled(.callout, size: 16, weight: .regular)
        albumLabel.adjustsFontForContentSizeCategory = true
        albumLabel.textColor = .white.withAlphaComponent(0.55)
        albumLabel.lineBreakMode = .byTruncatingTail
        albumLabel.addInteraction(UIContextMenuInteraction(delegate: self))
        albumLabel.isUserInteractionEnabled = true

        playingFromLabel.font = .scaled(.caption1, size: 12, weight: .regular)
        playingFromLabel.adjustsFontForContentSizeCategory = true
        playingFromLabel.textColor = .white.withAlphaComponent(0.4)
        playingFromLabel.isHidden = true
    }

    private func makeArtistAlbumRow() -> UIStackView {
        let row = UIStackView(arrangedSubviews: [artistAvatarButton, artistButton, dashLabel, albumLabel])
        row.spacing = 0
        row.setCustomSpacing(7, after: artistAvatarButton)
        row.alignment = .center
        return row
    }

    private func setupScrubber() {
        progressSlider.minimumTrackTintColor = .white
        progressSlider.maximumTrackTintColor = .white.withAlphaComponent(0.25)
        progressSlider.setThumbImage(smallThumb, for: .normal)
        progressSlider.setThumbImage(largeThumb, for: .highlighted)
        progressSlider.accessibilityLabel = "Playback position"
        progressSlider.addTarget(self, action: #selector(sliderTouchDown), for: .touchDown)
        progressSlider.addTarget(self, action: #selector(sliderTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        progressSlider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)

        let timeFont = UIFontMetrics(forTextStyle: .caption2)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 11, weight: .medium), maximumPointSize: 18)
        for label in [currentTimeLabel, remainingTimeLabel] {
            label.font = timeFont
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .white.withAlphaComponent(0.5)
        }
        currentTimeLabel.text = "0:00"
        remainingTimeLabel.text = "-0:00"
        remainingTimeLabel.textAlignment = .right
    }

    private func makeTimeRow() -> UIStackView {
        UIStackView(arrangedSubviews: [currentTimeLabel, UIView(), remainingTimeLabel])
    }

    private func setupScrubBubble() {
        scrubBubble.backgroundColor = UIColor.white.withAlphaComponent(0.95)
        scrubBubble.layer.cornerRadius = 12
        scrubBubble.layer.cornerCurve = .continuous
        scrubBubble.alpha = 0
        scrubBubbleLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        scrubBubbleLabel.textColor = .black
        scrubBubbleLabel.textAlignment = .center
        scrubBubble.addSubview(scrubBubbleLabel)
        view.addSubview(scrubBubble)
    }

    private func setupTransport() {
        let skipConfig = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        let transportConfig = UIImage.SymbolConfiguration(pointSize: 30, weight: .bold)

        skipBackButton.setImage(UIImage(systemName: "gobackward.15", withConfiguration: skipConfig), for: .normal)
        skipBackButton.tintColor = .white.withAlphaComponent(0.85)
        skipBackButton.accessibilityLabel = "Skip back 15 seconds"
        skipBackButton.addAction(UIAction { [weak self] _ in self?.skip(by: -15) }, for: .touchUpInside)

        previousButton.setImage(UIImage(systemName: "backward.fill", withConfiguration: transportConfig), for: .normal)
        previousButton.tintColor = .white
        previousButton.accessibilityLabel = "Previous track"
        previousButton.addAction(UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self?.viewModel.previousTrack()
        }, for: .touchUpInside)

        playPauseIconView.image = UIImage(systemName: "play.fill", withConfiguration: Self.playIconConfig)
        playPauseIconView.tintColor = .white
        playPauseIconView.contentMode = .center
        playPauseIconView.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.addSubview(playPauseIconView)
        playPauseButton.accessibilityLabel = "Play"
        playPauseButton.addAction(UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            self?.viewModel.togglePlayPause()
        }, for: .touchUpInside)

        nextButton.setImage(UIImage(systemName: "forward.fill", withConfiguration: transportConfig), for: .normal)
        nextButton.tintColor = .white
        nextButton.accessibilityLabel = "Next track"
        nextButton.addAction(UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self?.viewModel.nextTrack()
        }, for: .touchUpInside)

        skipForwardButton.setImage(UIImage(systemName: "goforward.15", withConfiguration: skipConfig), for: .normal)
        skipForwardButton.tintColor = .white.withAlphaComponent(0.85)
        skipForwardButton.accessibilityLabel = "Skip forward 15 seconds"
        skipForwardButton.addAction(UIAction { [weak self] _ in self?.skip(by: 15) }, for: .touchUpInside)

        NSLayoutConstraint.activate([
            playPauseButton.widthAnchor.constraint(equalToConstant: 72),
            playPauseButton.heightAnchor.constraint(equalToConstant: 72),
            playPauseIconView.centerXAnchor.constraint(equalTo: playPauseButton.centerXAnchor),
            playPauseIconView.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
        ])
    }

    private func makeVolumeRow() -> UIStackView {
        let glyphConfig = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let minGlyph = UIImageView(image: UIImage(systemName: "speaker.fill", withConfiguration: glyphConfig))
        let maxGlyph = UIImageView(image: UIImage(systemName: "speaker.wave.3.fill", withConfiguration: glyphConfig))
        for glyph in [minGlyph, maxGlyph] {
            glyph.tintColor = .white.withAlphaComponent(0.5)
            glyph.setContentHuggingPriority(.required, for: .horizontal)
        }
        volumeView.tintColor = .white
        volumeView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [minGlyph, volumeView, maxGlyph])
        row.spacing = 12
        row.alignment = .center
        row.accessibilityLabel = "Volume"
        return row
    }

    private func makeActionRow() -> UIStackView {
        configureActionButtons()

        let shuffle = GlassCapsule(hosting: shuffleButton)
        let repeats = GlassCapsule(hosting: repeatButton)
        let sleep = GlassCapsule(hosting: sleepTimerButton)
        let queue = GlassCapsule(hosting: queueButton)
        shuffleCapsule = shuffle
        repeatCapsule = repeats
        sleepTimerCapsule = sleep
        queueCapsule = queue

        actionCapsules = [
            shuffle, repeats, GlassCapsule(hosting: airplayButton), sleep,
            GlassCapsule(hosting: shareButton), GlassCapsule(hosting: lyricsButton), queue,
        ]
        actionRowContainer.axis = .vertical
        actionRowContainer.spacing = 8
        relayoutActionRow()
        return actionRowContainer
    }

    /// Lays the capsules out as a single equal-width row, splitting into two
    /// rows at accessibility text sizes so they never overflow the width.
    private func relayoutActionRow() {
        for view in actionRowContainer.arrangedSubviews {
            view.removeFromSuperview()
        }
        let wraps = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        let groups: [[UIView]] = wraps
            ? [Array(actionCapsules.prefix(4)), Array(actionCapsules.suffix(3))]
            : [actionCapsules]
        for group in groups {
            let row = UIStackView(arrangedSubviews: group)
            row.distribution = .fillEqually
            row.spacing = 8
            actionRowContainer.addArrangedSubview(row)
        }
    }

    private func configureActionButtons() {
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)

        shuffleButton.setImage(UIImage(systemName: "shuffle", withConfiguration: iconConfig), for: .normal)
        shuffleButton.accessibilityLabel = "Shuffle"
        shuffleButton.addAction(UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            AudioPlayer.shared.toggleShuffle()
            self?.updateShuffleRepeatState()
        }, for: .touchUpInside)

        repeatButton.setImage(UIImage(systemName: "repeat", withConfiguration: iconConfig), for: .normal)
        repeatButton.accessibilityLabel = "Repeat"
        repeatButton.addAction(UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            AudioPlayer.shared.cycleRepeatMode()
            self?.updateShuffleRepeatState()
        }, for: .touchUpInside)

        airplayButton.tintColor = .white.withAlphaComponent(0.7)
        airplayButton.activeTintColor = .white
        airplayButton.accessibilityLabel = "AirPlay"

        sleepTimerButton.setImage(UIImage(systemName: "moon.zzz", withConfiguration: iconConfig), for: .normal)
        sleepTimerButton.accessibilityLabel = "Sleep timer"
        sleepTimerButton.addAction(UIAction { [weak self] _ in self?.showSleepTimerSheet() }, for: .touchUpInside)
        sleepTimerButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.sleepTimerMenuActions() ?? [])
            }
        ])

        shareButton.setImage(UIImage(systemName: "square.and.arrow.up", withConfiguration: iconConfig), for: .normal)
        shareButton.accessibilityLabel = "Share"
        shareButton.addAction(UIAction { [weak self] _ in
            guard let self, let track = AudioPlayer.shared.currentTrack else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self.shareTrackViaSonglink(title: track.title, artist: track.artist, from: self.view)
        }, for: .touchUpInside)
        shareButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.shareMenuActions() ?? [])
            }
        ])

        lyricsButton.setImage(UIImage(systemName: "text.quote", withConfiguration: iconConfig), for: .normal)
        lyricsButton.accessibilityLabel = "Lyrics"
        lyricsButton.addAction(UIAction { [weak self] _ in self?.presentLyrics() }, for: .touchUpInside)

        queueButton.setImage(UIImage(systemName: "list.bullet", withConfiguration: iconConfig), for: .normal)
        queueButton.accessibilityLabel = "Queue"
        queueButton.addAction(UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self?.presentQueue()
        }, for: .touchUpInside)

        for button in [shuffleButton, repeatButton, sleepTimerButton, shareButton, lyricsButton, queueButton] {
            button.tintColor = .white.withAlphaComponent(0.7)
        }
    }

    private func sleepTimerMenuActions() -> [UIMenuElement] {
        var actions: [UIMenuElement] = [15, 30, 45, 60].map { minutes in
            UIAction(title: "\(minutes) minutes", image: UIImage(systemName: "timer")) { [weak self] _ in
                AudioPlayer.shared.setSleepTimer(minutes: minutes)
                self?.updateSleepTimerButton()
            }
        }
        actions.append(UIAction(title: "End of Track", image: UIImage(systemName: "forward.end")) { [weak self] _ in
            AudioPlayer.shared.setSleepTimerEndOfTrack()
            self?.updateSleepTimerButton()
        })
        if AudioPlayer.shared.sleepTimerRemaining != nil || AudioPlayer.shared.sleepAtEndOfTrack {
            actions.append(UIAction(title: "Cancel Timer", image: UIImage(systemName: "xmark.circle"), attributes: .destructive) { [weak self] _ in
                AudioPlayer.shared.cancelSleepTimer()
                self?.updateSleepTimerButton()
            })
        }
        return actions
    }

    private func shareMenuActions() -> [UIMenuElement] {
        guard let track = AudioPlayer.shared.currentTrack else { return [] }
        var actions: [UIMenuElement] = [
            UIAction(title: "Share Track", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                guard let self else { return }
                self.shareTrackViaSonglink(title: track.title, artist: track.artist, from: self.view)
            },
            UIAction(title: "Copy Songlink", image: UIImage(systemName: "link")) { [weak self] _ in
                self?.copySonglink(title: track.title, artist: track.artist)
            },
        ]
        if let artwork = artworkView.image, artworkView.contentMode == .scaleAspectFill {
            actions.append(UIAction(title: "Share Artwork", image: UIImage(systemName: "photo")) { [weak self] _ in
                self?.shareArtworkImage(artwork)
            })
        }
        return actions
    }

    private func copySonglink(title: String, artist: String) {
        Task { [weak self] in
            guard let result = await SonglinkService.shared.lookup(title: title, artist: artist) else {
                if let self {
                    ToastView.show("Couldn't find a Songlink for this track", in: self.view, style: .error)
                }
                return
            }
            UIPasteboard.general.url = result.pageURL
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if let self {
                ToastView.show("Songlink copied", in: self.view, style: .success)
            }
        }
    }

    private func shareArtworkImage(_ image: UIImage) {
        let activity = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = artworkContainer
        present(activity, animated: true)
    }

    private func setupAccessibilityOrder() {
        view.accessibilityElements = [
            artworkContainer, titleMarquee, artistAvatarButton, artistButton, albumLabel, playingFromLabel,
            progressSlider, currentTimeLabel, remainingTimeLabel,
            skipBackButton, previousButton, playPauseButton, nextButton, skipForwardButton,
            volumeView,
            shuffleButton, repeatButton, airplayButton, sleepTimerButton, shareButton, lyricsButton, queueButton,
        ]
    }

    private func bindViewModel() {
        viewModel.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.applyState(state) }
            .store(in: &cancellables)
    }

    private func applyState(_ state: NowPlayingViewModel.State) {
        let trackKey = "\(state.title)\0\(state.artist)\0\(state.albumTitle)"
        if trackKey != lastTrackKey {
            lastTrackKey = trackKey
            applyTrackMetadata(state)
        }
        if state.isPlaying != lastIsPlaying {
            lastIsPlaying = state.isPlaying
            applyPlaybackState(isPlaying: state.isPlaying)
        }
        if !isSliderDragging {
            progressSlider.maximumValue = Float(state.duration)
            progressSlider.value = Float(state.currentTime)
            currentTimeLabel.text = state.currentTimeFormatted
            remainingTimeLabel.text = state.remainingTimeFormatted
        }
    }

    private func applyTrackMetadata(_ state: NowPlayingViewModel.State) {
        titleMarquee.text = state.title
        artistButton.setTitle(state.artist, for: .normal)
        albumLabel.text = state.albumTitle

        let hasArtist = !state.artist.isEmpty
        let hasAlbum = !state.albumTitle.isEmpty
        dashLabel.isHidden = !(hasArtist && hasAlbum)
        playingFromLabel.text = hasAlbum ? "Playing from \(state.albumTitle)" : ""
        playingFromLabel.isHidden = !hasAlbum

        setArtwork(state.artwork)
        updateBackdropPalette(artwork: state.artwork, state: state)
        updateArtistImage(artist: state.artist)
    }

    /// Resolves the artist photo off-main and applies it to the ambient
    /// backdrop layer and avatar, skipping redundant fetches for the same artist.
    private func updateArtistImage(artist: String) {
        let key = artist.lowercased()
        guard key != currentArtistKey else { return }
        currentArtistKey = key
        artistImageTask?.cancel()

        guard !artist.isEmpty else {
            applyArtistImage(nil)
            return
        }
        artistImageTask = Task { [weak self] in
            let image = await ArtistImageService.shared.image(for: artist)
            guard !Task.isCancelled, let self, self.currentArtistKey == key else { return }
            self.applyArtistImage(image)
        }
    }

    private func applyArtistImage(_ image: UIImage?) {
        backdropView.setArtistImage(image, animated: hasAppliedInitialState)
        let showAvatar = image != nil
        artistAvatarButton.setImage(image, for: .normal)
        guard artistAvatarButton.isHidden == showAvatar else { return }
        let update = { self.artistAvatarButton.isHidden = !showAvatar }
        if hasAppliedInitialState, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.2, animations: update)
        } else {
            update()
        }
    }

    private func setArtwork(_ image: UIImage?) {
        let update = { [self] in
            if let image {
                artworkView.contentMode = .scaleAspectFill
                artworkView.image = image
            } else {
                artworkView.contentMode = .center
                artworkView.image = UIImage(systemName: "music.note")
            }
        }
        if hasAppliedInitialState, !isSwipeAnimating, !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(with: artworkView, duration: 0.22, options: [.transitionCrossDissolve, .allowUserInteraction], animations: update)
        } else {
            update()
        }
    }

    private func updateBackdropPalette(artwork: UIImage?, state: NowPlayingViewModel.State) {
        let cacheKey = "\(state.albumTitle)\0\(state.artist)"
        let seed = state.title.isEmpty ? "flaccy" : "\(state.title)\(state.artist)"
        let animated = hasAppliedInitialState
        ArtworkPaletteExtractor.palette(for: artwork, cacheKey: cacheKey, fallbackSeed: seed) { [weak self] palette in
            self?.backdropView.apply(palette, animated: animated)
        }
    }

    private func applyPlaybackState(isPlaying: Bool) {
        let iconName = isPlaying ? "pause.fill" : "play.fill"
        let image = UIImage(systemName: iconName, withConfiguration: Self.playIconConfig)!
        if hasAppliedInitialState {
            playPauseIconView.setSymbolImage(image, contentTransition: .replace)
        } else {
            playPauseIconView.image = image
        }
        playPauseButton.accessibilityLabel = isPlaying ? "Pause" : "Play"
        animateBreathe(isPlaying: isPlaying)
    }

    /// Springs the artwork card between full scale while playing and a dimmed,
    /// smaller presentation while paused; skipped entirely under Reduce Motion.
    private func animateBreathe(isPlaying: Bool) {
        guard !UIAccessibility.isReduceMotionEnabled else {
            artworkContainer.transform = .identity
            artworkView.alpha = 1
            return
        }
        breatheAnimator?.stopAnimation(true)
        let scale = isPlaying ? 1.0 : Self.pausedArtworkScale
        artworkRestScale = scale
        let animator = UIViewPropertyAnimator(duration: 0.42, dampingRatio: 0.76) { [self] in
            artworkContainer.transform = CGAffineTransform(scaleX: scale, y: scale)
            artworkView.alpha = isPlaying ? 1 : 0.75
        }
        animator.startAnimation()
        breatheAnimator = animator
    }

    private func skip(by seconds: TimeInterval) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let target = min(max(0, AudioPlayer.shared.currentTime + seconds), AudioPlayer.shared.duration)
        viewModel.seek(to: target)
    }

    private func makeThumbImage(size: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
        }
    }

    private func updateShuffleRepeatState() {
        let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let animated = hasAppliedInitialState
        let shuffleActive = AudioPlayer.shared.shuffleEnabled
        shuffleButton.tintColor = shuffleActive ? .white : .white.withAlphaComponent(0.55)
        shuffleButton.accessibilityValue = shuffleActive ? "On" : "Off"
        shuffleCapsule?.setActive(shuffleActive, animated: animated)

        switch AudioPlayer.shared.repeatMode {
        case .off:
            repeatButton.setImage(UIImage(systemName: "repeat", withConfiguration: config), for: .normal)
            repeatButton.tintColor = .white.withAlphaComponent(0.55)
            repeatButton.accessibilityValue = "Off"
            repeatCapsule?.setActive(false, animated: animated)
            repeatCapsule?.setBadge(nil)
        case .all:
            repeatButton.setImage(UIImage(systemName: "repeat", withConfiguration: config), for: .normal)
            repeatButton.tintColor = .white
            repeatButton.accessibilityValue = "All"
            repeatCapsule?.setActive(true, animated: animated)
            repeatCapsule?.setBadge("ALL")
        case .one:
            repeatButton.setImage(UIImage(systemName: "repeat.1", withConfiguration: config), for: .normal)
            repeatButton.tintColor = .white
            repeatButton.accessibilityValue = "One"
            repeatCapsule?.setActive(true, animated: animated)
            repeatCapsule?.setBadge("1")
        }
    }

    private func updateQueueBadge() {
        let count = AudioPlayer.shared.queue.count
        queueCapsule?.setBadge(count > 1 ? (count > 99 ? "99+" : "\(count)") : nil)
        queueButton.accessibilityValue = count > 0 ? "\(count) tracks" : nil
    }

    @objc private func queueDidChange() {
        updateQueueBadge()
    }

    private func presentQueue() {
        let queueVC = QueueViewController()
        let nav = UINavigationController(rootViewController: queueVC)
        nav.modalPresentationStyle = .pageSheet
        present(nav, animated: true)
    }

    private func presentLyrics() {
        guard let track = AudioPlayer.shared.currentTrack else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let vc = LyricsViewController(track: track.title, artist: track.artist, album: track.albumTitle)
        vc.modalPresentationStyle = .fullScreen
        present(vc, animated: true)
    }

    private func navigateToArtist() {
        guard let track = AudioPlayer.shared.currentTrack else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let artistAlbums = Library.shared.albums.filter { $0.artist == track.artist }
        dismissAndPush(ArtistDetailViewController(artistName: track.artist, albums: artistAlbums))
    }

    private func navigateToAlbum() {
        guard let track = AudioPlayer.shared.currentTrack,
              let album = Library.shared.albums.first(where: {
                  $0.title == track.albumTitle && $0.artist == track.artist
              })
        else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        dismissAndPush(AlbumDetailViewController(album: album))
    }

    private func dismissAndPush(_ viewController: UIViewController) {
        dismiss(animated: true) {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let rootVC = scene.windows.first?.rootViewController,
                  let nav = rootVC.children.compactMap({ $0 as? UINavigationController }).first else { return }
            nav.pushViewController(viewController, animated: true)
        }
    }

    @objc private func sliderTouchDown() {
        isSliderDragging = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        backdropView.setPaused(true)
        UIView.animate(withDuration: 0.15) {
            self.progressSlider.transform = CGAffineTransform(scaleX: 1.0, y: 1.4)
        }
        updateScrubBubble(time: TimeInterval(progressSlider.value))
        UIView.animate(withDuration: 0.12) { self.scrubBubble.alpha = 1 }
    }

    @objc private func sliderTouchUp() {
        isSliderDragging = false
        if presentedViewController == nil, view.window != nil {
            backdropView.setPaused(false)
        }
        UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.75, initialSpringVelocity: 0.8) {
            self.progressSlider.transform = .identity
        }
        UIView.animate(withDuration: 0.12) { self.scrubBubble.alpha = 0 }
        let targetTime = TimeInterval(progressSlider.value)
        chaseTime = targetTime
        seekToChaseTime()
    }

    @objc private func sliderChanged() {
        let time = TimeInterval(progressSlider.value)
        chaseTime = time
        updateTimeLabelsFromSlider(time)
        updateScrubBubble(time: time)
        if !isSeeking {
            seekToChaseTime()
        }
    }

    private func updateScrubBubble(time: TimeInterval) {
        let total = Int(time)
        scrubBubbleLabel.text = String(format: "%d:%02d", total / 60, total % 60)
        scrubBubbleLabel.sizeToFit()
        let bubbleSize = CGSize(width: scrubBubbleLabel.bounds.width + 20, height: 24)
        scrubBubble.bounds = CGRect(origin: .zero, size: bubbleSize)
        scrubBubbleLabel.frame = scrubBubble.bounds
        let trackRect = progressSlider.trackRect(forBounds: progressSlider.bounds)
        let thumbRect = progressSlider.thumbRect(forBounds: progressSlider.bounds, trackRect: trackRect, value: progressSlider.value)
        let thumbCenter = progressSlider.convert(CGPoint(x: thumbRect.midX, y: thumbRect.minY), to: view)
        scrubBubble.center = CGPoint(x: thumbCenter.x, y: thumbCenter.y - 26)
    }

    private func seekToChaseTime() {
        isSeeking = true
        let target = chaseTime
        let cmTime = CMTime(seconds: target, preferredTimescale: 600)
        let tolerance = isSliderDragging
            ? CMTime(seconds: 0.5, preferredTimescale: 600)
            : CMTime.zero

        AudioPlayer.shared.seekSmooth(to: cmTime, tolerance: tolerance) { [weak self] in
            guard let self else { return }
            self.isSeeking = false
            if abs(self.chaseTime - target) > 0.5 {
                self.seekToChaseTime()
            }
        }
    }

    private func updateTimeLabelsFromSlider(_ time: TimeInterval) {
        let total = Int(time)
        currentTimeLabel.text = String(format: "%d:%02d", total / 60, total % 60)
        let rem = max(0, TimeInterval(progressSlider.maximumValue) - time)
        let remTotal = Int(rem)
        remainingTimeLabel.text = String(format: "-%d:%02d", remTotal / 60, remTotal % 60)
    }

    @objc private func shuffleRepeatDidChange() {
        updateShuffleRepeatState()
    }

    @objc private func pauseBackdrop() {
        backdropView.setPaused(true)
    }

    @objc private func resumeBackdrop() {
        guard view.window != nil || !hasAnimatedAppearance || isBeingPresented else {
            return
        }
        guard !isSliderDragging else { return }
        backdropView.setPaused(false)
    }

    private func showSleepTimerSheet() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let sheet = UIAlertController(title: "Sleep Timer", message: nil, preferredStyle: .actionSheet)
        for minutes in [15, 30, 45, 60] {
            sheet.addAction(UIAlertAction(title: "\(minutes) minutes", style: .default) { [weak self] _ in
                AudioPlayer.shared.setSleepTimer(minutes: minutes)
                self?.updateSleepTimerButton()
            })
        }
        sheet.addAction(UIAlertAction(title: "End of Track", style: .default) { [weak self] _ in
            AudioPlayer.shared.setSleepTimerEndOfTrack()
            self?.updateSleepTimerButton()
        })
        if AudioPlayer.shared.sleepTimerRemaining != nil || AudioPlayer.shared.sleepAtEndOfTrack {
            sheet.addAction(UIAlertAction(title: "Cancel Timer", style: .destructive) { [weak self] _ in
                AudioPlayer.shared.cancelSleepTimer()
                self?.updateSleepTimerButton()
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    private func updateSleepTimerButton() {
        let isActive = AudioPlayer.shared.sleepTimerRemaining != nil || AudioPlayer.shared.sleepAtEndOfTrack
        let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let iconName = isActive ? "moon.zzz.fill" : "moon.zzz"
        sleepTimerButton.setImage(UIImage(systemName: iconName, withConfiguration: config), for: .normal)
        sleepTimerButton.tintColor = isActive ? .white : .white.withAlphaComponent(0.7)
        sleepTimerButton.accessibilityValue = isActive ? "Active" : "Off"
        sleepTimerCapsule?.setActive(isActive, animated: hasAppliedInitialState)
    }

    @objc private func handleSwipeLeft() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        animateTrackChange(direction: -1) { [weak self] in self?.viewModel.nextTrack() }
    }

    @objc private func handleSwipeRight() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        animateTrackChange(direction: 1) { [weak self] in self?.viewModel.previousTrack() }
    }

    /// Slides the artwork out in the swipe direction, advances the track, then
    /// springs the new artwork in from the opposite edge with an interruptible animator.
    private func animateTrackChange(direction: CGFloat, change: @escaping () -> Void) {
        guard !UIAccessibility.isReduceMotionEnabled else {
            change()
            return
        }
        isSwipeAnimating = true
        let outbound = UIViewPropertyAnimator(duration: 0.12, curve: .easeIn) { [self] in
            artworkView.transform = CGAffineTransform(translationX: 36 * direction, y: 0).scaledBy(x: 0.94, y: 0.94)
            artworkView.alpha = 0.35
        }
        outbound.addCompletion { [weak self] _ in
            guard let self else { return }
            change()
            self.artworkView.transform = CGAffineTransform(translationX: -36 * direction, y: 0).scaledBy(x: 0.94, y: 0.94)
            let spring = UISpringTimingParameters(dampingRatio: 0.84, initialVelocity: CGVector(dx: 2.2, dy: 0))
            let inbound = UIViewPropertyAnimator(duration: 0.32, timingParameters: spring)
            inbound.addAnimations {
                self.artworkView.transform = .identity
                self.artworkView.alpha = 1
            }
            inbound.addCompletion { [weak self] _ in self?.isSwipeAnimating = false }
            inbound.startAnimation()
        }
        outbound.startAnimation()
    }

    /// Tilts the artwork card in 3D toward the touch point while pressed and
    /// springs it flat on release; disabled under Reduce Motion.
    @objc private func handleTilt(_ gesture: UILongPressGestureRecognizer) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        switch gesture.state {
        case .began, .changed:
            let location = gesture.location(in: artworkContainer)
            let bounds = artworkContainer.bounds
            guard bounds.width > 0, bounds.height > 0 else { return }
            let normalizedX = (location.x / bounds.width - 0.5) * 2
            let normalizedY = (location.y / bounds.height - 0.5) * 2
            let maxAngle: CGFloat = 6 * .pi / 180
            var transform = CATransform3DIdentity
            transform.m34 = -1 / 600
            transform = CATransform3DRotate(transform, -normalizedY * maxAngle, 1, 0, 0)
            transform = CATransform3DRotate(transform, normalizedX * maxAngle, 0, 1, 0)
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            artworkView.layer.transform = transform
            CATransaction.commit()
        case .ended, .cancelled, .failed:
            let spring = CASpringAnimation(keyPath: "transform")
            spring.fromValue = artworkView.layer.presentation()?.transform ?? artworkView.layer.transform
            spring.toValue = CATransform3DIdentity
            spring.damping = 14
            spring.stiffness = 160
            spring.duration = spring.settlingDuration
            artworkView.layer.transform = CATransform3DIdentity
            artworkView.layer.add(spring, forKey: "tiltRelease")
        default:
            break
        }
    }

    private func prepareAppearanceAnimationIfNeeded() {
        guard !hasAnimatedAppearance, !UIAccessibility.isReduceMotionEnabled else { return }
        for group in appearanceGroups() {
            for element in group {
                element.alpha = 0
                element.transform = CGAffineTransform(translationX: 0, y: 14)
            }
        }
    }

    private func runAppearanceAnimationIfNeeded() {
        guard !hasAnimatedAppearance else { return }
        hasAnimatedAppearance = true
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        for (index, group) in appearanceGroups().enumerated() {
            let animator = UIViewPropertyAnimator(duration: 0.32, dampingRatio: 0.84) { [self] in
                for element in group {
                    element.alpha = 1
                    element.transform = element === artworkContainer
                        ? CGAffineTransform(scaleX: artworkRestScale, y: artworkRestScale)
                        : .identity
                }
            }
            animator.startAnimation(afterDelay: Double(index) * 0.05)
        }
    }

    private func appearanceGroups() -> [[UIView]] {
        [
            [artworkContainer],
            [titleMarquee, artistButton, dashLabel, albumLabel, playingFromLabel],
            [progressSlider, currentTimeLabel, remainingTimeLabel, skipBackButton, previousButton,
             playPauseButton, nextButton, skipForwardButton],
        ]
    }
}

extension NowPlayingViewController: UIContextMenuInteractionDelegate {

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let track = AudioPlayer.shared.currentTrack else { return nil }
        if interaction.view === artworkContainer {
            return artworkContextMenuConfiguration(track: track)
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let copyTitle = UIAction(title: "Copy Title", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = track.title
            }
            let copyArtist = UIAction(title: "Copy Artist", image: UIImage(systemName: "person")) { _ in
                UIPasteboard.general.string = track.artist
            }
            let copyBoth = UIAction(title: "Copy Track Info", image: UIImage(systemName: "music.note")) { _ in
                UIPasteboard.general.string = "\(track.artist) — \(track.title)"
            }
            return UIMenu(children: [copyTitle, copyArtist, copyBoth])
        }
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willDisplayMenuFor configuration: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionAnimating?
    ) {
        guard interaction.view === artworkContainer else { return }
        artworkView.layer.removeAnimation(forKey: "tiltRelease")
        artworkView.layer.transform = CATransform3DIdentity
    }

    private func artworkContextMenuConfiguration(track: Track) -> UIContextMenuConfiguration {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var actions: [UIMenuElement] = [
                UIAction(title: "Go to Album", image: UIImage(systemName: "square.stack")) { _ in
                    self?.navigateToAlbum()
                },
                UIAction(title: "Go to Artist", image: UIImage(systemName: "music.microphone")) { _ in
                    self?.navigateToArtist()
                },
            ]
            if let self, let artwork = self.artworkView.image, self.artworkView.contentMode == .scaleAspectFill {
                actions.append(UIAction(title: "Share Artwork", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                    self.shareArtworkImage(artwork)
                })
            }
            actions.append(UIAction(title: "Copy Title", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = track.title
            })
            return UIMenu(children: actions)
        }
    }
}
