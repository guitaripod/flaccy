import FlaccyCore
import UIKit

extension UIFont {

    /// A Dynamic Type font at an explicit weight, which `preferredFont` cannot
    /// give directly.
    static func watchSyncFont(_ style: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont {
        let reference = UITraitCollection(preferredContentSizeCategory: .large)
        let size = UIFont.preferredFont(forTextStyle: style, compatibleWith: reference).pointSize
        return UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight))
    }
}

private final class ProgressRingView: UIView {

    private let trackLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()
    private var fraction: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for layer in [trackLayer, progressLayer] {
            layer.fillColor = UIColor.clear.cgColor
            layer.lineCap = .round
            layer.lineWidth = 3
            self.layer.addSublayer(layer)
        }
        progressLayer.strokeEnd = 0
        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: ProgressRingView, _) in
            self.applyColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func applyColors() {
        trackLayer.strokeColor = UIColor.tertiarySystemFill.resolvedColor(with: traitCollection).cgColor
        progressLayer.strokeColor = tintColor.cgColor
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyColors()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = progressLayer.lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = UIBezierPath(
            arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
            radius: min(rect.width, rect.height) / 2,
            startAngle: -.pi / 2,
            endAngle: .pi * 1.5,
            clockwise: true
        )
        trackLayer.path = path.cgPath
        progressLayer.path = path.cgPath
        trackLayer.frame = bounds
        progressLayer.frame = bounds
    }

    /// Advances the ring smoothly; regressions and Reduce Motion set the value
    /// directly so the stroke never visibly rewinds or interpolates.
    func setProgress(_ value: Double, animated: Bool) {
        let clamped = CGFloat(min(1, max(0, value)))
        let shouldAnimate = animated
            && !UIAccessibility.isReduceMotionEnabled
            && clamped > fraction
            && window != nil
        fraction = clamped
        if shouldAnimate {
            let from = (progressLayer.presentation() ?? progressLayer).strokeEnd
            progressLayer.strokeEnd = clamped
            let animation = CABasicAnimation(keyPath: "strokeEnd")
            animation.fromValue = from
            animation.toValue = clamped
            animation.duration = 0.3
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            progressLayer.add(animation, forKey: "strokeEnd")
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            progressLayer.removeAnimation(forKey: "strokeEnd")
            progressLayer.strokeEnd = clamped
            CATransaction.commit()
        }
    }
}

final class WatchSyncStatusCell: UITableViewCell {

    struct Content {
        let state: WatchConnectionState
        let subtitle: String
        let storage: WatchStorageBreakdown?
        let stuckCount: Int
        let isChecking: Bool
    }

    static let reuseID = "WatchSyncStatusCell"

    var onRetry: (() -> Void)?
    var onShowHow: (() -> Void)?
    var onCheckAgain: (() -> Void)?

    private let badge = UIView()
    private let badgeIcon = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let headerRow = UIStackView()
    private let meter = WatchSyncStorageMeterView()
    private let badgeSpinner = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)
    private let showHowButton = UIButton(type: .system)
    private let checkAgainButton = UIButton(type: .system)
    private let buttonStack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        configureBadge()
        configureLabels()
        configureRetryButton()
        configureSetupButtons()

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 3

        headerRow.addArrangedSubview(badge)
        headerRow.addArrangedSubview(textStack)
        headerRow.axis = .horizontal
        headerRow.spacing = 14
        headerRow.alignment = .top
        headerRow.isAccessibilityElement = true

        buttonStack.addArrangedSubview(showHowButton)
        buttonStack.addArrangedSubview(checkAgainButton)
        buttonStack.addArrangedSubview(retryButton)
        buttonStack.spacing = 10
        buttonStack.distribution = .fillEqually
        applyButtonAxis()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: WatchSyncStatusCell, _) in
            self.applyButtonAxis()
        }

        let stack = UIStackView(arrangedSubviews: [headerRow, meter, buttonStack])
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(12, after: meter)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configureBadge() {
        badge.layer.cornerRadius = 14
        badge.layer.cornerCurve = .continuous
        badge.translatesAutoresizingMaskIntoConstraints = false
        badgeIcon.contentMode = .center
        badgeIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        badgeIcon.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(badgeIcon)
        badgeSpinner.hidesWhenStopped = true
        badgeSpinner.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(badgeSpinner)
        NSLayoutConstraint.activate([
            badgeSpinner.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            badgeSpinner.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 48),
            badge.heightAnchor.constraint(equalToConstant: 48),
            badgeIcon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            badgeIcon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func configureLabels() {
        titleLabel.font = .watchSyncFont(.headline, weight: .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 0
    }

    private func configureRetryButton() {
        var configuration = UIButton.Configuration.tinted()
        configuration.cornerStyle = .capsule
        configuration.image = UIImage(systemName: "arrow.clockwise")
        configuration.imagePadding = 6
        configuration.baseForegroundColor = .systemOrange
        configuration.baseBackgroundColor = .systemOrange
        retryButton.configuration = configuration
        retryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)
    }

    /// A "Show Me How" and a "Check Again" button, side by side while they fit
    /// and stacked once Dynamic Type makes the titles too wide for that.
    private func configureSetupButtons() {
        var help = UIButton.Configuration.filled()
        help.cornerStyle = .capsule
        help.image = UIImage(systemName: "list.number")
        help.imagePadding = 6
        help.title = String(localized: "Show Me How")
        help.baseBackgroundColor = .systemOrange
        help.baseForegroundColor = .white
        showHowButton.configuration = help
        showHowButton.addAction(UIAction { [weak self] _ in self?.onShowHow?() }, for: .touchUpInside)
        showHowButton.accessibilityHint = String(localized: "Shows the steps to put Flaccy on your Apple Watch")

        var recheck = UIButton.Configuration.tinted()
        recheck.cornerStyle = .capsule
        recheck.image = UIImage(systemName: "arrow.clockwise")
        recheck.imagePadding = 6
        recheck.baseForegroundColor = .systemOrange
        recheck.baseBackgroundColor = .systemOrange
        checkAgainButton.configuration = recheck
        checkAgainButton.addAction(UIAction { [weak self] _ in self?.onCheckAgain?() }, for: .touchUpInside)
        checkAgainButton.accessibilityHint = String(localized: "Looks for your Apple Watch again")

        for button in [showHowButton, checkAgainButton] {
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.textAlignment = .center
        }
    }

    private func applyButtonAxis() {
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        buttonStack.axis = large ? .vertical : .horizontal
    }

    private func applyCheckState(_ isChecking: Bool) {
        var configuration = checkAgainButton.configuration
        configuration?.showsActivityIndicator = isChecking
        configuration?.image = isChecking ? nil : UIImage(systemName: "arrow.clockwise")
        configuration?.title = isChecking ? String(localized: "Checking…") : String(localized: "Check Again")
        checkAgainButton.configuration = configuration
        checkAgainButton.isEnabled = !isChecking
    }

    func configure(_ content: Content) {
        let color = content.state.color
        badge.backgroundColor = color.withAlphaComponent(UIAccessibility.isReduceTransparencyEnabled ? 0.28 : 0.16)
        badgeIcon.image = UIImage(systemName: content.state.symbol)
        badgeIcon.tintColor = color
        badgeIcon.isHidden = content.state.isWaiting
        badgeSpinner.color = color
        if content.state.isWaiting { badgeSpinner.startAnimating() } else { badgeSpinner.stopAnimating() }
        titleLabel.text = content.state.title
        subtitleLabel.text = content.subtitle
        headerRow.accessibilityLabel = content.state.title
        headerRow.accessibilityValue = content.subtitle

        if let storage = content.storage {
            meter.apply(storage)
            meter.isHidden = false
        } else {
            meter.isHidden = true
        }

        retryButton.isHidden = content.stuckCount == 0
        retryButton.configuration?.title = String(localized: "Retry")
        retryButton.accessibilityHint = String(localized: "Sends the songs that stopped again")
        showHowButton.isHidden = !content.state.offersSetupHelp
        checkAgainButton.isHidden = !content.state.offersRecheck
        applyCheckState(content.isChecking)
        buttonStack.isHidden = retryButton.isHidden && showHowButton.isHidden && checkAgainButton.isHidden
        accessibilityElements = [headerRow, meter, showHowButton, checkAgainButton, retryButton].filter { !$0.isHidden }
    }
}

final class WatchSyncRunCell: UITableViewCell {

    static let reuseID = "WatchSyncRunCell"

    private let ring = ProgressRingView()
    private let percentLabel = UILabel()
    private let header = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let detail = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        header.font = .watchSyncFont(.subheadline, weight: .semibold)
        header.adjustsFontForContentSizeCategory = true
        header.numberOfLines = 0

        progress.progressTintColor = .tintColor
        progress.trackTintColor = .tertiarySystemFill

        detail.font = UIFont.monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0

        percentLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        percentLabel.textColor = .secondaryLabel
        percentLabel.textAlignment = .center
        percentLabel.adjustsFontSizeToFitWidth = true
        percentLabel.minimumScaleFactor = 0.6
        percentLabel.translatesAutoresizingMaskIntoConstraints = false

        ring.translatesAutoresizingMaskIntoConstraints = false
        ring.addSubview(percentLabel)

        let textStack = UIStackView(arrangedSubviews: [header, progress, detail])
        textStack.axis = .vertical
        textStack.spacing = 7

        let stack = UIStackView(arrangedSubviews: [ring, textStack])
        stack.axis = .horizontal
        stack.spacing = 14
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            ring.widthAnchor.constraint(equalToConstant: 48),
            ring.heightAnchor.constraint(equalToConstant: 48),
            percentLabel.centerXAnchor.constraint(equalTo: ring.centerXAnchor),
            percentLabel.centerYAnchor.constraint(equalTo: ring.centerYAnchor),
            percentLabel.widthAnchor.constraint(lessThanOrEqualTo: ring.widthAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        ring.setProgress(0, animated: false)
        progress.setProgress(0, animated: false)
    }

    func configure(service: WatchSyncService) {
        let fraction = service.sessionFraction
        header.text = headerText(service: service)
        ring.setProgress(fraction, animated: true)
        percentLabel.text = SyncFormat.percent(fraction)
        if UIAccessibility.isReduceMotionEnabled {
            progress.setProgress(Float(fraction), animated: false)
        } else {
            progress.setProgress(Float(fraction), animated: Float(fraction) > progress.progress)
        }
        let transferred = SyncFormat.size(service.sessionTransferredBytes)
        let total = SyncFormat.size(service.sessionTotalBytesPending)
        let speed = SyncFormat.speed(service.speedBytesPerSec)
        let eta = SyncFormat.eta(service.etaSeconds)
        detail.text = String(localized: "\(transferred) of \(total)  ·  \(speed)  ·  \(eta)")
        isAccessibilityElement = true
        accessibilityLabel = header.text
        accessibilityValue = String(localized: "\(SyncFormat.percent(fraction)), \(transferred) of \(total), \(speed), \(eta)")
    }

    /// Names the stage the run is in: songs still being encoded for the watch
    /// first, then the songs on their way.
    private func headerText(service: WatchSyncService) -> String {
        let preparing = service.preparingCount
        if preparing > 0 {
            let total = max(preparing, service.runStems.count)
            if total == 1 { return String(localized: "Preparing 1 song") }
            return String(localized: "Preparing \(preparing) of \(total) songs")
        }
        let sending = service.activeTransferCount
        if sending == 1 { return String(localized: "Sending 1 song…") }
        return String(localized: "Sending \(sending) songs…")
    }
}

final class WatchSyncQualityCell: UITableViewCell {

    static let reuseID = "WatchSyncQualityCell"

    private let titleLabel = UILabel()
    private let formatLabel = UILabel()
    private let captionLabel = UILabel()
    private let hintLabel = UILabel()
    private let checkView = UIImageView()
    private let titleRow = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        titleLabel.font = .watchSyncFont(.body, weight: .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0

        formatLabel.font = .watchSyncFont(.footnote, weight: .medium)
        formatLabel.adjustsFontForContentSizeCategory = true
        formatLabel.textColor = .secondaryLabel
        formatLabel.numberOfLines = 0
        formatLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        captionLabel.font = .preferredFont(forTextStyle: .subheadline)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.textColor = .secondaryLabel
        captionLabel.numberOfLines = 0

        hintLabel.font = UIFont.monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
        hintLabel.adjustsFontForContentSizeCategory = true
        hintLabel.textColor = .tertiaryLabel
        hintLabel.numberOfLines = 0

        titleRow.addArrangedSubview(titleLabel)
        titleRow.addArrangedSubview(formatLabel)
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 8
        applyTitleRowAxis()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: WatchSyncQualityCell, _) in
            self.applyTitleRowAxis()
        }

        let textStack = UIStackView(arrangedSubviews: [titleRow, captionLabel, hintLabel])
        textStack.axis = .vertical
        textStack.spacing = 3
        textStack.setCustomSpacing(6, after: captionLabel)

        checkView.contentMode = .center
        checkView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        checkView.setContentHuggingPriority(.required, for: .horizontal)
        checkView.setContentCompressionResistancePriority(.required, for: .horizontal)
        checkView.translatesAutoresizingMaskIntoConstraints = false
        checkView.widthAnchor.constraint(equalToConstant: 26).isActive = true

        let stack = UIStackView(arrangedSubviews: [textStack, checkView])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .top
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func applyTitleRowAxis() {
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        titleRow.axis = large ? .vertical : .horizontal
        titleRow.alignment = large ? .leading : .firstBaseline
    }

    func configure(profile: WatchAudioProfile, isSelected: Bool, hint: String?) {
        titleLabel.text = profile.displayName
        formatLabel.text = profile.formatName
        captionLabel.text = profile.caption
        hintLabel.text = hint
        hintLabel.isHidden = hint == nil
        checkView.image = isSelected ? UIImage(systemName: "checkmark.circle.fill") : UIImage(systemName: "circle")
        checkView.tintColor = isSelected ? .tintColor : .tertiaryLabel
        isAccessibilityElement = true
        accessibilityLabel = "\(profile.displayName), \(profile.formatName)"
        accessibilityValue = [isSelected ? String(localized: "Selected") : nil, profile.caption, hint]
            .compactMap { $0 }
            .joined(separator: ". ")
        accessibilityTraits = isSelected ? [.button, .selected] : .button
    }
}

final class WatchSyncAlbumCell: UITableViewCell {

    static let reuseID = "WatchSyncAlbumCell"

    private let artworkView = UIImageView()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let statusLabel = UILabel()
    private let ring = ProgressRingView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusIcon = UIImageView()
    private let pillButton = UIButton(type: .system)
    private var rowStack: UIStackView?
    private var pillWidthConstraints: [NSLayoutConstraint] = []
    private var currentArtworkKey: String?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentArtworkKey = nil
        artworkView.image = nil
        ring.setProgress(0, animated: false)
        showAccessory(.icon(name: "circle", tint: .clear))
        rowStack?.alpha = 1
    }

    private func setup() {
        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.layer.cornerRadius = 8
        artworkView.layer.cornerCurve = .continuous
        artworkView.backgroundColor = .tertiarySystemFill
        artworkView.tintColor = .tertiaryLabel
        artworkView.isAccessibilityElement = false

        titleLabel.font = .watchSyncFont(.body, weight: .medium)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 2

        artistLabel.font = .preferredFont(forTextStyle: .subheadline)
        artistLabel.adjustsFontForContentSizeCategory = true
        artistLabel.textColor = .secondaryLabel
        artistLabel.numberOfLines = 1

        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0

        let accessory = UIView()
        accessory.translatesAutoresizingMaskIntoConstraints = false
        configurePill()
        for view in [statusIcon, ring, spinner, pillButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            accessory.addSubview(view)
        }
        statusIcon.contentMode = .center
        statusIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        ring.isHidden = true
        spinner.hidesWhenStopped = true

        let textStack = UIStackView(arrangedSubviews: [titleLabel, artistLabel, statusLabel])
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.setCustomSpacing(4, after: artistLabel)

        pillWidthConstraints = [
            pillButton.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            pillButton.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
        ]
        accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
        accessory.setContentHuggingPriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [artworkView, textStack, accessory])
        rowStack = stack
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        let restingWidth = accessory.widthAnchor.constraint(equalToConstant: 28)
        restingWidth.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            artworkView.widthAnchor.constraint(equalToConstant: 56),
            artworkView.heightAnchor.constraint(equalToConstant: 56),
            accessory.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
            restingWidth,
            accessory.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            pillButton.centerYAnchor.constraint(equalTo: accessory.centerYAnchor),
            statusIcon.centerXAnchor.constraint(equalTo: accessory.centerXAnchor),
            statusIcon.centerYAnchor.constraint(equalTo: accessory.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: accessory.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: accessory.centerYAnchor),
            ring.widthAnchor.constraint(equalToConstant: 26),
            ring.heightAnchor.constraint(equalToConstant: 26),
            ring.centerXAnchor.constraint(equalTo: accessory.centerXAnchor),
            ring.centerYAnchor.constraint(equalTo: accessory.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
    }

    /// A tinted capsule that reads as an action but is not itself a control:
    /// the whole row is the tap target.
    private func configurePill() {
        var configuration = UIButton.Configuration.tinted()
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .watchSyncFont(.footnote, weight: .semibold)
            return attributes
        }
        pillButton.configuration = configuration
        pillButton.isUserInteractionEnabled = false
        pillButton.isAccessibilityElement = false
        pillButton.isHidden = true
        pillButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    func configure(album: Album, presentation: WatchAlbumPresentation) {
        titleLabel.text = album.title
        artistLabel.text = album.artist
        statusLabel.text = presentation.statusText
        statusLabel.textColor = presentation.statusColor
        rowStack?.alpha = presentation.isDimmed ? 0.55 : 1
        loadArtwork(for: album)
        showAccessory(presentation.accessory)

        isAccessibilityElement = true
        accessibilityLabel = "\(album.title), \(album.artist), \(presentation.statusText)"
        accessibilityValue = presentation.voiceOverValue
        accessibilityHint = presentation.voiceOverHint
        accessibilityTraits = .button
    }

    private func showAccessory(_ accessory: WatchAlbumPresentation.Accessory) {
        if case .pill = accessory {
            NSLayoutConstraint.activate(pillWidthConstraints)
        } else {
            NSLayoutConstraint.deactivate(pillWidthConstraints)
        }
        switch accessory {
        case let .ring(fraction):
            statusIcon.image = nil
            pillButton.isHidden = true
            spinner.stopAnimating()
            ring.isHidden = false
            ring.setProgress(fraction, animated: true)
        case .spinner:
            statusIcon.image = nil
            pillButton.isHidden = true
            ring.isHidden = true
            ring.setProgress(0, animated: false)
            spinner.startAnimating()
        case let .icon(name, tint):
            pillButton.isHidden = true
            ring.isHidden = true
            ring.setProgress(0, animated: false)
            spinner.stopAnimating()
            statusIcon.image = UIImage(systemName: name)
            statusIcon.tintColor = tint
        case let .pill(title):
            statusIcon.image = nil
            ring.isHidden = true
            ring.setProgress(0, animated: false)
            spinner.stopAnimating()
            pillButton.configuration?.title = title
            pillButton.isHidden = false
        }
    }

    private func loadArtwork(for album: Album) {
        let artworkKey = album.id
        guard currentArtworkKey != artworkKey else { return }
        currentArtworkKey = artworkKey
        if let art = album.artwork ?? AlbumArtworkCache.shared.thumbnail(forAlbum: album.title, artist: album.artist) {
            setArtwork(art)
        } else {
            setPlaceholder()
            AlbumArtworkCache.shared.loadThumbnail(forAlbum: album.title, artist: album.artist) { [weak self] image in
                guard let self, let image, self.currentArtworkKey == artworkKey else { return }
                self.setArtwork(image)
            }
        }
    }

    private func setArtwork(_ image: UIImage) {
        artworkView.contentMode = .scaleAspectFill
        artworkView.image = image
    }

    private func setPlaceholder() {
        artworkView.contentMode = .center
        artworkView.image = UIImage(systemName: "music.note")
    }
}
