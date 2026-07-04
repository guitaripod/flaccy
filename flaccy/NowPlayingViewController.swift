import AVFoundation
import AVKit
import Combine
import UIKit

final class NowPlayingViewController: UIViewController, SonglinkShareable {

    private let viewModel = NowPlayingViewModel()
    private var cancellables = Set<AnyCancellable>()

    private let backdropView = NowPlayingBackdropView()
    private let scrimLayer = CAGradientLayer()
    private let artworkView = UIImageView()
    private let artworkContainer = UIView()
    private let titleMarquee = MarqueeLabel()
    private let loveButton = LoveButton(pointSize: 22)
    private let qualityBadge = QualityBadgeView(size: .regular)
    private let artistAvatarButton = UIButton(type: .custom)
    private let artistButton = UIButton(type: .system)
    private let dashLabel = UILabel()
    private let albumLabel = UILabel()
    private let playingFromLabel = UILabel()
    private let scrubber = ScrubberView()
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
    private let volumeSlider = SystemVolumeSlider()
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
    private var lyricsCapsule: GlassCapsule?
    private var queueCapsule: GlassCapsule?
    private var actionCapsules: [UIView] = []
    private let actionRowContainer = UIStackView()

    private enum CenterState {
        case artwork
        case lyrics
        case queue
    }

    private var centerState: CenterState = .artwork
    private var stateChildController: UIViewController?
    private let centerContainer = UIView()
    private let artworkGroup = UIStackView()
    private let compactHeader = UIControl()
    private let compactArtworkView = UIImageView()
    private let compactTitleLabel = UILabel()
    private let compactArtistLabel = UILabel()
    private let stateContentContainer = UIView()

    private var artistImageTask: Task<Void, Never>?
    private var currentArtistKey: String?

    private var isSeeking = false
    private var chaseTime: TimeInterval = 0
    private var lastTrackKey: String?
    private var lastIsPlaying: Bool?
    private var hasAppliedInitialState = false
    private var hasAnimatedAppearance = false
    private var breatheAnimator: UIViewPropertyAnimator?
    private var artworkRestScale: CGFloat = 1

    private let peekArtworkView = UIImageView()
    private var trackPanAnimator: UIViewPropertyAnimator?
    private var trackPanDirection: CGFloat = 0
    private var trackPanBlocked = false
    private var trackPanBaseFraction: CGFloat = 0
    private var trackPanCommitted = false
    private var trackPanPastThreshold = false
    private var isInteractiveTrackTransitionActive = false
    private var deferredArtwork: UIImage??
    private lazy var thresholdTickGenerator = UIImpactFeedbackGenerator(style: .light)

    private enum TrackPan {
        static let exitMultiplier: CGFloat = 1.15
        static let commitDistanceRatio: CGFloat = 0.35
        static let commitVelocity: CGFloat = 600
        static let linearLimitRatio: CGFloat = 0.6
        static let rubberRangeRatio: CGFloat = 0.25
        static let blockedRangeRatio: CGFloat = 0.16
        static let exitRotation: CGFloat = 0.06
        static let exitScale: CGFloat = 0.92
        static let peekScale: CGFloat = 0.9
        static let peekStartMultiplier: CGFloat = 1.08
    }

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
        NotificationCenter.default.addObserver(
            self, selector: #selector(lovedTracksDidChange), name: LovedTracksService.didChange, object: nil
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

        let infoStack = UIStackView(arrangedSubviews: [makeTitleRow(), makeArtistAlbumRow(), playingFromLabel])
        infoStack.axis = .vertical
        infoStack.spacing = 4

        let sliderStack = UIStackView(arrangedSubviews: [scrubber, makeTimeRow()])
        sliderStack.axis = .vertical
        sliderStack.spacing = 0

        let transportStack = UIStackView(arrangedSubviews: [
            skipBackButton, previousButton, playPauseButton, nextButton, skipForwardButton,
        ])
        transportStack.distribution = .equalSpacing
        transportStack.alignment = .center

        let volumeRow = makeVolumeRow()
        let bottomStack = UIStackView(arrangedSubviews: [
            sliderStack, transportStack, volumeRow, makeActionRow(),
        ])
        bottomStack.axis = .vertical
        bottomStack.spacing = 22
        bottomStack.setCustomSpacing(28, after: transportStack)
        bottomStack.setCustomSpacing(34, after: volumeRow)
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomStack)

        setupCenterContainer(infoStack: infoStack)
        setupScrubBubble()

        NSLayoutConstraint.activate([
            centerContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            centerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            centerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            centerContainer.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -14),
            bottomStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            bottomStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            bottomStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            artworkView.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, multiplier: 0.42),
        ])
    }

    /// Hosts the three exclusive center states: the artwork column (default),
    /// and the lyrics/queue child content shown below a compact now-playing
    /// header that morphs in when the artwork collapses.
    private func setupCenterContainer(infoStack: UIStackView) {
        centerContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(centerContainer)

        artworkGroup.axis = .vertical
        artworkGroup.spacing = 26
        artworkGroup.addArrangedSubview(artworkContainer)
        artworkGroup.addArrangedSubview(infoStack)
        artworkGroup.translatesAutoresizingMaskIntoConstraints = false
        centerContainer.addSubview(artworkGroup)

        setupCompactHeader()
        centerContainer.addSubview(compactHeader)

        stateContentContainer.alpha = 0
        stateContentContainer.isUserInteractionEnabled = false
        stateContentContainer.translatesAutoresizingMaskIntoConstraints = false
        centerContainer.addSubview(stateContentContainer)

        NSLayoutConstraint.activate([
            artworkGroup.topAnchor.constraint(equalTo: centerContainer.topAnchor),
            artworkGroup.leadingAnchor.constraint(equalTo: centerContainer.leadingAnchor),
            artworkGroup.trailingAnchor.constraint(equalTo: centerContainer.trailingAnchor),
            artworkGroup.bottomAnchor.constraint(lessThanOrEqualTo: centerContainer.bottomAnchor),
            compactHeader.topAnchor.constraint(equalTo: centerContainer.topAnchor),
            compactHeader.leadingAnchor.constraint(equalTo: centerContainer.leadingAnchor),
            compactHeader.trailingAnchor.constraint(equalTo: centerContainer.trailingAnchor),
            stateContentContainer.topAnchor.constraint(equalTo: compactHeader.bottomAnchor, constant: 10),
            stateContentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateContentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stateContentContainer.bottomAnchor.constraint(equalTo: centerContainer.bottomAnchor),
        ])
    }

    private func setupCompactHeader() {
        compactHeader.alpha = 0
        compactHeader.isUserInteractionEnabled = false
        compactHeader.translatesAutoresizingMaskIntoConstraints = false
        compactHeader.accessibilityHint = "Returns to the artwork"
        compactHeader.accessibilityTraits = .button
        compactHeader.addAction(UIAction { [weak self] _ in
            self?.setCenterState(.artwork)
        }, for: .touchUpInside)

        compactArtworkView.contentMode = .scaleAspectFill
        compactArtworkView.clipsToBounds = true
        compactArtworkView.layer.cornerRadius = 10
        compactArtworkView.layer.cornerCurve = .continuous
        compactArtworkView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        compactArtworkView.tintColor = UIColor.white.withAlphaComponent(0.35)
        compactArtworkView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .light)
        compactArtworkView.isUserInteractionEnabled = false

        compactTitleLabel.font = .scaled(.subheadline, size: 15, weight: .semibold)
        compactTitleLabel.adjustsFontForContentSizeCategory = true
        compactTitleLabel.textColor = .white
        compactTitleLabel.lineBreakMode = .byTruncatingTail

        compactArtistLabel.font = .scaled(.caption1, size: 13, weight: .regular)
        compactArtistLabel.adjustsFontForContentSizeCategory = true
        compactArtistLabel.textColor = .white.withAlphaComponent(0.6)
        compactArtistLabel.lineBreakMode = .byTruncatingTail

        let textStack = UIStackView(arrangedSubviews: [compactTitleLabel, compactArtistLabel])
        textStack.axis = .vertical
        textStack.spacing = 1
        textStack.isUserInteractionEnabled = false

        let chevron = UIImageView(image: UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        ))
        chevron.tintColor = .white.withAlphaComponent(0.45)
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [compactArtworkView, textStack, chevron])
        row.spacing = 12
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        compactHeader.addSubview(row)

        NSLayoutConstraint.activate([
            compactArtworkView.widthAnchor.constraint(equalToConstant: 44),
            compactArtworkView.heightAnchor.constraint(equalToConstant: 44),
            compactHeader.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            row.topAnchor.constraint(equalTo: compactHeader.topAnchor, constant: 4),
            row.leadingAnchor.constraint(equalTo: compactHeader.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: compactHeader.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: compactHeader.bottomAnchor, constant: -4),
        ])
    }


    /// Device-motion parallax: the artwork card drifts opposite the device tilt
    /// so it reads as floating above the backdrop. Skipped under Reduce Motion.
    private func addMotionParallax() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let horizontal = UIInterpolatingMotionEffect(keyPath: "center.x", type: .tiltAlongHorizontalAxis)
        horizontal.minimumRelativeValue = -18
        horizontal.maximumRelativeValue = 18
        let vertical = UIInterpolatingMotionEffect(keyPath: "center.y", type: .tiltAlongVerticalAxis)
        vertical.minimumRelativeValue = -12
        vertical.maximumRelativeValue = 12
        let group = UIMotionEffectGroup()
        group.motionEffects = [horizontal, vertical]
        artworkContainer.addMotionEffect(group)
    }

    private func setupArtwork() {
        addMotionParallax()
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

        setupPeekArtwork()

        artworkContainer.isUserInteractionEnabled = true
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleTrackPan(_:)))
        pan.delegate = self
        artworkContainer.addGestureRecognizer(pan)

        let tilt = UILongPressGestureRecognizer(target: self, action: #selector(handleTilt(_:)))
        tilt.minimumPressDuration = 0.18
        artworkContainer.addGestureRecognizer(tilt)

        artworkContainer.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    private func setupPeekArtwork() {
        peekArtworkView.contentMode = .scaleAspectFill
        peekArtworkView.clipsToBounds = true
        peekArtworkView.layer.cornerRadius = 20
        peekArtworkView.layer.cornerCurve = .continuous
        peekArtworkView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        peekArtworkView.tintColor = UIColor.white.withAlphaComponent(0.35)
        peekArtworkView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 48, weight: .ultraLight)
        peekArtworkView.isHidden = true
        peekArtworkView.isUserInteractionEnabled = false
        peekArtworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkContainer.addSubview(peekArtworkView)
        NSLayoutConstraint.activate([
            peekArtworkView.topAnchor.constraint(equalTo: artworkView.topAnchor),
            peekArtworkView.leadingAnchor.constraint(equalTo: artworkView.leadingAnchor),
            peekArtworkView.trailingAnchor.constraint(equalTo: artworkView.trailingAnchor),
            peekArtworkView.bottomAnchor.constraint(equalTo: artworkView.bottomAnchor),
        ])
    }

    private func setupInfoBlock() {
        titleMarquee.font = .scaled(.title3, size: 21, weight: .bold)
        titleMarquee.textColor = .white
        titleMarquee.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleMarquee.addInteraction(UIContextMenuInteraction(delegate: self))
        titleMarquee.isUserInteractionEnabled = true
        titleMarquee.accessibilityTraits = .button
        titleMarquee.accessibilityHint = "Shows the album"
        titleMarquee.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(albumNavigationTapped))
        )

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
        albumLabel.isAccessibilityElement = true
        albumLabel.accessibilityTraits = .button
        albumLabel.accessibilityHint = "Shows the album"
        albumLabel.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(albumNavigationTapped))
        )

        playingFromLabel.font = .scaled(.caption1, size: 12, weight: .regular)
        playingFromLabel.adjustsFontForContentSizeCategory = true
        playingFromLabel.textColor = .white.withAlphaComponent(0.4)
        playingFromLabel.isHidden = true
        playingFromLabel.isUserInteractionEnabled = true
        playingFromLabel.accessibilityTraits = .button
        playingFromLabel.accessibilityHint = "Shows the album"
        playingFromLabel.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(albumNavigationTapped))
        )
    }

    @objc private func albumNavigationTapped() {
        navigateToAlbum()
    }

    /// The song title paired with its quality signature and the love toggle:
    /// title claims the width, the badge and heart hug the trailing edge.
    private func makeTitleRow() -> UIStackView {
        loveButton.onToggle = { [weak self] in self?.toggleLove() }

        let row = UIStackView(arrangedSubviews: [titleMarquee, qualityBadge, loveButton])
        row.spacing = 8
        row.alignment = .center
        return row
    }

    private func toggleLove() {
        guard let track = AudioPlayer.shared.currentTrack else { return }
        let newValue = !LovedTracksService.shared.isLoved(track: track)
        loveButton.setLoved(newValue, animated: true)
        Task { await LovedTracksService.shared.toggleLove(track: track) }
    }

    private func refreshTrackSignals() {
        let track = AudioPlayer.shared.currentTrack
        qualityBadge.configure(with: track)
        loveButton.isEnabled = track != nil
        let loved = track.map { LovedTracksService.shared.isLoved(track: $0) } ?? false
        loveButton.setLoved(loved, animated: false)
    }

    @objc private func lovedTracksDidChange() {
        let track = AudioPlayer.shared.currentTrack
        let loved = track.map { LovedTracksService.shared.isLoved(track: $0) } ?? false
        loveButton.setLoved(loved, animated: false)
    }

    private func makeArtistAlbumRow() -> UIStackView {
        let row = UIStackView(arrangedSubviews: [artistAvatarButton, artistButton, dashLabel, albumLabel])
        row.spacing = 0
        row.setCustomSpacing(7, after: artistAvatarButton)
        row.alignment = .center
        return row
    }

    private func setupScrubber() {
        scrubber.onScrubBegan = { [weak self] in self?.scrubBegan() }
        scrubber.onScrubChanged = { [weak self] time in self?.scrubChanged(to: time) }
        scrubber.onScrubEnded = { [weak self] time in self?.scrubEnded(at: time) }
        scrubber.onAccessibilityAdjust = { [weak self] time in
            self?.chaseTime = time
            self?.seekToChaseTime()
        }

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
        volumeSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [minGlyph, volumeSlider, maxGlyph])
        row.spacing = 12
        row.alignment = .center
        return row
    }

    private func makeActionRow() -> UIStackView {
        configureActionButtons()

        let shuffle = GlassCapsule(hosting: shuffleButton)
        let repeats = GlassCapsule(hosting: repeatButton)
        let sleep = GlassCapsule(hosting: sleepTimerButton)
        let lyrics = GlassCapsule(hosting: lyricsButton)
        let queue = GlassCapsule(hosting: queueButton)
        shuffleCapsule = shuffle
        repeatCapsule = repeats
        sleepTimerCapsule = sleep
        lyricsCapsule = lyrics
        queueCapsule = queue

        actionCapsules = [
            shuffle, repeats, GlassCapsule(hosting: airplayButton), sleep,
            GlassCapsule(hosting: shareButton), lyrics, queue,
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
        lyricsButton.accessibilityHint = "Shows lyrics in place of the artwork"
        lyricsButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.setCenterState(self.centerState == .lyrics ? .artwork : .lyrics)
        }, for: .touchUpInside)

        queueButton.setImage(UIImage(systemName: "list.bullet", withConfiguration: iconConfig), for: .normal)
        queueButton.accessibilityLabel = "Queue"
        queueButton.accessibilityHint = "Shows the queue in place of the artwork"
        queueButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.setCenterState(self.centerState == .queue ? .artwork : .queue)
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
        let centerElements: [Any]
        switch centerState {
        case .artwork:
            centerElements = [
                artworkContainer, titleMarquee, qualityBadge, loveButton,
                artistAvatarButton, artistButton, albumLabel, playingFromLabel,
            ]
        case .lyrics, .queue:
            centerElements = [compactHeader, stateChildController?.view].compactMap { $0 }
        }
        view.accessibilityElements = centerElements + [
            scrubber, currentTimeLabel, remainingTimeLabel,
            skipBackButton, previousButton, playPauseButton, nextButton, skipForwardButton,
            volumeSlider,
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
        if !scrubber.isScrubbing {
            scrubber.setProgress(currentTime: state.currentTime, duration: state.duration)
            scrubber.accessibilityValue = state.currentTimeFormatted
            currentTimeLabel.text = state.currentTimeFormatted
            remainingTimeLabel.text = state.remainingTimeFormatted
        }
    }

    private func applyTrackMetadata(_ state: NowPlayingViewModel.State) {
        titleMarquee.text = state.title
        artistButton.setTitle(state.artist, for: .normal)
        albumLabel.text = state.albumTitle
        compactTitleLabel.text = state.title
        compactArtistLabel.text = state.artist
        compactHeader.accessibilityLabel = "Now playing: \(state.title), \(state.artist)"

        let hasArtist = !state.artist.isEmpty
        let hasAlbum = !state.albumTitle.isEmpty
        dashLabel.isHidden = !(hasArtist && hasAlbum)
        playingFromLabel.text = hasAlbum ? "Playing from \(state.albumTitle)" : ""
        playingFromLabel.isHidden = !hasAlbum

        refreshTrackSignals()
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
        if hasAppliedInitialState, hasAnimatedAppearance, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.2, animations: update)
        } else {
            update()
        }
    }

    private func setArtwork(_ image: UIImage?) {
        applyCompactArtwork(image)
        if isInteractiveTrackTransitionActive {
            deferredArtwork = .some(image)
            return
        }
        if hasAppliedInitialState, !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(
                with: artworkView, duration: 0.22,
                options: [.transitionCrossDissolve, .allowUserInteraction]
            ) { self.applyArtworkDirect(image) }
        } else {
            applyArtworkDirect(image)
        }
    }

    private func applyCompactArtwork(_ image: UIImage?) {
        if let image {
            compactArtworkView.contentMode = .scaleAspectFill
            compactArtworkView.image = image
        } else {
            compactArtworkView.contentMode = .center
            compactArtworkView.image = UIImage(systemName: "music.note")
        }
    }

    private func applyArtworkDirect(_ image: UIImage?) {
        if let image {
            artworkView.contentMode = .scaleAspectFill
            artworkView.image = image
        } else {
            artworkView.contentMode = .center
            artworkView.image = UIImage(systemName: "music.note")
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
        let countPart = count > 0 ? "\(count) tracks" : nil
        let shownPart = centerState == .queue ? "Shown" : nil
        let parts = [countPart, shownPart].compactMap { $0 }
        queueButton.accessibilityValue = parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    @objc private func queueDidChange() {
        updateQueueBadge()
    }

    /// Switches the center region between the artwork column and in-place
    /// lyrics/queue content. States are exclusive; the lyrics and queue
    /// controllers are embedded as children so their standalone modal
    /// presentations elsewhere keep working.
    private func setCenterState(_ target: CenterState) {
        guard target != centerState else { return }
        if target == .lyrics, AudioPlayer.shared.currentTrack == nil { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let previous = centerState
        centerState = target
        removeStateChild()
        if let child = makeStateChild(for: target) {
            embedStateChild(child)
        }
        updateStateCapsules()
        animateCenterTransition(from: previous, to: target)
        setupAccessibilityOrder()
        UIAccessibility.post(notification: .layoutChanged, argument: target == .artwork ? artworkContainer : compactHeader)
        AppLogger.info("Now Playing center state -> \(target)", category: .ui)
    }

    private func makeStateChild(for state: CenterState) -> UIViewController? {
        switch state {
        case .artwork:
            return nil
        case .lyrics:
            guard let track = AudioPlayer.shared.currentTrack else { return nil }
            return LyricsViewController(
                track: track.title, artist: track.artist, album: track.albumTitle, embeddedInNowPlaying: true
            )
        case .queue:
            return QueueViewController(embeddedInNowPlaying: true)
        }
    }

    private func embedStateChild(_ child: UIViewController) {
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        stateContentContainer.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: stateContentContainer.topAnchor),
            child.view.leadingAnchor.constraint(equalTo: stateContentContainer.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: stateContentContainer.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: stateContentContainer.bottomAnchor),
        ])
        child.didMove(toParent: self)
        stateChildController = child
    }

    private func removeStateChild() {
        guard let child = stateChildController else { return }
        child.willMove(toParent: nil)
        child.view.removeFromSuperview()
        child.removeFromParent()
        stateChildController = nil
    }

    private func updateStateCapsules() {
        lyricsCapsule?.setActive(centerState == .lyrics, animated: hasAppliedInitialState)
        queueCapsule?.setActive(centerState == .queue, animated: hasAppliedInitialState)
        lyricsButton.tintColor = centerState == .lyrics ? .white : .white.withAlphaComponent(0.7)
        queueButton.tintColor = centerState == .queue ? .white : .white.withAlphaComponent(0.7)
        lyricsButton.accessibilityValue = centerState == .lyrics ? "Shown" : nil
        updateQueueBadge()
    }

    /// Crossfade-and-scale morph between the artwork column and the compact
    /// header + child content; alpha-only under Reduce Motion.
    private func animateCenterTransition(from previous: CenterState, to target: CenterState) {
        let showsArtwork = target == .artwork
        artworkGroup.isUserInteractionEnabled = showsArtwork
        compactHeader.isUserInteractionEnabled = !showsArtwork
        stateContentContainer.isUserInteractionEnabled = !showsArtwork

        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let apply = { [self] in
            artworkGroup.alpha = showsArtwork ? 1 : 0
            compactHeader.alpha = showsArtwork ? 0 : 1
            stateContentContainer.alpha = showsArtwork ? 0 : 1
            if !reduceMotion {
                artworkGroup.transform = showsArtwork ? .identity : CGAffineTransform(scaleX: 0.94, y: 0.94)
                stateContentContainer.transform = showsArtwork
                    ? CGAffineTransform(translationX: 0, y: 12)
                    : .identity
            }
        }
        guard hasAppliedInitialState, !reduceMotion else {
            artworkGroup.transform = .identity
            stateContentContainer.transform = .identity
            apply()
            return
        }
        if !showsArtwork {
            stateContentContainer.alpha = 0
            stateContentContainer.transform = CGAffineTransform(translationX: 0, y: 12)
        }
        let animator = UIViewPropertyAnimator(duration: 0.32, dampingRatio: 0.84, animations: apply)
        animator.startAnimation()
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

    private func scrubBegan() {
        backdropView.setPaused(true)
        updateScrubBubble(time: scrubber.currentTime)
        UIView.animate(withDuration: 0.12) { self.scrubBubble.alpha = 1 }
    }

    private func scrubChanged(to time: TimeInterval) {
        chaseTime = time
        updateTimeLabelsFromScrubber(time)
        updateScrubBubble(time: time)
        if !isSeeking {
            seekToChaseTime()
        }
    }

    private func scrubEnded(at time: TimeInterval) {
        if presentedViewController == nil, view.window != nil {
            backdropView.setPaused(false)
        }
        UIView.animate(withDuration: 0.12) { self.scrubBubble.alpha = 0 }
        chaseTime = time
        seekToChaseTime()
    }

    private func updateScrubBubble(time: TimeInterval) {
        let total = Int(time)
        scrubBubbleLabel.text = String(format: "%d:%02d", total / 60, total % 60)
        scrubBubbleLabel.sizeToFit()
        let bubbleSize = CGSize(width: scrubBubbleLabel.bounds.width + 20, height: 24)
        scrubBubble.bounds = CGRect(origin: .zero, size: bubbleSize)
        scrubBubbleLabel.frame = scrubBubble.bounds
        let anchor = scrubber.convert(CGPoint(x: scrubber.playheadX, y: 0), to: view)
        let halfWidth = bubbleSize.width / 2
        let clampedX = min(max(anchor.x, halfWidth + 8), view.bounds.width - halfWidth - 8)
        scrubBubble.center = CGPoint(x: clampedX, y: anchor.y - 18)
    }

    private func seekToChaseTime() {
        isSeeking = true
        let target = chaseTime
        let cmTime = CMTime(seconds: target, preferredTimescale: 600)
        let tolerance = scrubber.isScrubbing
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

    private func updateTimeLabelsFromScrubber(_ time: TimeInterval) {
        let total = Int(time)
        currentTimeLabel.text = String(format: "%d:%02d", total / 60, total % 60)
        let rem = max(0, scrubber.duration - time)
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
        guard !scrubber.isScrubbing else { return }
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

    /// Interactive, interruptible track-change gesture. The card tracks the
    /// finger 1:1 via a paused linear animator scrubbed by translation, with
    /// rubber-band resistance past 60% of the width (or from zero when the
    /// direction is blocked), the neighbor's artwork peeking from the opposite
    /// edge, and a velocity-seeded spring settle in either direction.
    @objc private func handleTrackPan(_ gesture: UIPanGestureRecognizer) {
        guard !UIAccessibility.isReduceMotionEnabled else {
            handleReducedMotionTrackPan(gesture)
            return
        }
        let width = max(artworkContainer.bounds.width, 1)
        let translation = gesture.translation(in: view).x
        let velocity = gesture.velocity(in: view).x
        switch gesture.state {
        case .began:
            beginTrackPan()
        case .changed:
            scrubTrackPan(translation: translation, width: width)
        case .ended:
            settleTrackPan(velocity: velocity, width: width, cancelled: false)
        case .cancelled, .failed:
            settleTrackPan(velocity: velocity, width: width, cancelled: true)
        default:
            break
        }
    }

    /// Grabs a settling card mid-flight: the running animator is paused at its
    /// current fraction and further scrubbing continues from there.
    private func beginTrackPan() {
        thresholdTickGenerator.prepare()
        if let animator = trackPanAnimator, animator.state == .active {
            animator.pauseAnimation()
            animator.isReversed = false
            trackPanBaseFraction = animator.fractionComplete
        } else {
            trackPanAnimator = nil
            trackPanDirection = 0
            trackPanBaseFraction = 0
            trackPanCommitted = false
            trackPanPastThreshold = false
        }
    }

    private func startTrackPan(direction: CGFloat, width: CGFloat) {
        trackPanDirection = direction
        trackPanBlocked = isTrackChangeBlocked(direction: direction)
        trackPanBaseFraction = 0
        trackPanCommitted = false
        trackPanPastThreshold = false
        deferredArtwork = nil
        isInteractiveTrackTransitionActive = true
        if !trackPanBlocked {
            configurePeekArtwork(with: neighborTrack(direction: direction))
            peekArtworkView.transform = CGAffineTransform(
                translationX: -direction * width * TrackPan.peekStartMultiplier, y: 0
            ).scaledBy(x: TrackPan.peekScale, y: TrackPan.peekScale)
            peekArtworkView.isHidden = false
        }
        let blocked = trackPanBlocked
        let fullDistance = trackPanFullDistance(width: width)
        let animator = UIViewPropertyAnimator(duration: 0.4, curve: .linear)
        animator.addAnimations { [self] in
            if blocked {
                artworkView.transform = CGAffineTransform(translationX: direction * fullDistance, y: 0)
                    .rotated(by: direction * TrackPan.exitRotation * 0.5)
                    .scaledBy(x: 0.97, y: 0.97)
            } else {
                artworkView.transform = CGAffineTransform(translationX: direction * fullDistance, y: 0)
                    .rotated(by: direction * TrackPan.exitRotation)
                    .scaledBy(x: TrackPan.exitScale, y: TrackPan.exitScale)
                peekArtworkView.transform = .identity
            }
        }
        animator.addCompletion { [weak self] position in
            self?.trackPanDidSettle(at: position)
        }
        animator.pauseAnimation()
        trackPanAnimator = animator
    }

    private func scrubTrackPan(translation: CGFloat, width: CGFloat) {
        if trackPanAnimator == nil {
            guard abs(translation) > 0.5 else { return }
            startTrackPan(direction: translation < 0 ? -1 : 1, width: width)
        }
        guard let animator = trackPanAnimator else { return }
        let fullDistance = trackPanFullDistance(width: width)
        let raw = trackPanBaseFraction * fullDistance + trackPanDirection * translation
        if raw < -6, trackPanBaseFraction == 0, !trackPanCommitted {
            flipTrackPanDirection(translation: translation, width: width)
            return
        }
        let mapped = rubberBandedDistance(max(0, raw), width: width)
        animator.fractionComplete = min(mapped / fullDistance, 1)
        updateThresholdTick(distance: mapped, width: width)
    }

    private func flipTrackPanDirection(translation: CGFloat, width: CGFloat) {
        let newDirection = -trackPanDirection
        trackPanAnimator?.stopAnimation(true)
        trackPanAnimator = nil
        resetCardPresentation()
        startTrackPan(direction: newDirection, width: width)
        scrubTrackPan(translation: translation, width: width)
    }

    /// Commits when the card is past 35% of the width or flicked faster than
    /// 600 pt/s along the gesture direction (a strong opposite flick cancels);
    /// an already-committed transition always finishes forward.
    private func settleTrackPan(velocity: CGFloat, width: CGFloat, cancelled: Bool) {
        guard let animator = trackPanAnimator else { return }
        let fullDistance = trackPanFullDistance(width: width)
        let distance = animator.fractionComplete * fullDistance
        let directionalVelocity = trackPanDirection * velocity
        let shouldCommit = trackPanCommitted
            || (!trackPanBlocked && !cancelled
                && directionalVelocity > -TrackPan.commitVelocity
                && (distance >= width * TrackPan.commitDistanceRatio
                    || directionalVelocity > TrackPan.commitVelocity))
        if shouldCommit {
            commitTrackPan(animator: animator, distance: distance, velocity: directionalVelocity, fullDistance: fullDistance)
        } else {
            cancelTrackPan(animator: animator, distance: distance, velocity: directionalVelocity, fullDistance: fullDistance)
        }
    }

    private func commitTrackPan(
        animator: UIViewPropertyAnimator, distance: CGFloat, velocity: CGFloat, fullDistance: CGFloat
    ) {
        if !trackPanCommitted {
            trackPanCommitted = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            fireTrackChange(direction: trackPanDirection)
        }
        let remaining = max(fullDistance - distance, 1)
        let spring = UISpringTimingParameters(
            dampingRatio: 0.86, initialVelocity: CGVector(dx: max(0, velocity) / remaining, dy: 0)
        )
        animator.isReversed = false
        animator.continueAnimation(withTimingParameters: spring, durationFactor: 0.8)
    }

    private func cancelTrackPan(
        animator: UIViewPropertyAnimator, distance: CGFloat, velocity: CGFloat, fullDistance: CGFloat
    ) {
        let remaining = max(distance, 1)
        let spring = UISpringTimingParameters(
            dampingRatio: 0.78, initialVelocity: CGVector(dx: max(0, -velocity) / remaining, dy: 0)
        )
        animator.isReversed = true
        animator.continueAnimation(withTimingParameters: spring, durationFactor: 0.7)
    }

    /// Finalizes a settled transition: on commit the peek image is promoted to
    /// the main card before the peek hides, so the swap is pixel-identical, and
    /// any artwork update deferred during the transition is applied directly.
    private func trackPanDidSettle(at position: UIViewAnimatingPosition) {
        trackPanAnimator = nil
        isInteractiveTrackTransitionActive = false
        if case .some(let pending) = deferredArtwork {
            applyArtworkDirect(pending)
        } else if position == .end, trackPanCommitted {
            artworkView.contentMode = peekArtworkView.contentMode
            artworkView.image = peekArtworkView.image
        }
        deferredArtwork = nil
        resetCardPresentation()
        trackPanDirection = 0
        trackPanCommitted = false
        trackPanPastThreshold = false
    }

    private func resetCardPresentation() {
        artworkView.transform = .identity
        peekArtworkView.isHidden = true
        peekArtworkView.transform = .identity
    }

    /// Maps raw finger distance to card distance: 1:1 up to 60% of the width
    /// then asymptotically resisted, or fully rubber-banded from zero when the
    /// direction has no track to go to.
    private func rubberBandedDistance(_ distance: CGFloat, width: CGFloat) -> CGFloat {
        if trackPanBlocked {
            let range = width * TrackPan.blockedRangeRatio
            return range * (1 - 1 / (1 + distance / range))
        }
        let limit = width * TrackPan.linearLimitRatio
        guard distance > limit else { return distance }
        let range = width * TrackPan.rubberRangeRatio
        return limit + range * (1 - 1 / (1 + (distance - limit) / range))
    }

    private func trackPanFullDistance(width: CGFloat) -> CGFloat {
        trackPanBlocked ? width * 0.5 : width * TrackPan.exitMultiplier
    }

    private func updateThresholdTick(distance: CGFloat, width: CGFloat) {
        guard !trackPanBlocked else { return }
        let past = distance >= width * TrackPan.commitDistanceRatio
        guard past != trackPanPastThreshold else { return }
        trackPanPastThreshold = past
        thresholdTickGenerator.impactOccurred(intensity: past ? 1.0 : 0.6)
        thresholdTickGenerator.prepare()
    }

    private func configurePeekArtwork(with track: Track?) {
        if let artwork = track?.artwork {
            peekArtworkView.contentMode = .scaleAspectFill
            peekArtworkView.image = artwork
        } else {
            peekArtworkView.contentMode = .center
            peekArtworkView.image = UIImage(systemName: "music.note")
        }
    }

    /// Resolves the track whose artwork should peek in for the given direction,
    /// mirroring AudioPlayer semantics: forward wraps only on repeat-all, and a
    /// backward swipe more than 3s into a track restarts the current one.
    private func neighborTrack(direction: CGFloat) -> Track? {
        let player = AudioPlayer.shared
        if direction < 0 {
            if player.currentIndex + 1 < player.queue.count {
                return player.queue[player.currentIndex + 1]
            }
            return player.repeatMode == .all ? player.queue.first : nil
        }
        if player.currentTime > 3 { return player.currentTrack }
        guard player.currentIndex > 0, player.currentIndex - 1 < player.queue.count else { return nil }
        return player.queue[player.currentIndex - 1]
    }

    private func isTrackChangeBlocked(direction: CGFloat) -> Bool {
        let player = AudioPlayer.shared
        guard !player.queue.isEmpty else { return true }
        if direction < 0 {
            return player.currentIndex + 1 >= player.queue.count && player.repeatMode != .all
        }
        return player.currentIndex <= 0 && player.currentTime <= 3
    }

    private func fireTrackChange(direction: CGFloat) {
        AppLogger.info(
            "Interactive track change committed (\(direction < 0 ? "next" : "previous"))", category: .ui
        )
        if direction < 0 {
            viewModel.nextTrack()
        } else {
            viewModel.previousTrack()
        }
    }

    private func handleReducedMotionTrackPan(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let width = max(artworkContainer.bounds.width, 1)
        let translation = gesture.translation(in: view).x
        let velocity = gesture.velocity(in: view).x
        let dominant = abs(translation) > 1 ? translation : velocity
        guard dominant != 0 else { return }
        let direction: CGFloat = dominant < 0 ? -1 : 1
        guard !isTrackChangeBlocked(direction: direction) else { return }
        guard direction * translation >= width * TrackPan.commitDistanceRatio
            || direction * velocity > TrackPan.commitVelocity else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        fireTrackChange(direction: direction)
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
            [titleMarquee, qualityBadge, loveButton, artistAvatarButton, artistButton, dashLabel, albumLabel, playingFromLabel],
            [scrubber, currentTimeLabel, remainingTimeLabel, skipBackButton, previousButton,
             playPauseButton, nextButton, skipForwardButton],
        ]
    }
}

extension NowPlayingViewController: UIGestureRecognizerDelegate {

    /// Restricts the track pan to horizontally dominant drags so vertical
    /// drags still reach the sheet's interactive dismissal.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        return abs(velocity.x) >= abs(velocity.y)
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
            let loved = LovedTracksService.shared.isLoved(track: track)
            var actions: [UIMenuElement] = [
                UIAction(
                    title: loved ? "Unlove" : "Love",
                    image: UIImage(systemName: loved ? "heart.slash" : "heart")
                ) { _ in
                    self?.toggleLove()
                },
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
