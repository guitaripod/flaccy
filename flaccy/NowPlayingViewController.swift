import AVFoundation
import AVKit
import Combine
import UIKit

final class NowPlayingViewController: UIViewController {

    private let viewModel = NowPlayingViewModel()
    private var cancellables = Set<AnyCancellable>()

    private let artworkView = UIImageView()
    private let artworkContainer = UIView()
    private let titleLabel = UILabel()
    private let artistAlbumLabel = UILabel()
    private let progressSlider = UISlider()
    private let currentTimeLabel = UILabel()
    private let remainingTimeLabel = UILabel()
    private let previousButton = UIButton(type: .system)
    private let playPauseButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let shuffleButton = UIButton(type: .system)
    private let repeatButton = UIButton(type: .system)
    private let playingFromLabel = UILabel()
    private let airplayButton = AVRoutePickerView(frame: .zero)
    private let sleepTimerButton = UIButton(type: .system)
    private let queueButton = UIButton(type: .system)
    private var isSliderDragging = false
    private var isSeeking = false
    private var chaseTime: TimeInterval = 0

    private lazy var smallThumb = makeThumbImage(size: 6)
    private lazy var largeThumb = makeThumbImage(size: 20)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
        bindViewModel()
        applyState(viewModel.currentState)
        updateShuffleRepeatState()

        NotificationCenter.default.addObserver(
            self, selector: #selector(shuffleRepeatDidChange), name: AudioPlayer.shuffleRepeatDidChange, object: nil
        )
    }

    private func setupUI() {
        let dragHandle = UIView()
        dragHandle.backgroundColor = .quaternaryLabel
        dragHandle.layer.cornerRadius = 2.5

        let topSpacer = UIView()

        airplayButton.tintColor = .secondaryLabel
        airplayButton.activeTintColor = .systemBlue
        airplayButton.translatesAutoresizingMaskIntoConstraints = false

        sleepTimerButton.setImage(
            UIImage(systemName: "moon.zzz", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)),
            for: .normal
        )
        sleepTimerButton.tintColor = .secondaryLabel
        sleepTimerButton.addAction(UIAction { [weak self] _ in self?.showSleepTimerSheet() }, for: .touchUpInside)

        queueButton.setImage(
            UIImage(systemName: "list.bullet", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)),
            for: .normal
        )
        queueButton.tintColor = .secondaryLabel
        queueButton.addAction(UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self?.presentQueue()
        }, for: .touchUpInside)

        let topRow = UIStackView(arrangedSubviews: [dragHandle, topSpacer, airplayButton, sleepTimerButton, queueButton])
        topRow.alignment = .center
        topRow.spacing = 16

        artworkContainer.layer.shadowColor = UIColor.black.cgColor
        artworkContainer.layer.shadowOpacity = 0.25
        artworkContainer.layer.shadowOffset = CGSize(width: 0, height: 10)
        artworkContainer.layer.shadowRadius = 30

        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.layer.cornerRadius = 14
        artworkView.layer.cornerCurve = .continuous
        artworkView.backgroundColor = .tertiarySystemFill
        artworkView.image = UIImage(systemName: "music.note")
        artworkView.tintColor = .quaternaryLabel
        artworkView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 48, weight: .ultraLight)
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkContainer.addSubview(artworkView)

        NSLayoutConstraint.activate([
            artworkView.topAnchor.constraint(equalTo: artworkContainer.topAnchor),
            artworkView.leadingAnchor.constraint(equalTo: artworkContainer.leadingAnchor),
            artworkView.trailingAnchor.constraint(equalTo: artworkContainer.trailingAnchor),
            artworkView.bottomAnchor.constraint(equalTo: artworkContainer.bottomAnchor),
            artworkView.heightAnchor.constraint(equalTo: artworkView.widthAnchor),
        ])

        artworkContainer.isUserInteractionEnabled = true
        let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeLeft))
        swipeLeft.direction = .left
        artworkContainer.addGestureRecognizer(swipeLeft)
        let swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeRight))
        swipeRight.direction = .right
        artworkContainer.addGestureRecognizer(swipeRight)

        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail

        artistAlbumLabel.font = .systemFont(ofSize: 16, weight: .regular)
        artistAlbumLabel.textColor = .secondaryLabel

        playingFromLabel.font = .systemFont(ofSize: 12, weight: .regular)
        playingFromLabel.textColor = .tertiaryLabel
        playingFromLabel.isHidden = true

        let infoStack = UIStackView(arrangedSubviews: [titleLabel, artistAlbumLabel, playingFromLabel])
        infoStack.axis = .vertical
        infoStack.spacing = 4

        progressSlider.minimumTrackTintColor = .label
        progressSlider.maximumTrackTintColor = .quaternaryLabel
        progressSlider.setThumbImage(smallThumb, for: .normal)
        progressSlider.setThumbImage(largeThumb, for: .highlighted)
        progressSlider.addTarget(self, action: #selector(sliderTouchDown), for: .touchDown)
        progressSlider.addTarget(self, action: #selector(sliderTouchUp), for: [.touchUpInside, .touchUpOutside])
        progressSlider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)

        let timeFont = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        currentTimeLabel.font = timeFont
        currentTimeLabel.textColor = .tertiaryLabel
        currentTimeLabel.text = "0:00"
        remainingTimeLabel.font = timeFont
        remainingTimeLabel.textColor = .tertiaryLabel
        remainingTimeLabel.text = "-0:00"
        remainingTimeLabel.textAlignment = .right

        let timeSpacer = UIView()
        let timeStack = UIStackView(arrangedSubviews: [currentTimeLabel, timeSpacer, remainingTimeLabel])

        let sliderStack = UIStackView(arrangedSubviews: [progressSlider, timeStack])
        sliderStack.axis = .vertical
        sliderStack.spacing = 4

        let transportConfig = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        let playConfig = UIImage.SymbolConfiguration(pointSize: 48, weight: .bold)
        let secondaryConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)

        previousButton.setImage(UIImage(systemName: "backward.fill", withConfiguration: transportConfig), for: .normal)
        previousButton.tintColor = .label
        previousButton.addAction(UIAction { [weak self] _ in self?.viewModel.previousTrack() }, for: .touchUpInside)

        playPauseButton.setImage(UIImage(systemName: "play.fill", withConfiguration: playConfig), for: .normal)
        playPauseButton.tintColor = .label
        playPauseButton.addAction(UIAction { [weak self] _ in self?.viewModel.togglePlayPause() }, for: .touchUpInside)

        nextButton.setImage(UIImage(systemName: "forward.fill", withConfiguration: transportConfig), for: .normal)
        nextButton.tintColor = .label
        nextButton.addAction(UIAction { [weak self] _ in self?.viewModel.nextTrack() }, for: .touchUpInside)

        shuffleButton.setImage(UIImage(systemName: "shuffle", withConfiguration: secondaryConfig), for: .normal)
        shuffleButton.addAction(UIAction { [weak self] _ in
            AudioPlayer.shared.toggleShuffle()
            self?.updateShuffleRepeatState()
        }, for: .touchUpInside)

        repeatButton.setImage(UIImage(systemName: "repeat", withConfiguration: secondaryConfig), for: .normal)
        repeatButton.addAction(UIAction { [weak self] _ in
            AudioPlayer.shared.cycleRepeatMode()
            self?.updateShuffleRepeatState()
        }, for: .touchUpInside)

        let controlsStack = UIStackView(arrangedSubviews: [
            shuffleButton, previousButton, playPauseButton, nextButton, repeatButton,
        ])
        controlsStack.distribution = .equalSpacing
        controlsStack.alignment = .center

        let mainStack = UIStackView(arrangedSubviews: [
            topRow, artworkContainer, infoStack, sliderStack, controlsStack,
        ])
        mainStack.axis = .vertical
        mainStack.spacing = 24
        mainStack.setCustomSpacing(12, after: topRow)
        mainStack.setCustomSpacing(28, after: artworkContainer)
        mainStack.setCustomSpacing(32, after: sliderStack)
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mainStack)

        NSLayoutConstraint.activate([
            dragHandle.widthAnchor.constraint(equalToConstant: 36),
            dragHandle.heightAnchor.constraint(equalToConstant: 5),
            airplayButton.widthAnchor.constraint(equalToConstant: 36),
            airplayButton.heightAnchor.constraint(equalToConstant: 36),

            mainStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            mainStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            mainStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
        ])
    }

    private func bindViewModel() {
        viewModel.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.applyState(state) }
            .store(in: &cancellables)
    }

    private func applyState(_ state: NowPlayingViewModel.State) {
        titleLabel.text = state.title
        artistAlbumLabel.text = state.artistAlbum

        if state.albumTitle.isEmpty {
            playingFromLabel.text = ""
            playingFromLabel.isHidden = true
        } else {
            playingFromLabel.text = "Playing from \(state.albumTitle)"
            playingFromLabel.isHidden = false
        }

        if let image = state.artwork as? UIImage {
            artworkView.contentMode = .scaleAspectFill
            artworkView.image = image
        } else {
            artworkView.contentMode = .center
            artworkView.image = UIImage(systemName: "music.note")
        }

        let icon = state.isPlaying ? "pause.fill" : "play.fill"
        let playConfig = UIImage.SymbolConfiguration(pointSize: 48, weight: .bold)
        playPauseButton.setImage(UIImage(systemName: icon, withConfiguration: playConfig), for: .normal)

        if !isSliderDragging {
            progressSlider.maximumValue = Float(state.duration)
            progressSlider.value = Float(state.currentTime)
        }
        currentTimeLabel.text = state.currentTimeFormatted
        remainingTimeLabel.text = state.remainingTimeFormatted
    }

    private func makeThumbImage(size: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            UIColor.label.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
        }
    }

    private func updateShuffleRepeatState() {
        let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        shuffleButton.tintColor = AudioPlayer.shared.shuffleEnabled ? .systemBlue : .tertiaryLabel

        switch AudioPlayer.shared.repeatMode {
        case .off:
            repeatButton.setImage(UIImage(systemName: "repeat", withConfiguration: config), for: .normal)
            repeatButton.tintColor = .tertiaryLabel
        case .all:
            repeatButton.setImage(UIImage(systemName: "repeat", withConfiguration: config), for: .normal)
            repeatButton.tintColor = .systemBlue
        case .one:
            repeatButton.setImage(UIImage(systemName: "repeat.1", withConfiguration: config), for: .normal)
            repeatButton.tintColor = .systemBlue
        }
    }

    private func presentQueue() {
        let queueVC = QueueViewController()
        let nav = UINavigationController(rootViewController: queueVC)
        nav.modalPresentationStyle = .pageSheet
        present(nav, animated: true)
    }

    @objc private func sliderTouchDown() {
        isSliderDragging = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func sliderTouchUp() {
        isSliderDragging = false
        let targetTime = TimeInterval(progressSlider.value)
        chaseTime = targetTime
        seekToChaseTime()
    }

    @objc private func sliderChanged() {
        let time = TimeInterval(progressSlider.value)
        chaseTime = time
        updateTimeLabelsFromSlider(time)
        if !isSeeking {
            seekToChaseTime()
        }
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
            let remaining = AudioPlayer.shared.duration - AudioPlayer.shared.currentTime
            let minutes = max(1, Int(ceil(remaining / 60)))
            AudioPlayer.shared.setSleepTimer(minutes: minutes)
            self?.updateSleepTimerButton()
        })
        if AudioPlayer.shared.sleepTimerRemaining != nil {
            sheet.addAction(UIAlertAction(title: "Cancel Timer", style: .destructive) { [weak self] _ in
                AudioPlayer.shared.cancelSleepTimer()
                self?.updateSleepTimerButton()
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    private func updateSleepTimerButton() {
        let isActive = AudioPlayer.shared.sleepTimerRemaining != nil
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        let iconName = isActive ? "moon.zzz.fill" : "moon.zzz"
        sleepTimerButton.setImage(UIImage(systemName: iconName, withConfiguration: config), for: .normal)
        sleepTimerButton.tintColor = isActive ? .systemBlue : .secondaryLabel
    }

    @objc private func handleSwipeLeft() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        UIView.animate(withDuration: 0.15, animations: {
            self.artworkView.transform = CGAffineTransform(translationX: -30, y: 0).scaledBy(x: 0.95, y: 0.95)
            self.artworkView.alpha = 0.5
        }) { _ in
            self.viewModel.nextTrack()
            self.artworkView.transform = CGAffineTransform(translationX: 30, y: 0).scaledBy(x: 0.95, y: 0.95)
            UIView.animate(withDuration: 0.2) {
                self.artworkView.transform = .identity
                self.artworkView.alpha = 1
            }
        }
    }

    @objc private func handleSwipeRight() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        UIView.animate(withDuration: 0.15, animations: {
            self.artworkView.transform = CGAffineTransform(translationX: 30, y: 0).scaledBy(x: 0.95, y: 0.95)
            self.artworkView.alpha = 0.5
        }) { _ in
            self.viewModel.previousTrack()
            self.artworkView.transform = CGAffineTransform(translationX: -30, y: 0).scaledBy(x: 0.95, y: 0.95)
            UIView.animate(withDuration: 0.2) {
                self.artworkView.transform = .identity
                self.artworkView.alpha = 1
            }
        }
    }
}
