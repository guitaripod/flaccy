import MidgarCore
import UIKit

final class MiniPlayerView: UIView {

    static let queueTapped = Notification.Name("MiniPlayerQueueTapped")

    /// `floating` is the card with its own glass that rides above the tab bar;
    /// `accessory` is transparent and square-cornered inside, because the
    /// system's tab accessory already supplies the glass capsule around it.
    enum Style {
        case floating
        case accessory
    }

    var style: Style = .floating {
        didSet {
            guard style != oldValue else { return }
            applyStyle()
        }
    }

    private let artworkView = UIImageView()
    private let glassView = LiquidGlass.view(cornerRadius: 16)

    /// Holds the parts above the glass rather than in its content view: inside
    /// a visual effect view's content view, the system's own resize of the tab
    /// accessory snapped the row's width while its position still animated.
    private let stage = MorphLayoutView()
    private var artworkInsets: [NSLayoutConstraint] = []
    private var controlsFirstConstraints: [NSLayoutConstraint] = []
    private var controlsLastConstraints: [NSLayoutConstraint] = []
    private let textStack = MorphLayoutStackView()
    private let rowStack = MorphLayoutStackView()

    /// Which end of the dock holds play, next and the queue: the leading end,
    /// as on the iPhone, unless the window shares the screen from its trailing
    /// side, where the thumb that reaches it rests.
    private(set) var controlsSide: AdaptiveLayout.Side = .leading
    private var isCompact = false
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let playPauseButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let queueButton = UIButton(type: .system)
    private let progressFill = UIView()
    private var progressFollowsArtwork = false
    private var progressWidthConstraint: NSLayoutConstraint?
    private let timerLabel = UILabel()
    private var currentArtworkKey: String?
    private lazy var artistFolded = artistLabel.heightAnchor.constraint(equalToConstant: 0)
    private lazy var queueWidth = queueButton.widthAnchor.constraint(equalToConstant: Self.queueButtonWidth)
    private lazy var nextWidth = nextButton.widthAnchor.constraint(equalToConstant: Self.nextButtonWidth)
    private var morphLayoutUntil: CFTimeInterval = 0
    private var morphStartsAt: CFTimeInterval = 0
    private let expandElement = ExpandAccessibilityElement(accessibilityContainer: NSObject())

    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        clipsToBounds = true
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowOffset = CGSize(width: 0, height: 4)
        layer.shadowRadius = 12
        layer.masksToBounds = false

        let blur = glassView
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)
        stage.translatesAutoresizingMaskIntoConstraints = false
        stage.layer.themedCornerRadius = 16
        stage.layer.cornerCurve = .continuous
        stage.clipsToBounds = true
        addSubview(stage)
        for container in [stage, rowStack, textStack] as [any MorphLayoutHost] {
            container.morph = { [weak self] in
                guard let self, self.isMorphing else { return nil }
                return self.morphStartsAt
            }
        }

        progressFill.backgroundColor = tintColor.withAlphaComponent(0.85)
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(progressFill)

        titleLabel.font = .scaled(.footnote, size: 13, weight: .semibold, maxSize: 21)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        artistLabel.font = .scaled(.caption2, size: 11, weight: .medium, maxSize: 17)
        artistLabel.adjustsFontForContentSizeCategory = true
        artistLabel.textColor = .flaccySecondaryLabel
        artistLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        artistLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(artistLabel)
        textStack.axis = .vertical
        textStack.spacing = 0

        let buttonConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)

        playPauseButton.setImage(UIImage(systemName: "play.fill", withConfiguration: buttonConfig), for: .normal)
        playPauseButton.tintColor = .flaccyLabel
        playPauseButton.accessibilityLabel = String(localized: "Play")
        playPauseButton.addAction(UIAction { _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            AudioPlayer.shared.togglePlayPause()
        }, for: .touchUpInside)

        nextButton.setImage(UIImage(systemName: "forward.fill", withConfiguration: buttonConfig), for: .normal)
        nextButton.tintColor = .flaccyLabel
        nextButton.accessibilityLabel = String(localized: "Next track")
        nextButton.addAction(UIAction { _ in
            UISelectionFeedbackGenerator().selectionChanged()
            AudioPlayer.shared.nextTrack()
        }, for: .touchUpInside)

        let queueConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        queueButton.setImage(UIImage(systemName: "list.bullet", withConfiguration: queueConfig), for: .normal)
        queueButton.tintColor = .flaccySecondaryLabel
        queueButton.accessibilityLabel = String(localized: "Queue")
        queueButton.addAction(UIAction { _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            NotificationCenter.default.post(name: MiniPlayerView.queueTapped, object: nil)
        }, for: .touchUpInside)

        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.shapeAsCover(radius: 16)
        artworkView.layer.cornerCurve = .continuous
        artworkView.backgroundColor = .flaccyTertiaryFill
        artworkView.tintColor = .flaccySecondaryLabel
        artworkView.image = UIImage(systemName: "music.note")
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(artworkView)

        let hStack = rowStack
        hStack.spacing = Self.rowSpacing
        hStack.alignment = .center
        hStack.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(hStack)

        progressWidthConstraint = progressFill.widthAnchor.constraint(equalToConstant: 0)
        artworkInsets = [
            artworkView.topAnchor.constraint(equalTo: stage.topAnchor),
            artworkView.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            artworkView.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            artworkView.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
        ]
        NSLayoutConstraint.activate([artworkInsets[0], artworkInsets[2]])

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            stage.topAnchor.constraint(equalTo: topAnchor),
            stage.leadingAnchor.constraint(equalTo: leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: trailingAnchor),
            stage.bottomAnchor.constraint(equalTo: bottomAnchor),

            progressFill.topAnchor.constraint(equalTo: stage.topAnchor),
            progressFill.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            progressFill.heightAnchor.constraint(equalToConstant: 2.5),
            progressWidthConstraint!,

            artworkView.widthAnchor.constraint(equalTo: artworkView.heightAnchor),

            playPauseButton.widthAnchor.constraint(equalToConstant: 36),
            playPauseButton.heightAnchor.constraint(equalToConstant: 36),
            nextWidth,
            nextButton.heightAnchor.constraint(equalToConstant: 36),
            queueWidth,
            queueButton.heightAnchor.constraint(equalToConstant: 36),

            hStack.topAnchor.constraint(equalTo: stage.topAnchor),
            hStack.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
        ])

        timerLabel.font = UIFontMetrics(forTextStyle: .caption2)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 10, weight: .medium), maximumPointSize: 15)
        timerLabel.adjustsFontForContentSizeCategory = true
        timerLabel.textColor = .white
        timerLabel.textAlignment = .center
        timerLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        timerLabel.layer.themedCornerRadius = 8
        timerLabel.layer.cornerCurve = .continuous
        timerLabel.clipsToBounds = true
        timerLabel.isHidden = true
        timerLabel.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(timerLabel)

        NSLayoutConstraint.activate([
            timerLabel.topAnchor.constraint(equalTo: stage.topAnchor, constant: 4),
            timerLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 42),
            timerLabel.heightAnchor.constraint(equalToConstant: 18),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(viewTapped))
        addGestureRecognizer(tap)

        controlsFirstConstraints = [
            artworkInsets[1],
            hStack.leadingAnchor.constraint(equalTo: stage.leadingAnchor, constant: 10),
            hStack.trailingAnchor.constraint(equalTo: artworkView.leadingAnchor, constant: -10),
            timerLabel.trailingAnchor.constraint(equalTo: artworkView.leadingAnchor, constant: -6),
        ]
        controlsLastConstraints = [
            artworkInsets[3],
            hStack.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 10),
            hStack.trailingAnchor.constraint(equalTo: stage.trailingAnchor, constant: -10),
            timerLabel.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 6),
        ]
        arrangeRow()

        setupAccessibility()
        registerForCompactEnvironment()

        NotificationCenter.default.addObserver(
            self, selector: #selector(progressDidChange), name: AudioPlayer.playbackProgressDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(sleepTimerDidUpdate), name: AudioPlayer.sleepTimerDidUpdate, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(artworkDidChange), name: AlbumArtworkCache.didChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneDidActivate), name: UIScene.didActivateNotification, object: nil
        )
    }

    @objc private func sceneDidActivate() {
        refreshControlsSide()
    }

    /// Re-lays the dock for the system accessory: no glass or shadow of its own,
    /// artwork inset into the capsule as a rounded square.
    private func applyStyle() {
        let accessory = style == .accessory
        glassView.effect = accessory ? nil : LiquidGlass.effect()
        glassView.layer.cornerRadius = accessory ? 0 : 16
        stage.layer.cornerRadius = accessory ? 0 : 16
        layer.cornerRadius = accessory ? 0 : 16
        layer.shadowOpacity = accessory ? 0 : 0.15
        let inset: CGFloat = accessory ? 4 : 0
        artworkInsets[0].constant = inset
        artworkInsets[1].constant = -inset
        artworkInsets[2].constant = -inset
        artworkInsets[3].constant = inset
        artworkView.shapeAsCover(radius: accessory ? 10 : 16)
        applyArtworkCorners()
        progressFill.isHidden = accessory
        setNeedsLayout()
    }

    /// In the collapsed tab bar the accessory sits inline and is only about
    /// 180 pt wide: the queue, skip and artist line give way to the essentials.
    private func registerForCompactEnvironment() {
        guard #available(iOS 26.0, *) else { return }
        registerForTraitChanges([UITraitTabAccessoryEnvironment.self]) { (self: MiniPlayerView, _) in
            self.setCompact(self.traitCollection.tabAccessoryEnvironment == .inline, animated: self.window != nil)
            #if DEBUG
            AccessoryMorphProbe.shared?.noteEnvironment(inline: self.isCompact)
            #endif
        }
    }

    #if DEBUG
    var morphProbeParts: [(name: String, view: UIView)] {
        [("self", self), ("art", artworkView), ("play", playPauseButton), ("next", nextButton),
         ("queue", queueButton), ("title", titleLabel), ("artist", artistLabel)]
    }
    #endif

    /// The buttons the inline accessory has no room for.
    private var buttonsWithoutRoomInline: [UIView] { [queueButton, nextButton] }

    private static let foldedScale = CGAffineTransform(scaleX: 0.5, y: 0.5)

    private static let queueButtonWidth: CGFloat = 30
    private static let nextButtonWidth: CGFloat = 36
    private static let rowSpacing: CGFloat = 10

    /// The system carries the accessory between its two places on a spring of
    /// its own, so the parts that leave or return shrink and fade on the same
    /// spring while the row closes or opens around them: the play
    /// button glides to its new place with the capsule instead of jumping
    /// there once the bar has settled. The artist line fades as it folds
    /// shut, so the title settles into the middle without the line squashed
    /// under it. The system hands the accessory its new size only after this
    /// runs and lays it out with no animation, which is what made every part
    /// jump; `layoutSubviews` puts that layout on the spring too. Instant
    /// under Reduce Motion.
    private func setCompact(_ compact: Bool, animated: Bool) {
        guard compact != isCompact else { return }
        isCompact = compact
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            UIView.performWithoutAnimation {
                applyFold(compact)
                layoutIfNeeded()
            }
            return
        }
        morphStartsAt = CACurrentMediaTime() + MorphLayout.delay(goingInline: compact)
        morphLayoutUntil = morphStartsAt + MorphLayout.window
        MorphLayout.run(if: true, startingAt: morphStartsAt) {
            self.applyFold(compact)
            self.layoutIfNeeded()
        }
    }

    /// Folds the queue and skip buttons to nothing and their gaps with them,
    /// rather than hiding them: a stack view applies a hidden view's collapse
    /// outside any animation once the system resizes the accessory.
    private func applyFold(_ folded: Bool) {
        queueWidth.constant = folded ? 0 : Self.queueButtonWidth
        nextWidth.constant = folded ? 0 : Self.nextButtonWidth
        for button in buttonsWithoutRoomInline {
            button.alpha = folded ? 0 : 1
            button.transform = folded ? Self.foldedScale : .identity
        }
        let controlsFirst = controlsSide == .leading
        rowStack.setCustomSpacing(folded ? 0 : Self.rowSpacing, after: queueButton)
        rowStack.setCustomSpacing(folded ? 0 : Self.rowSpacing, after: controlsFirst ? nextButton : playPauseButton)
        foldArtistLine(folded)
        accessibilityElements = folded ? [expandElement, playPauseButton] : [expandElement, playPauseButton, nextButton, queueButton]
    }

    private func foldArtistLine(_ folded: Bool) {
        artistLabel.alpha = folded ? 0 : 1
        artistFolded.isActive = folded
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshControlsSide()
    }

    /// Moves play, next and the queue to the end of the dock the person's
    /// thumb reaches for the window as it sits now, and the artwork and title
    /// to the other end. Asked on every layout pass, which a resize, a new
    /// tile or a turn of the iPad brings, whenever the window comes forward,
    /// and with each tick of playback progress: iPadOS tells an app nothing
    /// when its window only moves, and a window dragged to the other side
    /// while music plays follows within a quarter of a second.
    func refreshControlsSide() {
        let side = reachableControlsSide(otherwise: .leading)
        guard side != controlsSide else { return }
        controlsSide = side
        arrangeRow()
        MidgarLog.debug("Mini player controls moved to the \(side) end", category: .ui)
    }

    /// True when the artwork sits at the dock's right-hand end on screen.
    var artworkIsOnRight: Bool {
        (controlsSide == .leading) == (effectiveUserInterfaceLayoutDirection == .leftToRight)
    }

    private func arrangeRow() {
        let controlsFirst = controlsSide == .leading
        NSLayoutConstraint.deactivate(controlsFirst ? controlsLastConstraints : controlsFirstConstraints)
        NSLayoutConstraint.activate(controlsFirst ? controlsFirstConstraints : controlsLastConstraints)
        for view in rowStack.arrangedSubviews { rowStack.removeArrangedSubview(view) }
        let controls: [UIView] = [queueButton, playPauseButton, nextButton]
        for view in controlsFirst ? controls + [textStack] : [textStack] + controls {
            rowStack.addArrangedSubview(view)
        }
        if !controlsFirst { rowStack.setCustomSpacing(16, after: textStack) }
        applyFold(isCompact)
        textStack.alignment = controlsFirst ? .trailing : .leading
        let alignment: NSTextAlignment = artworkIsOnRight ? .right : .left
        titleLabel.textAlignment = alignment
        artistLabel.textAlignment = alignment
        applyArtworkCorners()
        setNeedsLayout()
    }

    /// The accessory's artwork is a rounded square; the floating card's is
    /// flush with the card's own rounded end.
    private func applyArtworkCorners() {
        guard style == .floating else {
            artworkView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            return
        }
        artworkView.layer.maskedCorners = artworkIsOnRight
            ? [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMinXMaxYCorner]
    }

    @objc private func artworkDidChange() {
        guard let track = AudioPlayer.shared.currentTrack else { return }
        configure(with: track, isPlaying: AudioPlayer.shared.isPlaying)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupAccessibility() {
        isAccessibilityElement = false
        expandElement.accessibilityContainer = self
        expandElement.accessibilityTraits = .button
        expandElement.accessibilityIdentifier = "player.expand"
        expandElement.accessibilityHint = String(localized: "Opens Now Playing")
        expandElement.onActivate = { [weak self] in self?.onTap?() }
        accessibilityElements = [expandElement, playPauseButton, nextButton, queueButton]
    }

    override func layoutSubviews() {
        MorphLayout.run(if: isMorphing, startingAt: morphStartsAt) { super.layoutSubviews() }
        refreshControlsSide()
        expandElement.accessibilityFrameInContainerSpace = bounds
    }

    /// True for the moments after the accessory changed place, while the
    /// system hands it its new size and lays it out with no animation: every
    /// layout in the player then rides the same spring as the parts that
    /// leave or return.
    private var isMorphing: Bool {
        CACurrentMediaTime() < morphLayoutUntil
    }

    /// The dock's current album image, or nil while it still shows the
    /// music-note placeholder, so the morph proxy never flies a glyph.
    var currentArtwork: UIImage? {
        artworkView.contentMode == .scaleAspectFill ? artworkView.image : nil
    }

    /// Toggles only the dock artwork's visibility so the morph proxy can take
    /// over the artwork during a transition while the rest of the dock chrome
    /// cross-fades independently.
    func setMorphArtworkHidden(_ hidden: Bool) {
        artworkView.alpha = hidden ? 0 : 1
    }

    func configure(with track: Track, isPlaying: Bool) {
        titleLabel.text = track.title
        artistLabel.text = track.artist
        expandElement.accessibilityLabel = "\(track.title), \(track.artist)"

        updateProgressBar()

        let requestedKey = track.albumTitle + "\u{0}" + track.artist
        currentArtworkKey = requestedKey

        let cached = track.artwork
            ?? AlbumArtworkCache.shared.thumbnail(forAlbum: track.albumTitle, artist: track.artist)

        if let artwork = cached {
            applyArtwork(artwork)
        } else {
            artworkView.contentMode = .center
            artworkView.image = UIImage(systemName: "music.note")
            progressFollowsArtwork = false
            progressFill.backgroundColor = tintColor.withAlphaComponent(0.85)

            AlbumArtworkCache.shared.loadThumbnail(forAlbum: track.albumTitle, artist: track.artist) { [weak self] image in
                guard let self, let image, self.currentArtworkKey == requestedKey else { return }
                self.applyArtwork(image)
            }
        }

        let icon = isPlaying ? "pause.fill" : "play.fill"
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        playPauseButton.setImage(UIImage(systemName: icon, withConfiguration: config), for: .normal)
        playPauseButton.accessibilityLabel = isPlaying ? String(localized: "Pause") : String(localized: "Play")
    }

    private func updateProgressBar() {
        let player = AudioPlayer.shared
        if player.duration > 0 {
            progressWidthConstraint?.constant = bounds.width * CGFloat(player.currentTime / player.duration)
        } else {
            progressWidthConstraint?.constant = 0
        }
    }

    private func applyArtwork(_ artwork: UIImage) {
        artworkView.contentMode = .scaleAspectFill
        artworkView.image = artwork
        updateProgressColor(from: artwork)
    }

    private func updateProgressColor(from image: UIImage) {
        guard let cgImage = image.cgImage else { return }
        let size = 8
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        var totalR: CGFloat = 0
        var totalG: CGFloat = 0
        var totalB: CGFloat = 0
        let count = size * size
        for i in 0..<count {
            totalR += CGFloat(pixels[i * 4])
            totalG += CGFloat(pixels[i * 4 + 1])
            totalB += CGFloat(pixels[i * 4 + 2])
        }

        let color = UIColor(
            red: totalR / CGFloat(count) / 255,
            green: totalG / CGFloat(count) / 255,
            blue: totalB / CGFloat(count) / 255,
            alpha: 0.9
        )
        progressFollowsArtwork = true
        progressFill.backgroundColor = color
    }

    /// Without a cover to take a color from, the progress line wears the accent.
    override func tintColorDidChange() {
        super.tintColorDidChange()
        guard !progressFollowsArtwork else { return }
        progressFill.backgroundColor = tintColor.withAlphaComponent(0.85)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        setPressed(true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        setPressed(false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        setPressed(false)
    }

    /// Springs the whole surface to 0.98 while pressed, mirroring the Now
    /// Playing card press language; instant under Reduce Motion.
    private func setPressed(_ pressed: Bool) {
        let transform = pressed ? CGAffineTransform(scaleX: 0.98, y: 0.98) : .identity
        guard !UIAccessibility.isReduceMotionEnabled else {
            self.transform = transform
            return
        }
        let animator = UIViewPropertyAnimator(duration: pressed ? 0.16 : 0.32, dampingRatio: pressed ? 1 : 0.72) {
            self.transform = transform
        }
        animator.startAnimation()
    }

    @objc private func viewTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onTap?()
    }

    @objc private func progressDidChange() {
        updateProgressBar()
        refreshControlsSide()
    }

    @objc private func sleepTimerDidUpdate() {
        if AudioPlayer.shared.sleepAtEndOfTrack {
            timerLabel.text = String(localized: " End of track ")
            timerLabel.accessibilityLabel = String(localized: "Sleep timer, at end of track")
            timerLabel.isHidden = false
            return
        }
        guard let remaining = AudioPlayer.shared.sleepTimerRemaining, remaining > 0 else {
            timerLabel.isHidden = true
            return
        }
        let mins = Int(remaining) / 60
        let secs = Int(remaining) % 60
        timerLabel.text = " \(String(format: "%d:%02d", mins, secs)) "
        timerLabel.accessibilityLabel = String(localized: "Sleep timer, \(mins) minutes \(secs) seconds remaining")
        timerLabel.isHidden = false
    }
}

private final class ExpandAccessibilityElement: UIAccessibilityElement {
    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        onActivate?()
        return true
    }
}

/// The spring the mini player's parts ride while the tab accessory changes
/// place, fitted to the system's own move of the capsule from the probe's
/// frames on iOS 27: a 0.36 s response at a damping of 0.71, starting 20 ms
/// after the accessory is told it is going inline and 52 ms after it is told
/// it is coming back.
enum MorphLayout {

    static let duration: TimeInterval = 0.36

    static let bounce: CGFloat = 0.29

    static func delay(goingInline: Bool) -> TimeInterval { goingInline ? 0.02 : 0.052 }

    /// How long after the accessory starts to move its new size may still
    /// arrive, a little longer than the spring takes to settle.
    static let window: TimeInterval = 0.6

    /// Runs `changes` on the spring, starting at `start`, when `animated` and
    /// no animation is already carrying them, else as they are. The system
    /// tells the player it is going inline from inside
    /// `performWithoutAnimation`, so the spring turns animations back on for
    /// its own changes.
    static func run(if animated: Bool, startingAt start: CFTimeInterval = 0, _ changes: @escaping () -> Void) {
        guard animated, UIView.inheritedAnimationDuration == 0, !UIAccessibility.isReduceMotionEnabled else {
            changes()
            return
        }
        let wereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(true)
        UIView.animate(
            springDuration: duration, bounce: bounce, initialSpringVelocity: 0,
            delay: max(start - CACurrentMediaTime(), 0), options: .allowUserInteraction, animations: changes
        )
        UIView.setAnimationsEnabled(wereEnabled)
    }
}

/// A container in the mini player that lays out on the morph spring while
/// its player is changing place.
protocol MorphLayoutHost: AnyObject {
    /// When the player's move started, or nil while it is not moving.
    var morph: () -> CFTimeInterval? { get set }
}

final class MorphLayoutView: UIView, MorphLayoutHost {
    var morph: () -> CFTimeInterval? = { nil }

    override func layoutSubviews() {
        let start = morph()
        MorphLayout.run(if: start != nil, startingAt: start ?? 0) { super.layoutSubviews() }
    }
}

final class MorphLayoutStackView: UIStackView, MorphLayoutHost {
    var morph: () -> CFTimeInterval? = { nil }

    override func layoutSubviews() {
        let start = morph()
        MorphLayout.run(if: start != nil, startingAt: start ?? 0) { super.layoutSubviews() }
    }
}
