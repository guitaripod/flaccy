import UIKit

final class MiniPlayerView: UIView {

    static let queueTapped = Notification.Name("MiniPlayerQueueTapped")

    private let artworkView = UIImageView()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let playPauseButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let queueButton = UIButton(type: .system)
    private let progressFill = UIView()
    private var progressWidthConstraint: NSLayoutConstraint?
    private let timerLabel = UILabel()
    private var currentArtworkKey: String?
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

        let blur = LiquidGlass.view(cornerRadius: 16)
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        progressFill.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(progressFill)

        titleLabel.font = .scaled(.footnote, size: 13, weight: .semibold, maxSize: 21)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        artistLabel.font = .scaled(.caption2, size: 11, weight: .medium, maxSize: 17)
        artistLabel.adjustsFontForContentSizeCategory = true
        artistLabel.textColor = .secondaryLabel
        artistLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        artistLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        titleLabel.textAlignment = .right
        artistLabel.textAlignment = .right

        let textStack = UIStackView(arrangedSubviews: [titleLabel, artistLabel])
        textStack.axis = .vertical
        textStack.spacing = 0
        textStack.alignment = .trailing

        let buttonConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)

        playPauseButton.setImage(UIImage(systemName: "play.fill", withConfiguration: buttonConfig), for: .normal)
        playPauseButton.tintColor = .label
        playPauseButton.accessibilityLabel = "Play"
        playPauseButton.addAction(UIAction { _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            AudioPlayer.shared.togglePlayPause()
        }, for: .touchUpInside)

        nextButton.setImage(UIImage(systemName: "forward.fill", withConfiguration: buttonConfig), for: .normal)
        nextButton.tintColor = .label
        nextButton.accessibilityLabel = "Next track"
        nextButton.addAction(UIAction { _ in
            UISelectionFeedbackGenerator().selectionChanged()
            AudioPlayer.shared.nextTrack()
        }, for: .touchUpInside)

        let queueConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        queueButton.setImage(UIImage(systemName: "list.bullet", withConfiguration: queueConfig), for: .normal)
        queueButton.tintColor = .secondaryLabel
        queueButton.accessibilityLabel = "Queue"
        queueButton.addAction(UIAction { _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            NotificationCenter.default.post(name: MiniPlayerView.queueTapped, object: nil)
        }, for: .touchUpInside)

        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.layer.cornerRadius = 16
        artworkView.layer.cornerCurve = .continuous
        artworkView.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        artworkView.backgroundColor = .tertiarySystemFill
        artworkView.tintColor = .secondaryLabel
        artworkView.image = UIImage(systemName: "music.note")
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(artworkView)

        let hStack = UIStackView(arrangedSubviews: [queueButton, playPauseButton, nextButton, textStack])
        hStack.spacing = 10
        hStack.alignment = .center
        hStack.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(hStack)

        progressWidthConstraint = progressFill.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),

            progressFill.topAnchor.constraint(equalTo: blur.contentView.topAnchor),
            progressFill.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor),
            progressFill.heightAnchor.constraint(equalToConstant: 2.5),
            progressWidthConstraint!,

            artworkView.topAnchor.constraint(equalTo: blur.contentView.topAnchor),
            artworkView.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor),
            artworkView.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor),
            artworkView.widthAnchor.constraint(equalTo: artworkView.heightAnchor),

            playPauseButton.widthAnchor.constraint(equalToConstant: 36),
            playPauseButton.heightAnchor.constraint(equalToConstant: 36),
            nextButton.widthAnchor.constraint(equalToConstant: 36),
            nextButton.heightAnchor.constraint(equalToConstant: 36),
            queueButton.widthAnchor.constraint(equalToConstant: 30),
            queueButton.heightAnchor.constraint(equalToConstant: 36),

            hStack.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 10),
            hStack.trailingAnchor.constraint(equalTo: artworkView.leadingAnchor, constant: -10),
            hStack.topAnchor.constraint(equalTo: blur.contentView.topAnchor),
            hStack.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor),
        ])

        timerLabel.font = UIFontMetrics(forTextStyle: .caption2)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 10, weight: .medium), maximumPointSize: 15)
        timerLabel.adjustsFontForContentSizeCategory = true
        timerLabel.textColor = .white
        timerLabel.textAlignment = .center
        timerLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        timerLabel.layer.cornerRadius = 8
        timerLabel.layer.cornerCurve = .continuous
        timerLabel.clipsToBounds = true
        timerLabel.isHidden = true
        timerLabel.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(timerLabel)

        NSLayoutConstraint.activate([
            timerLabel.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: 4),
            timerLabel.trailingAnchor.constraint(equalTo: artworkView.leadingAnchor, constant: -6),
            timerLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 42),
            timerLabel.heightAnchor.constraint(equalToConstant: 18),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(viewTapped))
        addGestureRecognizer(tap)

        setupAccessibility()

        NotificationCenter.default.addObserver(
            self, selector: #selector(progressDidChange), name: AudioPlayer.playbackProgressDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(sleepTimerDidUpdate), name: AudioPlayer.sleepTimerDidUpdate, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupAccessibility() {
        isAccessibilityElement = false
        expandElement.accessibilityContainer = self
        expandElement.accessibilityTraits = .button
        expandElement.accessibilityHint = "Opens Now Playing"
        expandElement.onActivate = { [weak self] in self?.onTap?() }
        accessibilityElements = [expandElement, playPauseButton, nextButton, queueButton]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        expandElement.accessibilityFrameInContainerSpace = bounds
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
            ?? AlbumArtworkCache.shared.artwork(forAlbum: track.albumTitle, artist: track.artist)

        if let artwork = cached {
            applyArtwork(artwork)
        } else {
            artworkView.contentMode = .center
            artworkView.image = UIImage(systemName: "music.note")
            progressFill.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)

            AlbumArtworkCache.shared.loadArtwork(forAlbum: track.albumTitle, artist: track.artist) { [weak self] image in
                guard let self, let image, self.currentArtworkKey == requestedKey else { return }
                self.applyArtwork(image)
            }
        }

        let icon = isPlaying ? "pause.fill" : "play.fill"
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        playPauseButton.setImage(UIImage(systemName: icon, withConfiguration: config), for: .normal)
        playPauseButton.accessibilityLabel = isPlaying ? "Pause" : "Play"
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
        progressFill.backgroundColor = color
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
    }

    @objc private func sleepTimerDidUpdate() {
        if AudioPlayer.shared.sleepAtEndOfTrack {
            timerLabel.text = " End of track "
            timerLabel.accessibilityLabel = "Sleep timer, at end of track"
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
        timerLabel.accessibilityLabel = "Sleep timer, \(mins) minutes \(secs) seconds remaining"
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
