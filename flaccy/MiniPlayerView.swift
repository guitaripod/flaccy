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

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 16
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true
        addSubview(blur)

        progressFill.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(progressFill)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        artistLabel.font = .systemFont(ofSize: 10, weight: .regular)
        artistLabel.textColor = .secondaryLabel
        artistLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        artistLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        titleLabel.textAlignment = .right
        artistLabel.textAlignment = .right

        let textStack = UIStackView(arrangedSubviews: [titleLabel, artistLabel])
        textStack.axis = .vertical
        textStack.spacing = 1
        textStack.alignment = .trailing

        let buttonConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)

        playPauseButton.setImage(UIImage(systemName: "play.fill", withConfiguration: buttonConfig), for: .normal)
        playPauseButton.tintColor = .label
        playPauseButton.addAction(UIAction { _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            AudioPlayer.shared.togglePlayPause()
        }, for: .touchUpInside)

        nextButton.setImage(UIImage(systemName: "forward.fill", withConfiguration: buttonConfig), for: .normal)
        nextButton.tintColor = .label
        nextButton.addAction(UIAction { _ in
            UISelectionFeedbackGenerator().selectionChanged()
            AudioPlayer.shared.nextTrack()
        }, for: .touchUpInside)

        let queueConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        queueButton.setImage(UIImage(systemName: "list.bullet", withConfiguration: queueConfig), for: .normal)
        queueButton.tintColor = .secondaryLabel
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
            progressFill.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor),
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

        let tap = UITapGestureRecognizer(target: self, action: #selector(viewTapped))
        addGestureRecognizer(tap)

        NotificationCenter.default.addObserver(
            self, selector: #selector(progressDidChange), name: AudioPlayer.playbackProgressDidChange, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with track: Track, isPlaying: Bool) {
        titleLabel.text = track.title
        artistLabel.text = track.artist
        if let artwork = track.artwork {
            artworkView.contentMode = .scaleAspectFill
            artworkView.image = artwork
            updateProgressColor(from: artwork)
        } else {
            artworkView.contentMode = .center
            artworkView.image = UIImage(systemName: "music.note")
            progressFill.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
        }
        let icon = isPlaying ? "pause.fill" : "play.fill"
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        playPauseButton.setImage(UIImage(systemName: icon, withConfiguration: config), for: .normal)
    }

    private func updateProgressColor(from image: UIImage) {
        guard let cgImage = image.cgImage else { return }
        let width = 1
        let height = 1
        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixel, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let color = UIColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 0.15
        )
        progressFill.backgroundColor = color
    }

    @objc private func viewTapped() {
        onTap?()
    }

    @objc private func progressDidChange() {
        let player = AudioPlayer.shared
        guard player.duration > 0 else { return }
        let fraction = CGFloat(player.currentTime / player.duration)
        progressWidthConstraint?.constant = bounds.width * fraction
    }
}
