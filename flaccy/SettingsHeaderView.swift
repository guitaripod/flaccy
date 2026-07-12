import UIKit

/// The Settings banner: an ambient-gradient hero that states who you are in
/// flaccy at a glance — a branded mark, a live library dashboard, and a
/// status-aware entitlement call to action.
final class SettingsHeaderView: UIView {

    var onUnlockTapped: (() -> Void)?

    private let backdrop = AmbientPaletteBackdropView()
    private let contentStack = UIStackView()

    private let albumsColumn = StatColumn()
    private let tracksColumn = StatColumn()
    private let playsColumn = StatColumn()

    private let statusControl = StatusPillControl()

    private static let groupedNumber: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        autoresizingMask = [.flexibleWidth]
        layer.cornerRadius = 30
        layer.cornerCurve = .continuous
        layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        clipsToBounds = true
        buildBackdrop()
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildBackdrop() {
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        backdrop.apply(ArtworkPaletteExtractor.fallbackPalette(seed: "flaccy"), animated: false)
    }

    private func buildContent() {
        contentStack.axis = .vertical
        contentStack.spacing = 22
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 26, leading: 22, bottom: 24, trailing: 22)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        contentStack.addArrangedSubview(makeIdentityRow())
        contentStack.addArrangedSubview(makeStatsStrip())

        statusControl.addTarget(self, action: #selector(statusTapped), for: .touchUpInside)
        contentStack.addArrangedSubview(statusControl)
    }

    private func makeIdentityRow() -> UIView {
        let glyph = UIImageView(image: Self.brandGlyph())
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: 52),
            glyph.heightAnchor.constraint(equalToConstant: 52),
        ])

        let wordmark = UILabel()
        wordmark.text = "flaccy"
        wordmark.font = .scaled(.title1, size: 27, weight: .heavy, maxSize: 34)
        wordmark.textColor = .white
        wordmark.adjustsFontForContentSizeCategory = true

        let tagline = UILabel()
        tagline.text = "Your lossless library"
        tagline.font = .scaled(.subheadline, size: 14, weight: .medium, maxSize: 20)
        tagline.textColor = UIColor.white.withAlphaComponent(0.62)
        tagline.adjustsFontForContentSizeCategory = true

        let labels = UIStackView(arrangedSubviews: [wordmark, tagline])
        labels.axis = .vertical
        labels.spacing = 1

        let row = UIStackView(arrangedSubviews: [glyph, labels])
        row.axis = .horizontal
        row.spacing = 14
        row.alignment = .center

        row.isAccessibilityElement = true
        row.accessibilityLabel = "flaccy, your lossless library"
        row.accessibilityTraits = .header
        return row
    }

    private func makeStatsStrip() -> UIView {
        albumsColumn.configure(caption: "Albums")
        tracksColumn.configure(caption: "Tracks")
        playsColumn.configure(caption: "Plays")

        let strip = UIStackView(arrangedSubviews: [
            albumsColumn, makeDivider(), tracksColumn, makeDivider(), playsColumn,
        ])
        strip.axis = .horizontal
        strip.alignment = .center
        strip.distribution = .fill
        NSLayoutConstraint.activate([
            tracksColumn.widthAnchor.constraint(equalTo: albumsColumn.widthAnchor),
            playsColumn.widthAnchor.constraint(equalTo: albumsColumn.widthAnchor),
        ])
        return strip
    }

    private func makeDivider() -> UIView {
        let container = UIView()
        container.setContentHuggingPriority(.required, for: .horizontal)
        let line = UIView()
        line.backgroundColor = UIColor.white.withAlphaComponent(0.14)
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 1),
            line.widthAnchor.constraint(equalToConstant: 1),
            line.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            line.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            line.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        ])
        return container
    }

    func configure(state: EntitlementState, priceText: String?, albums: Int, tracks: Int, plays: Int?) {
        albumsColumn.setValue(Self.groupedNumber.string(from: NSNumber(value: albums)) ?? "\(albums)")
        tracksColumn.setValue(Self.groupedNumber.string(from: NSNumber(value: tracks)) ?? "\(tracks)")
        if let plays {
            playsColumn.setValue(Self.groupedNumber.string(from: NSNumber(value: plays)) ?? "\(plays)")
        } else {
            playsColumn.setValue("—")
        }
        configureStatus(state: state, priceText: priceText)
    }

    private func configureStatus(state: EntitlementState, priceText: String?) {
        switch state {
        case .purchased:
            statusControl.configure(
                symbolName: "crown.fill",
                title: "Lifetime member",
                subtitle: "Thanks for supporting flaccy",
                tint: .systemYellow,
                interactive: false
            )
        case .trial(let daysRemaining):
            let days = "\(daysRemaining) day\(daysRemaining == 1 ? "" : "s") left"
            let subtitle = priceText.map { "\(days) · \($0) once, forever" } ?? "\(days) in your free trial"
            statusControl.configure(
                symbolName: "sparkles",
                title: "Unlock Lifetime",
                subtitle: subtitle,
                tint: daysRemaining <= 2 ? .systemOrange : QualityBadgeView.losslessTint,
                interactive: true
            )
        case .expired:
            let subtitle = priceText.map { "Your trial ended · \($0) once, forever" } ?? "Your free trial has ended"
            statusControl.configure(
                symbolName: "lock.fill",
                title: "Unlock Lifetime",
                subtitle: subtitle,
                tint: .systemRed,
                interactive: true
            )
        }
    }

    @objc private func statusTapped() {
        onUnlockTapped?()
    }

    /// A rounded-square brand mark: a diagonal cyan→indigo field behind a white
    /// waveform, drawn once at the display scale.
    private static func brandGlyph() -> UIImage {
        let side: CGFloat = 52
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { context in
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 14)
            path.addClip()
            let colors = [
                QualityBadgeView.losslessTint.cgColor,
                UIColor.systemIndigo.cgColor,
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]
            ) {
                context.cgContext.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: side, y: side),
                    options: []
                )
            }
            let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .bold)
            guard let glyph = UIImage(systemName: "waveform", withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) else { return }
            glyph.draw(in: CGRect(
                x: (side - glyph.size.width) / 2,
                y: (side - glyph.size.height) / 2,
                width: glyph.size.width,
                height: glyph.size.height
            ))
        }
    }
}

/// One column of the hero dashboard: a bold count over a letterspaced caption.
private final class StatColumn: UIView {

    private let valueLabel = UILabel()
    private let captionLabel = UILabel()
    private var caption = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        valueLabel.font = .scaled(.title2, size: 22, weight: .bold, maxSize: 30)
        valueLabel.textColor = .white
        valueLabel.textAlignment = .center
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.7

        captionLabel.textAlignment = .center
        captionLabel.adjustsFontForContentSizeCategory = true

        let stack = UIStackView(arrangedSubviews: [valueLabel, captionLabel])
        stack.axis = .vertical
        stack.spacing = 3
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(caption: String) {
        self.caption = caption
        captionLabel.attributedText = NSAttributedString(
            string: caption.uppercased(),
            attributes: [
                .font: UIFont.scaled(.caption2, size: 11, weight: .semibold, maxSize: 15),
                .foregroundColor: UIColor.white.withAlphaComponent(0.55),
                .kern: 1.3,
            ]
        )
    }

    func setValue(_ value: String) {
        valueLabel.text = value
        accessibilityLabel = "\(value) \(caption)"
    }
}

/// The entitlement banner control: a tinted capsule with an icon, a title, an
/// optional subtitle, and a chevron when it leads somewhere. Presses dim and
/// gently scale, matching the app's tactile feel.
private final class StatusPillControl: UIControl {

    private let background = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let chevron = UIImageView(
        image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
    )

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        background.layer.cornerRadius = 16
        background.layer.cornerCurve = .continuous
        background.layer.borderWidth = 1
        background.isUserInteractionEnabled = false
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        iconView.contentMode = .center
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .scaled(.subheadline, size: 16, weight: .semibold, maxSize: 22)
        titleLabel.textColor = .white
        titleLabel.adjustsFontForContentSizeCategory = true

        subtitleLabel.font = .scaled(.footnote, size: 12.5, weight: .medium, maxSize: 18)
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.numberOfLines = 2

        let labels = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        labels.axis = .vertical
        labels.spacing = 1

        chevron.tintColor = UIColor.white.withAlphaComponent(0.5)
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [iconView, labels, chevron])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            iconView.widthAnchor.constraint(equalToConstant: 26),
        ])

        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(symbolName: String, title: String, subtitle: String?, tint: UIColor, interactive: Bool) {
        iconView.image = UIImage(
            systemName: symbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        )
        iconView.tintColor = tint
        titleLabel.text = title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = (subtitle ?? "").isEmpty
        chevron.isHidden = !interactive
        isUserInteractionEnabled = interactive
        accessibilityIdentifier = interactive ? "unlockLifetime" : "lifetimeMember"
        accessibilityTraits = interactive ? .button : .staticText

        let fillAlpha = UIAccessibility.isReduceTransparencyEnabled ? 0.34 : 0.24
        background.backgroundColor = tint.withAlphaComponent(interactive ? fillAlpha : 0.12)
        background.layer.borderColor = tint.withAlphaComponent(interactive ? 0.55 : 0.25).cgColor

        let spokenSubtitle = subtitle.map { ", \($0)" } ?? ""
        accessibilityLabel = title + spokenSubtitle
        accessibilityHint = interactive ? "Shows the one-time purchase that unlocks flaccy forever" : nil
    }

    override var isHighlighted: Bool {
        didSet {
            guard isUserInteractionEnabled else { return }
            UIView.animate(withDuration: 0.16, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.background.alpha = self.isHighlighted ? 0.7 : 1
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.98, y: 0.98) : .identity
            }
        }
    }
}
