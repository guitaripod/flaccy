import AVFoundation
import MidgarCore
import AVKit
import Combine
import UIKit

final class NowPlayingViewController: UIViewController, SonglinkShareable {

    let viewModel = NowPlayingViewModel()
    var cancellables = Set<AnyCancellable>()

    let backdropView = NowPlayingBackdropView()
    let scrimLayer = CAGradientLayer()
    let artworkView = UIImageView()
    let artworkContainer = UIView()
    let titleMarquee = MarqueeLabel()
    let loveButton = LoveButton(pointSize: 22)
    let qualityBadge = QualityBadgeView(size: .regular)
    let artistAvatarButton = UIButton(type: .custom)
    let artistButton = UIButton(type: .system)
    let dashLabel = UILabel()
    let albumLabel = UILabel()
    let playingFromLabel = UILabel()
    let scrubber = ScrubberView()
    let currentTimeLabel = UILabel()
    let remainingTimeLabel = UILabel()
    let scrubBubble = UIView()
    let scrubBubbleLabel = UILabel()
    let skipBackButton = UIButton(type: .system)
    let previousButton = UIButton(type: .system)
    let playPauseButton = UIButton(type: .custom)
    let playPauseIconView = UIImageView()
    let nextButton = UIButton(type: .system)
    let skipForwardButton = UIButton(type: .system)
    let volumeSlider = SystemVolumeSlider()
    let shuffleButton = UIButton(type: .system)
    let repeatButton = UIButton(type: .system)
    let airplayButton = AVRoutePickerView(frame: .zero)
    let sleepTimerButton = UIButton(type: .system)
    let shareButton = UIButton(type: .system)
    let lyricsButton = UIButton(type: .system)
    let queueButton = UIButton(type: .system)
    let equalizerButton = UIButton(type: .system)
    let equalizerBadge = EqualizerBadgeView()
    var equalizerCapsule: GlassCapsule?

    var shuffleCapsule: GlassCapsule?
    var repeatCapsule: GlassCapsule?
    var sleepTimerCapsule: GlassCapsule?
    var lyricsCapsule: GlassCapsule?
    var queueCapsule: GlassCapsule?
    var actionCapsules: [UIView] = []
    let actionRowContainer = UIStackView()
    let transportStack = UIStackView()

    var isMorphEmbedded = false
    var isPaneMode = false
    var isFocused = false
    var onFocusRequest: ((Bool) -> Void)?
    weak var morphContainer: PlayerMorphContaining?
    var morphBackdropActive = false
    let grabberControl = UIControl()

    enum CenterState {
        case artwork
        case lyrics
        case queue
    }

    var centerState: CenterState = .artwork
    var bottomControls = UIStackView()
    let infoBlock = UIStackView()
    let titleRow = UIStackView()
    let badgeStrip = UIStackView()
    let wrappedBadgeLine = UIStackView()
    var volumeRowView = UIView()
    var layoutMode: AdaptiveLayout.PlayerLayout = .portrait
    var modeConstraints: [NSLayoutConstraint] = []
    var laptopFoldTopConstraint: NSLayoutConstraint?
    var laptopFoldBottomConstraint: NSLayoutConstraint?
    var artworkGroupTrailing: NSLayoutConstraint!
    let focusLeftColumn = UILayoutGuide()
    let focusRightColumn = UILayoutGuide()
    let laptopLyricsHost = UIView()
    let laptopQueueHost = UIView()
    var laptopLyricsChild: LyricsViewController?
    var laptopQueueChild: QueueViewController?
    var stateChildController: UIViewController?
    let centerContainer = UIView()
    let artworkGroup = UIStackView()
    let compactHeader = UIControl()
    let compactArtworkView = UIImageView()
    let compactTitleLabel = UILabel()
    let compactArtistLabel = UILabel()
    let stateContentContainer = UIView()

    var artistImageTask: Task<Void, Never>?
    var currentArtistKey: String?

    var isSeeking = false
    var chaseTime: TimeInterval = 0
    var seekGeneration = 0
    var staleScrubTicks = 0
    var lastTrackKey: String?
    var lastIsPlaying: Bool?
    var lastAppliedArtwork: UIImage?
    var peekArtworkKey: String?
    var hasAppliedInitialState = false
    var hasAnimatedAppearance = false
    var breatheAnimator: UIViewPropertyAnimator?
    var artworkRestScale: CGFloat = 1

    let peekArtworkView = UIImageView()
    var trackPanAnimator: UIViewPropertyAnimator?
    var trackPanDirection: CGFloat = 0
    var trackPanBlocked = false
    var trackPanBaseFraction: CGFloat = 0
    var trackPanCommitted = false
    var trackPanPastThreshold = false
    var isInteractiveTrackTransitionActive = false
    var deferredArtwork: UIImage??
    lazy var thresholdTickGenerator = UIImpactFeedbackGenerator(style: .light)

    enum TrackPan {
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

    static let pausedArtworkScale: CGFloat = 0.86
    static let playIconConfig = UIImage.SymbolConfiguration(pointSize: 44, weight: .bold)

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        configureSheet()
        setupBackdrop()
        setupUI()
        setupGrabberIfEmbedded()
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(equalizerStateDidChange), name: EqualizerEngine.stateDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(equalizerOutputDidChange(_:)), name: EqualizerEngine.outputDidChange, object: nil
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
        updateLayoutModeIfNeeded()
        placeBadgeStrip()
        backdropView.frame = view.bounds
        scrimLayer.frame = view.bounds
        artworkContainer.layer.shadowPath = UIBezierPath(
            roundedRect: artworkContainer.bounds, cornerRadius: 20
        ).cgPath
    }

    func configureSheet() {
        guard !isMorphEmbedded else { return }
        sheetPresentationController?.prefersGrabberVisible = true
        sheetPresentationController?.preferredCornerRadius = 32
    }

    func setupBackdrop() {
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

    func setupUI() {
        setupArtwork()
        setupInfoBlock()
        setupScrubber()
        setupTransport()

        let infoStack = infoBlock
        for row in [makeTitleRow(), makeArtistAlbumRow(), playingFromLabel] { infoStack.addArrangedSubview(row) }
        infoStack.axis = .vertical
        infoStack.spacing = 4

        let sliderStack = UIStackView(arrangedSubviews: [scrubber, makeTimeRow()])
        sliderStack.axis = .vertical
        sliderStack.spacing = 0

        for control in [skipBackButton, previousButton, playPauseButton, nextButton, skipForwardButton] {
            transportStack.addArrangedSubview(control)
        }
        transportStack.distribution = .equalSpacing
        transportStack.alignment = .center

        let volumeRow = makeVolumeRow()
        volumeRowView = volumeRow
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

        bottomControls = bottomStack
        setupLaptopCompanions()
        activateLayoutMode(.portrait, foldTop: nil, foldBottom: nil)
    }

    func setupLaptopCompanions() {
        view.addLayoutGuide(focusLeftColumn)
        view.addLayoutGuide(focusRightColumn)
        for host in [laptopLyricsHost, laptopQueueHost] {
            host.translatesAutoresizingMaskIntoConstraints = false
            host.isHidden = true
            host.clipsToBounds = true
            view.addSubview(host)
        }
        view.bringSubviewToFront(scrubBubble)
    }

    /// A sheet-style grabber pill hinting the drag-to-collapse gesture, with a
    /// generous tap target that collapses the player outright.
    func setupGrabberIfEmbedded() {
        guard isMorphEmbedded else { return }
        let pill = UIView()
        pill.backgroundColor = UIColor.white.withAlphaComponent(0.35)
        pill.layer.cornerRadius = 2.5
        pill.layer.cornerCurve = .continuous
        pill.isUserInteractionEnabled = false
        pill.translatesAutoresizingMaskIntoConstraints = false

        grabberControl.accessibilityLabel = String(localized: "Collapse player")
        grabberControl.accessibilityIdentifier = "player.collapse"
        grabberControl.accessibilityTraits = .button
        grabberControl.addAction(UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self?.morphContainer?.requestCollapse()
        }, for: .touchUpInside)
        grabberControl.translatesAutoresizingMaskIntoConstraints = false
        grabberControl.addSubview(pill)
        view.addSubview(grabberControl)

        NSLayoutConstraint.activate([
            grabberControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            grabberControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grabberControl.widthAnchor.constraint(equalToConstant: 88),
            grabberControl.heightAnchor.constraint(equalToConstant: 26),
            pill.topAnchor.constraint(equalTo: grabberControl.topAnchor, constant: 6),
            pill.centerXAnchor.constraint(equalTo: grabberControl.centerXAnchor),
            pill.widthAnchor.constraint(equalToConstant: 36),
            pill.heightAnchor.constraint(equalToConstant: 5),
        ])
    }

    override func accessibilityPerformEscape() -> Bool {
        guard isMorphEmbedded else { return false }
        morphContainer?.requestCollapse()
        return true
    }

    func setupAccessibilityOrder() {
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
        let trailing: [Any] = isMorphEmbedded ? [grabberControl] : []
        view.accessibilityElements = centerElements + [
            scrubber, currentTimeLabel, remainingTimeLabel,
            skipBackButton, previousButton, playPauseButton, nextButton, skipForwardButton,
            volumeSlider, equalizerButton,
            shuffleButton, repeatButton, airplayButton, sleepTimerButton, shareButton, lyricsButton, queueButton,
        ] + trailing
    }

    @objc func shuffleRepeatDidChange() {
        updateShuffleRepeatState()
    }

    @objc func pauseBackdrop() {
        backdropView.setPaused(true)
    }

    @objc func resumeBackdrop() {
        if isMorphEmbedded {
            guard morphBackdropActive, !scrubber.isScrubbing else { return }
            backdropView.setPaused(false)
            return
        }
        guard view.window != nil || !hasAnimatedAppearance || isBeingPresented else {
            return
        }
        guard !scrubber.isScrubbing else { return }
        backdropView.setPaused(false)
    }

    func showSleepTimerSheet() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let sheet = UIAlertController(title: String(localized: "Sleep Timer"), message: nil, preferredStyle: .actionSheet)
        for minutes in [15, 30, 45, 60] {
            sheet.addAction(UIAlertAction(title: String(localized: "\(minutes) minutes"), style: .default) { [weak self] _ in
                AudioPlayer.shared.setSleepTimer(minutes: minutes)
                self?.updateSleepTimerButton()
            })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "End of Track"), style: .default) { [weak self] _ in
            AudioPlayer.shared.setSleepTimerEndOfTrack()
            self?.updateSleepTimerButton()
        })
        if AudioPlayer.shared.sleepTimerRemaining != nil || AudioPlayer.shared.sleepAtEndOfTrack {
            sheet.addAction(UIAlertAction(title: String(localized: "Cancel Timer"), style: .destructive) { [weak self] _ in
                AudioPlayer.shared.cancelSleepTimer()
                self?.updateSleepTimerButton()
            })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        present(sheet, animated: true)
    }

    func updateSleepTimerButton() {
        let isActive = AudioPlayer.shared.sleepTimerRemaining != nil || AudioPlayer.shared.sleepAtEndOfTrack
        let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let iconName = isActive ? "moon.zzz.fill" : "moon.zzz"
        sleepTimerButton.setImage(UIImage(systemName: iconName, withConfiguration: config), for: .normal)
        sleepTimerButton.tintColor = isActive ? .white : .white.withAlphaComponent(0.7)
        sleepTimerButton.accessibilityValue = isActive ? String(localized: "Active") : String(localized: "Off")
        sleepTimerCapsule?.setActive(isActive, animated: hasAppliedInitialState)
    }

}
