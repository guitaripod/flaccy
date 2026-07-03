import UIKit

final class StreamingLinksViewController: UIViewController {

    private let result: SonglinkResult
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private var appearanceRows: [UIView] = []
    private var hasAnimatedAppearance = false

    init(result: SonglinkResult) {
        self.result = result
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        title = "Share"

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                self?.dismiss(animated: true)
            }
        )

        setupLayout()
        buildContent()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        prepareAppearanceAnimationIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        runAppearanceAnimationIfNeeded()
    }

    private func setupLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = 10
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -32),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40),
        ])
    }

    private func buildContent() {
        contentStack.addArrangedSubview(trackHeader())
        contentStack.setCustomSpacing(28, after: contentStack.arrangedSubviews.last!)

        addSectionCaption("Universal Link")

        let shareRow = GlassRow(
            icon: UIImage(systemName: "square.and.arrow.up"),
            iconTint: view.tintColor ?? .systemBlue,
            title: "Share",
            subtitle: result.pageURL.absoluteString,
            accessibilityLabel: "Share universal link"
        )
        shareRow.onTap = { [weak self] in
            guard let self else { return }
            shareURL(result.pageURL, label: "Universal")
        }
        shareRow.menuProvider = { [weak self] in
            guard let self else { return nil }
            return linkMenu(for: result.pageURL, label: "Universal")
        }
        addRow(shareRow)

        let copyRow = GlassRow(
            icon: UIImage(systemName: "doc.on.doc"),
            iconTint: view.tintColor ?? .systemBlue,
            title: "Copy Link",
            accessibilityLabel: "Copy universal link"
        )
        copyRow.onTap = { [weak self] in
            guard let self else { return }
            copyURL(result.pageURL, label: "Universal")
        }
        copyRow.menuProvider = { [weak self] in
            guard let self else { return nil }
            return linkMenu(for: result.pageURL, label: "Universal")
        }
        addRow(copyRow)

        addSectionFooter("Recipients choose their preferred platform")

        guard !result.platformLinks.isEmpty else { return }
        contentStack.setCustomSpacing(24, after: contentStack.arrangedSubviews.last!)
        addSectionCaption("Available On")

        for link in result.platformLinks {
            let row = GlassRow(
                icon: UIImage(systemName: link.iconName),
                iconTint: brandColor(fromHex: link.tintColorHex),
                title: link.displayName,
                accessory: UIImage(systemName: "arrow.up.forward"),
                accessibilityLabel: "Open in \(link.displayName)"
            )
            row.onTap = { [weak self] in self?.openPlatform(link) }
            row.menuProvider = { [weak self] in self?.linkMenu(for: link.url, label: link.displayName) }
            addRow(row)
        }
    }

    private func trackHeader() -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = result.title
        titleLabel.font = .preferredFont(forTextStyle: .title2).withWeight(.bold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2

        let artistLabel = UILabel()
        artistLabel.text = result.artist
        artistLabel.font = .preferredFont(forTextStyle: .subheadline)
        artistLabel.adjustsFontForContentSizeCategory = true
        artistLabel.textColor = .secondaryLabel
        artistLabel.textAlignment = .center
        artistLabel.numberOfLines = 2

        let stack = UIStackView(arrangedSubviews: [titleLabel, artistLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.isAccessibilityElement = true
        stack.accessibilityLabel = "\(result.title) by \(result.artist)"
        stack.accessibilityTraits = .header
        appearanceRows.append(stack)
        return stack
    }

    private func addSectionCaption(_ text: String) {
        let label = UILabel()
        label.text = text.uppercased()
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.accessibilityTraits = .header

        let container = UIStackView(arrangedSubviews: [label])
        container.layoutMargins = UIEdgeInsets(top: 0, left: 16, bottom: 2, right: 16)
        container.isLayoutMarginsRelativeArrangement = true
        contentStack.addArrangedSubview(container)
        appearanceRows.append(container)
    }

    private func addSectionFooter(_ text: String) {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 0

        let container = UIStackView(arrangedSubviews: [label])
        container.layoutMargins = UIEdgeInsets(top: 2, left: 16, bottom: 0, right: 16)
        container.isLayoutMarginsRelativeArrangement = true
        contentStack.addArrangedSubview(container)
        appearanceRows.append(container)
    }

    private func addRow(_ row: GlassRow) {
        contentStack.addArrangedSubview(row)
        appearanceRows.append(row)
    }

    private func openPlatform(_ link: PlatformLink) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        AppLogger.info("Opening \(link.displayName) link", category: .ui)
        UIApplication.shared.open(link.url)
    }

    private func shareURL(_ url: URL, label: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        AppLogger.info("Sharing \(label) link", category: .ui)
        let text = "\(result.title) by \(result.artist)"
        let activity = UIActivityViewController(activityItems: [text, url], applicationActivities: nil)
        activity.completionWithItemsHandler = { [weak self] _, completed, _, _ in
            if completed {
                self?.dismiss(animated: true)
            }
        }
        present(activity, animated: true)
    }

    private func copyURL(_ url: URL, label: String) {
        UIPasteboard.general.url = url
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        AppLogger.info("Copied \(label) link", category: .ui)
        ToastView.show("\(label) link copied", in: view, style: .success)
    }

    private func linkMenu(for url: URL, label: String) -> UIMenu {
        let share = UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
            self?.shareURL(url, label: label)
        }
        let copy = UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            self?.copyURL(url, label: label)
        }
        let open = UIAction(title: "Open", image: UIImage(systemName: "safari")) { _ in
            AppLogger.info("Opening \(label) link from menu", category: .ui)
            UIApplication.shared.open(url)
        }
        return UIMenu(children: [share, copy, open])
    }

    /// Resolves a brand hex to a dynamic color, lifting near-black brands
    /// (Tidal, Spinrilla) to `.label` so glyphs stay visible on glass in dark mode.
    private func brandColor(fromHex hex: UInt) -> UIColor {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        if max(red, green, blue) < 0.2 {
            return .label
        }
        return UIColor(red: red, green: green, blue: blue, alpha: 1)
    }

    private func prepareAppearanceAnimationIfNeeded() {
        guard !hasAnimatedAppearance, !UIAccessibility.isReduceMotionEnabled else { return }
        for row in appearanceRows {
            row.alpha = 0
            row.transform = CGAffineTransform(translationX: 0, y: 14)
        }
    }

    private func runAppearanceAnimationIfNeeded() {
        guard !hasAnimatedAppearance else { return }
        hasAnimatedAppearance = true
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        for (index, row) in appearanceRows.enumerated() {
            let animator = UIViewPropertyAnimator(duration: 0.32, dampingRatio: 0.84) {
                row.alpha = 1
                row.transform = .identity
            }
            animator.startAnimation(afterDelay: min(Double(index) * 0.045, 0.6))
        }
    }
}

/// A full-width Liquid Glass row control: brand-tinted glyph, title, optional
/// subtitle and trailing accessory, press-down scale feedback, and a
/// long-press context menu supplied by `menuProvider`. Falls back to a solid
/// fill when Reduce Transparency is enabled.
private final class GlassRow: UIControl {

    var onTap: (() -> Void)?
    var menuProvider: (() -> UIMenu?)?

    private static let cornerRadius: CGFloat = 18

    init(
        icon: UIImage?,
        iconTint: UIColor,
        title: String,
        subtitle: String? = nil,
        accessory: UIImage? = UIImage(systemName: "chevron.right"),
        accessibilityLabel: String
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let background = Self.makeBackground()
        background.isUserInteractionEnabled = false
        addSubview(background)

        let iconView = UIImageView(image: icon)
        iconView.tintColor = iconTint
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1

        let textStack = UIStackView(arrangedSubviews: [titleLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        if let subtitle {
            let subtitleLabel = UILabel()
            subtitleLabel.text = subtitle
            subtitleLabel.font = .preferredFont(forTextStyle: .caption2)
            subtitleLabel.adjustsFontForContentSizeCategory = true
            subtitleLabel.textColor = .tertiaryLabel
            subtitleLabel.numberOfLines = 1
            subtitleLabel.lineBreakMode = .byTruncatingMiddle
            textStack.addArrangedSubview(subtitleLabel)
        }

        let accessoryView = UIImageView(image: accessory)
        accessoryView.tintColor = .tertiaryLabel
        accessoryView.contentMode = .scaleAspectFit
        accessoryView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        accessoryView.setContentHuggingPriority(.required, for: .horizontal)
        accessoryView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let rowStack = UIStackView(arrangedSubviews: [iconView, textStack, accessoryView])
        rowStack.spacing = 14
        rowStack.alignment = .center
        rowStack.isUserInteractionEnabled = false
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 54),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            rowStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            rowStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])

        isAccessibilityElement = true
        self.accessibilityLabel = accessibilityLabel
        accessibilityTraits = .button

        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { setPressed(isHighlighted) }
    }

    @objc private func handleTap() {
        onTap?()
    }

    private static func makeBackground() -> UIView {
        if UIAccessibility.isReduceTransparencyEnabled {
            let solid = UIView()
            solid.backgroundColor = .secondarySystemGroupedBackground
            solid.layer.cornerRadius = cornerRadius
            solid.layer.cornerCurve = .continuous
            solid.clipsToBounds = true
            return solid
        }
        return LiquidGlass.view(cornerRadius: cornerRadius, interactive: true)
    }

    private func setPressed(_ pressed: Bool) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let animator = UIViewPropertyAnimator(duration: 0.18, dampingRatio: 0.84) {
            self.transform = pressed ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity
        }
        animator.startAnimation()
    }
}

extension GlassRow {

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let menuProvider else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menuProvider() }
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ])
        return UIFont(descriptor: descriptor, size: 0)
    }
}
