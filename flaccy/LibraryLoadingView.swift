import FlaccyCore
import UIKit

/// The first-launch indexing screen: a determinate ring, the stage the scan is
/// in, and live tallies of what has been found. Shown only while there is no
/// library to look at yet — once anything is on the shelves the scan moves to
/// `LibraryScanBanner` instead.
final class LibraryLoadingView: UIView {

    private let wordmark = UILabel()
    private let ringView = ProgressRingView()
    private let headline = UILabel()
    private let explanation = UILabel()
    private let statsRow = StatsRowView()
    private let reassurance = UILabel()

    private var lastAnnouncedPhase: LibraryLoadPhase = .idle
    private var reassuranceWorkItem: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        setupSubviews()
        configureAccessibility()
        scheduleReassurance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        reassuranceWorkItem?.cancel()
    }

    private func setupSubviews() {
        wordmark.text = "flaccy"
        wordmark.font = .scaled(.title1, size: 28, weight: .bold)
        wordmark.adjustsFontForContentSizeCategory = true
        wordmark.textAlignment = .center

        headline.font = .scaled(.title3, size: 20, weight: .semibold)
        headline.adjustsFontForContentSizeCategory = true
        headline.textAlignment = .center
        headline.numberOfLines = 2

        explanation.font = .preferredFont(forTextStyle: .footnote)
        explanation.adjustsFontForContentSizeCategory = true
        explanation.textColor = .secondaryLabel
        explanation.textAlignment = .center
        explanation.numberOfLines = 3

        reassurance.font = .preferredFont(forTextStyle: .caption1)
        reassurance.adjustsFontForContentSizeCategory = true
        reassurance.textColor = .tertiaryLabel
        reassurance.textAlignment = .center
        reassurance.numberOfLines = 2
        reassurance.text = String(localized: "Everything is indexed on this device — this only takes a moment the first time.")
        reassurance.alpha = 0

        let textStack = UIStackView(arrangedSubviews: [headline, explanation])
        textStack.axis = .vertical
        textStack.spacing = 6
        textStack.alignment = .fill

        let stack = UIStackView(arrangedSubviews: [wordmark, ringView, textStack, statsRow])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 24
        stack.setCustomSpacing(28, after: ringView)
        stack.setCustomSpacing(28, after: textStack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        reassurance.translatesAutoresizingMaskIntoConstraints = false
        addSubview(reassurance)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -32),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
            textStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statsRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            reassurance.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            reassurance.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            reassurance.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -28),
        ])
    }

    private func configureAccessibility() {
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
        accessibilityLabel = String(localized: "Setting up your library")
        accessibilityValue = ""
    }

    /// Fades in the "only the first time" note once a scan has clearly outlived
    /// a glance, so a fast launch never shows it at all.
    private func scheduleReassurance() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            UIView.animate(withDuration: 0.4) { self.reassurance.alpha = 1 }
        }
        reassuranceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    func update(progress: LibraryLoadProgress, fraction: Double) {
        headline.text = LibraryLoadPhaseCopy.headline(for: progress.phase)
        explanation.text = LibraryLoadPhaseCopy.explanation(for: progress.phase)
        ringView.setProgress(fraction, determinate: progress.isDeterminate, detail: LibraryLoadPhaseCopy.detail(for: progress))
        statsRow.update(progress: progress)
        accessibilityValue = LibraryLoadPhaseCopy.accessibilityValue(for: progress, fraction: fraction)
        announcePhaseChangeIfNeeded(progress.phase)
    }

    private func announcePhaseChangeIfNeeded(_ phase: LibraryLoadPhase) {
        guard phase != lastAnnouncedPhase, UIAccessibility.isVoiceOverRunning else {
            lastAnnouncedPhase = phase
            return
        }
        lastAnnouncedPhase = phase
        UIAccessibility.post(notification: .announcement, argument: LibraryLoadPhaseCopy.headline(for: phase))
    }
}

/// A circular determinate progress ring with the percentage and the current
/// count inside it; falls back to a sweeping arc when the work is uncountable.
private final class ProgressRingView: UIView {

    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()
    private let percentLabel = UILabel()
    private let detailLabel = UILabel()
    private var isSweeping = false

    private static let diameter: CGFloat = 156
    private static let lineWidth: CGFloat = 10

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        track.fillColor = nil
        track.lineWidth = Self.lineWidth
        track.lineCap = .round
        progress.fillColor = nil
        progress.lineWidth = Self.lineWidth
        progress.lineCap = .round
        progress.strokeEnd = 0
        layer.addSublayer(track)
        layer.addSublayer(progress)
        applyStrokeColors()

        percentLabel.font = .scaled(.largeTitle, size: 40, weight: .semibold).monospacedDigits
        percentLabel.adjustsFontForContentSizeCategory = true
        percentLabel.textAlignment = .center
        percentLabel.text = "0%"

        detailLabel.font = .scaled(.caption1, size: 12, weight: .medium).monospacedDigits
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 1
        detailLabel.adjustsFontSizeToFitWidth = true
        detailLabel.minimumScaleFactor = 0.7

        let stack = UIStackView(arrangedSubviews: [percentLabel, detailLabel])
        stack.axis = .vertical
        stack.spacing = 2
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.diameter),
            heightAnchor.constraint(equalToConstant: Self.diameter),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(equalTo: widthAnchor, constant: -44),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = Self.lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = UIBezierPath(
            arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
            radius: rect.width / 2,
            startAngle: -.pi / 2,
            endAngle: 1.5 * .pi,
            clockwise: true
        ).cgPath
        track.frame = bounds
        progress.frame = bounds
        track.path = path
        progress.path = path
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        applyStrokeColors()
    }

    private func applyStrokeColors() {
        track.strokeColor = UIColor.tertiarySystemFill.resolvedColor(with: traitCollection).cgColor
        progress.strokeColor = UIColor.tintColor.resolvedColor(with: traitCollection).cgColor
    }

    func setProgress(_ fraction: Double, determinate: Bool, detail: String) {
        detailLabel.text = detail
        detailLabel.isHidden = detail.isEmpty
        percentLabel.text = "\(Int((fraction * 100).rounded()))%"

        if determinate {
            stopSweeping()
            let clamped = CGFloat(min(1, max(0, fraction)))
            progress.strokeStart = 0
            if UIAccessibility.isReduceMotionEnabled {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                progress.strokeEnd = clamped
                CATransaction.commit()
            } else {
                progress.strokeEnd = clamped
            }
        } else {
            startSweeping()
        }
    }

    /// The uncountable phases still need to look alive; a short arc chasing the
    /// ring reads as work in flight without pretending to know how much is left.
    private func startSweeping() {
        guard !isSweeping else { return }
        isSweeping = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progress.strokeStart = 0
        progress.strokeEnd = 0.22
        CATransaction.commit()
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 1.4
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        progress.add(spin, forKey: "sweep")
    }

    private func stopSweeping() {
        guard isSweeping else { return }
        isSweeping = false
        progress.removeAnimation(forKey: "sweep")
    }
}

/// Three live tallies — files seen, tracks indexed, albums built — so the wait
/// shows the library growing instead of an opaque spinner.
private final class StatsRowView: UIView {

    private let files = StatView(title: String(localized: "Files"))
    private let tracks = StatView(title: String(localized: "Tracks"))
    private let albums = StatView(title: String(localized: "Albums"))

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [files, divider(), tracks, divider(), albums])
        stack.axis = .horizontal
        stack.distribution = .fill
        stack.alignment = .center
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            tracks.widthAnchor.constraint(equalTo: files.widthAnchor),
            albums.widthAnchor.constraint(equalTo: files.widthAnchor),
        ])
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func divider() -> UIView {
        let line = UIView()
        line.backgroundColor = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 28),
        ])
        return line
    }

    func update(progress: LibraryLoadProgress) {
        files.setValue(progress.filesFound)
        tracks.setValue(progress.tracksIndexed)
        albums.setValue(progress.albumsBuilt)
    }
}

private final class StatView: UIView {

    private let valueLabel = UILabel()
    private let titleLabel = UILabel()
    private var lastValue = 0

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = .scaled(.title3, size: 19, weight: .semibold).monospacedDigits
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.textAlignment = .center
        valueLabel.textColor = .tertiaryLabel
        valueLabel.text = "—"

        titleLabel.text = title
        titleLabel.font = .scaled(.caption2, size: 11, weight: .medium)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .secondaryLabel
        titleLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [valueLabel, titleLabel])
        stack.axis = .vertical
        stack.spacing = 2
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setValue(_ value: Int) {
        guard value != lastValue else { return }
        let wasEmpty = lastValue == 0
        lastValue = value
        valueLabel.text = value > 0 ? LibraryLoadPhaseCopy.number(value) : "—"
        valueLabel.textColor = value > 0 ? .label : .tertiaryLabel
        guard value > 0, wasEmpty, !UIAccessibility.isReduceMotionEnabled else { return }
        valueLabel.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0.4) {
            self.valueLabel.transform = .identity
        }
    }
}

private extension UIFont {
    var monospacedDigits: UIFont {
        let settings: [UIFontDescriptor.FeatureKey: Int] = [
            .type: kNumberSpacingType,
            .selector: kMonospacedNumbersSelector,
        ]
        let descriptor = fontDescriptor.addingAttributes([.featureSettings: [settings]])
        return UIFont(descriptor: descriptor, size: 0)
    }
}
