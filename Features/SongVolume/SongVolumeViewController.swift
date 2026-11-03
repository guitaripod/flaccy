import FlaccyCore
import FlaccyEngine
import UIKit

/// The sheet that sets one song's own volume. Every step is heard at once
/// while the slider moves; the level is saved when it rests, and on close.
final class SongVolumeViewController: UIViewController {

    private static let sheetHeight: CGFloat = 380

    static func makePresented(for track: Track) -> SongVolumeViewController {
        let controller = SongVolumeViewController(track: track)
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.custom(identifier: .init("songVolume")) { _ in sheetHeight }, .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 38
        }
        return controller
    }

    private let track: Track
    private lazy var session = SongVolumeEditSession(track: track) { [weak self] message in
        guard let view = self?.presentingViewController?.view ?? self?.view else { return }
        ToastView.show(message, in: view, style: .error)
    }
    private let titleLabel = UILabel()
    private let songLabel = UILabel()
    private let artistLabel = UILabel()
    private let readout = UILabel()
    private let slider = UISlider()
    private let quieterButton = UIButton(type: .system)
    private let louderButton = UIButton(type: .system)
    private let scaleRow = UIStackView()
    private let explanation = UILabel()
    private let resetButton = UIButton(type: .system)
    private let selection = UISelectionFeedbackGenerator()
    private let detent = UIImpactFeedbackGenerator(style: .medium)

    init(track: Track) {
        self.track = track
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureLabels()
        configureSlider()
        configureButtons()
        layout()
        render(animated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        selection.prepare()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        session.save()
    }

    private func configureLabels() {
        titleLabel.text = SongVolumeCopy.title
        titleLabel.font = .scaled(.footnote, size: 13, weight: .semibold)
        titleLabel.textColor = .secondaryLabel
        titleLabel.textAlignment = .center

        songLabel.text = track.title
        songLabel.font = .scaled(.title3, size: 20, weight: .bold)
        songLabel.textAlignment = .center
        songLabel.numberOfLines = 2
        songLabel.adjustsFontForContentSizeCategory = true

        artistLabel.text = track.artist
        artistLabel.font = .scaled(.subheadline, size: 15, weight: .regular)
        artistLabel.textColor = .secondaryLabel
        artistLabel.textAlignment = .center
        artistLabel.adjustsFontForContentSizeCategory = true

        readout.font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(
            for: .monospacedDigitSystemFont(ofSize: 44, weight: .bold), maximumPointSize: 60
        )
        readout.textAlignment = .center
        readout.adjustsFontForContentSizeCategory = true
        readout.accessibilityTraits = .updatesFrequently

        explanation.text = SongVolumeCopy.explanation
        explanation.font = .scaled(.footnote, size: 13, weight: .regular)
        explanation.textColor = .secondaryLabel
        explanation.textAlignment = .center
        explanation.numberOfLines = 0
        explanation.adjustsFontForContentSizeCategory = true
    }

    private func configureSlider() {
        let limit = Float(SongGain.decibels(SongGain.maxTenths))
        slider.minimumValue = -limit
        slider.maximumValue = limit
        slider.value = Float(SongGain.decibels(session.level))
        slider.minimumTrackTintColor = .tintColor
        slider.accessibilityLabel = SongVolumeCopy.title
        slider.accessibilityIdentifier = "songVolume.slider"
        slider.addAction(UIAction { [weak self] _ in self?.sliderMoved() }, for: .valueChanged)
        slider.addAction(UIAction { [weak self] _ in self?.sliderReleased() }, for: [.touchUpInside, .touchUpOutside, .touchCancel])

        scaleRow.axis = .horizontal
        scaleRow.distribution = .equalSpacing
        for tenths in [-SongGain.maxTenths, 0, SongGain.maxTenths] {
            let mark = UILabel()
            mark.text = SongVolumeCopy.level(tenths)
            mark.font = .scaled(.caption2, size: 11, weight: .medium)
            mark.textColor = .tertiaryLabel
            mark.isAccessibilityElement = false
            scaleRow.addArrangedSubview(mark)
        }
    }

    private func configureButtons() {
        for (button, symbol, label, steps) in [
            (quieterButton, "minus", SongVolumeCopy.quieter, -1),
            (louderButton, "plus", SongVolumeCopy.louder, 1),
        ] {
            var configuration = UIButton.Configuration.gray()
            configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(weight: .semibold))
            configuration.cornerStyle = .capsule
            button.configuration = configuration
            button.accessibilityLabel = label
            button.addAction(UIAction { [weak self] _ in self?.step(steps) }, for: .touchUpInside)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 44),
                button.heightAnchor.constraint(equalToConstant: 44),
            ])
        }

        var reset = UIButton.Configuration.gray()
        reset.title = SongVolumeCopy.reset
        reset.cornerStyle = .capsule
        resetButton.configuration = reset
        resetButton.accessibilityIdentifier = "songVolume.reset"
        resetButton.addAction(UIAction { [weak self] _ in self?.resetLevel() }, for: .touchUpInside)
    }

    private func layout() {
        let heading = UIStackView(arrangedSubviews: [titleLabel, songLabel, artistLabel])
        heading.axis = .vertical
        heading.spacing = 4
        heading.setCustomSpacing(10, after: titleLabel)

        let sliderColumn = UIStackView(arrangedSubviews: [slider, scaleRow])
        sliderColumn.axis = .vertical
        sliderColumn.spacing = 2

        let controls = UIStackView(arrangedSubviews: [quieterButton, sliderColumn, louderButton])
        controls.axis = .horizontal
        controls.alignment = .center
        controls.spacing = 14

        let stack = UIStackView(arrangedSubviews: [heading, readout, controls, explanation, resetButton])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 18
        stack.setCustomSpacing(8, after: heading)
        stack.translatesAutoresizingMaskIntoConstraints = false
        resetButton.setContentHuggingPriority(.required, for: .vertical)
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

    private func sliderMoved() {
        let tenths = SongGain.snapped(decibels: Double(slider.value))
        let previous = session.level
        guard session.move(to: tenths) else { return }
        if tenths == 0 || previous.signum() * tenths.signum() < 0 {
            detent.impactOccurred()
        } else {
            selection.selectionChanged()
        }
        render(animated: true)
    }

    private func sliderReleased() {
        slider.setValue(Float(SongGain.decibels(session.level)), animated: true)
        session.save()
    }

    private func step(_ steps: Int) {
        let target = SongGain.stepped(session.level, by: steps)
        guard session.move(to: target) else { return }
        target == 0 ? detent.impactOccurred() : selection.selectionChanged()
        slider.setValue(Float(SongGain.decibels(target)), animated: true)
        render(animated: true)
    }

    private func resetLevel() {
        guard session.move(to: 0) else { return }
        detent.impactOccurred()
        slider.setValue(0, animated: true)
        session.save()
        render(animated: true)
    }

    private func render(animated: Bool) {
        let level = session.level
        readout.text = SongVolumeCopy.level(level)
        readout.accessibilityLabel = SongVolumeCopy.accessibilityLevel(level)
        readout.textColor = level == 0 ? .secondaryLabel : .label
        slider.accessibilityValue = SongVolumeCopy.level(level)
        resetButton.isEnabled = level != 0
        quieterButton.isEnabled = level > -SongGain.maxTenths
        louderButton.isEnabled = level < SongGain.maxTenths
        guard animated else { return }
        readout.layer.removeAllAnimations()
        UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.readout.transform = CGAffineTransform(scaleX: 1.04, y: 1.04)
        } completion: { _ in
            UIView.animate(withDuration: 0.18) { self.readout.transform = .identity }
        }
    }
}
