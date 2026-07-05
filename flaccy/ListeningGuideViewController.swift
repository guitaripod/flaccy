import UIKit

/// A dark editorial explainer on what Bluetooth, AAC, and lossless formats
/// actually deliver, rendered as a scrolling stack of fact cards.
final class ListeningGuideViewController: UIViewController {

    private static let accent = QualityBadgeView.losslessTint

    private let backdropView = AmbientPaletteBackdropView()
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let impactLight = UIImpactFeedbackGenerator(style: .light)

    private var animatableViews: [UIView] = []
    private var hasAnimatedAppearance = false

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        navigationItem.largeTitleDisplayMode = .never
        configureNavigationBarAppearance()
        setupBackdrop()
        setupScrollView()
        buildContent()
        AppLogger.info("Listening guide opened", category: .ui)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.navigationBar.overrideUserInterfaceStyle = .dark
        prepareAppearanceAnimationIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        runAppearanceAnimationIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.navigationBar.overrideUserInterfaceStyle = .unspecified
    }

    private func configureNavigationBarAppearance() {
        let scrollEdge = UINavigationBarAppearance()
        scrollEdge.configureWithTransparentBackground()
        let standard = UINavigationBarAppearance()
        standard.configureWithDefaultBackground()
        standard.titleTextAttributes = [.foregroundColor: UIColor.white]
        navigationItem.scrollEdgeAppearance = scrollEdge
        navigationItem.standardAppearance = standard
        navigationItem.compactAppearance = standard
    }

    private func setupBackdrop() {
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdropView)
        NSLayoutConstraint.activate([
            backdropView.topAnchor.constraint(equalTo: view.topAnchor),
            backdropView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdropView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        backdropView.apply(
            ArtworkPaletteExtractor.fallbackPalette(seed: "listening-guide"),
            animated: false
        )
    }

    private func setupScrollView() {
        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = 16
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.layoutMargins = UIEdgeInsets(top: 12, left: 20, bottom: 40, right: 20)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    private func buildContent() {
        let header = makeHeaderView()
        contentStack.addArrangedSubview(header)
        contentStack.setCustomSpacing(24, after: header)
        animatableViews.append(header)

        for card in ListeningGuideContent.cards {
            let cardView = makeCardView(for: card)
            contentStack.addArrangedSubview(cardView)
            animatableViews.append(cardView)
        }
    }

    private func makeHeaderView() -> UIView {
        let captionLabel = UILabel()
        captionLabel.attributedText = Self.letterspaced(
            ListeningGuideContent.caption.uppercased(),
            font: .scaled(.caption1, size: 12, weight: .bold),
            color: UIColor.white.withAlphaComponent(0.65),
            kern: 2.2
        )
        captionLabel.adjustsFontForContentSizeCategory = true

        let titleLabel = UILabel()
        titleLabel.text = ListeningGuideContent.headline
        titleLabel.font = .scaled(.largeTitle, size: 32, weight: .heavy)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits = .header

        let introLabel = UILabel()
        introLabel.attributedText = Self.paragraph(
            ListeningGuideContent.intro,
            font: .scaled(.callout, size: 16, weight: .regular),
            color: UIColor.white.withAlphaComponent(0.6),
            lineSpacing: 3
        )
        introLabel.adjustsFontForContentSizeCategory = true
        introLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [captionLabel, titleLabel, introLabel])
        stack.axis = .vertical
        stack.spacing = 6
        stack.setCustomSpacing(8, after: titleLabel)
        return stack
    }

    private func makeCardView(for card: ListeningGuideCard) -> UIView {
        let cardView = makeCardBackground()

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: cardView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
        ])

        stack.addArrangedSubview(makeCardHeader(title: card.title, symbolName: card.symbolName))
        stack.addArrangedSubview(makeBodyLabel(card.body))

        if !card.bullets.isEmpty {
            stack.addArrangedSubview(makeBulletsView(caption: card.bulletsCaption, bullets: card.bullets))
        }
        if let takeaway = card.takeaway {
            stack.addArrangedSubview(makeTakeawayView(caption: card.takeawayCaption, text: takeaway))
        }
        if let sourceLabel = card.sourceLabel, let sourceURL = card.sourceURL {
            stack.addArrangedSubview(makeSourceButton(label: sourceLabel, url: sourceURL))
        }

        return cardView
    }

    private func makeCardBackground() -> UIView {
        let card = UIView()
        if UIAccessibility.isReduceTransparencyEnabled {
            card.backgroundColor = UIColor.white.withAlphaComponent(0.1)
        } else {
            card.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        }
        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 0.5
        card.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        return card
    }

    private func makeCardHeader(title: String, symbolName: String) -> UIView {
        let tile = UIView()
        tile.backgroundColor = Self.accent.withAlphaComponent(0.16)
        tile.layer.cornerRadius = 12
        tile.layer.cornerCurve = .continuous
        tile.translatesAutoresizingMaskIntoConstraints = false

        let symbolView = UIImageView(
            image: UIImage(
                systemName: symbolName,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
            )
        )
        symbolView.tintColor = Self.accent.withAlphaComponent(0.9)
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(symbolView)

        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 40),
            tile.heightAnchor.constraint(equalToConstant: 40),
            symbolView.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .scaled(.title3, size: 20, weight: .bold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits = .header

        let row = UIStackView(arrangedSubviews: [tile, titleLabel])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        return row
    }

    private func makeBodyLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.attributedText = Self.paragraph(
            text,
            font: .scaled(.subheadline, size: 15, weight: .regular),
            color: UIColor.white.withAlphaComponent(0.8),
            lineSpacing: 3.5
        )
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        return label
    }

    private func makeBulletsView(caption: String?, bullets: [String]) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8

        if let caption {
            let captionLabel = UILabel()
            captionLabel.attributedText = Self.letterspaced(
                caption.uppercased(),
                font: .scaled(.caption1, size: 11, weight: .bold),
                color: UIColor.white.withAlphaComponent(0.55),
                kern: 1.5
            )
            captionLabel.adjustsFontForContentSizeCategory = true
            stack.addArrangedSubview(captionLabel)
        }

        for bullet in bullets {
            let dotLabel = UILabel()
            dotLabel.text = "•"
            dotLabel.font = .scaled(.subheadline, size: 15, weight: .bold)
            dotLabel.adjustsFontForContentSizeCategory = true
            dotLabel.textColor = Self.accent.withAlphaComponent(0.9)
            dotLabel.setContentHuggingPriority(.required, for: .horizontal)
            dotLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            dotLabel.isAccessibilityElement = false

            let textLabel = makeBodyLabel(bullet)

            let row = UIStackView(arrangedSubviews: [dotLabel, textLabel])
            row.axis = .horizontal
            row.spacing = 8
            row.alignment = .firstBaseline
            stack.addArrangedSubview(row)
        }

        return stack
    }

    private func makeTakeawayView(caption: String?, text: String) -> UIView {
        let box = UIView()
        box.backgroundColor = Self.accent.withAlphaComponent(0.12)
        box.layer.cornerRadius = 14
        box.layer.cornerCurve = .continuous

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 5
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])

        if let caption {
            let captionLabel = UILabel()
            captionLabel.attributedText = Self.letterspaced(
                caption.uppercased(),
                font: .scaled(.caption1, size: 11, weight: .bold),
                color: Self.accent,
                kern: 1.5
            )
            captionLabel.adjustsFontForContentSizeCategory = true
            stack.addArrangedSubview(captionLabel)
        }

        let textLabel = UILabel()
        textLabel.attributedText = Self.paragraph(
            text,
            font: .scaled(.footnote, size: 13, weight: .semibold),
            color: UIColor.white.withAlphaComponent(0.9),
            lineSpacing: 2.5
        )
        textLabel.adjustsFontForContentSizeCategory = true
        textLabel.numberOfLines = 0
        stack.addArrangedSubview(textLabel)

        return box
    }

    private func makeSourceButton(label: String, url: URL) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.contentInsets = .zero
        config.imagePadding = 5
        config.imagePlacement = .trailing
        config.image = UIImage(
            systemName: "arrow.up.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        )
        config.attributedTitle = AttributedString(
            label,
            attributes: AttributeContainer([.font: UIFont.scaled(.footnote, size: 13, weight: .semibold)])
        )
        config.baseForegroundColor = Self.accent

        let button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .leading
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.accessibilityLabel = "Apple Support article, \(label)"
        button.accessibilityHint = "Opens in your browser"
        button.addAction(UIAction { [weak self] _ in
            self?.impactLight.impactOccurred()
            AppLogger.info("Listening guide source opened: \(url.absoluteString)", category: .ui)
            UIApplication.shared.open(url)
        }, for: .touchUpInside)
        return button
    }

    private func prepareAppearanceAnimationIfNeeded() {
        guard !hasAnimatedAppearance, !UIAccessibility.isReduceMotionEnabled else { return }
        for view in animatableViews {
            view.alpha = 0
            view.transform = CGAffineTransform(translationX: 0, y: 14)
        }
    }

    private func runAppearanceAnimationIfNeeded() {
        guard !hasAnimatedAppearance else { return }
        hasAnimatedAppearance = true
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        for (index, view) in animatableViews.enumerated() {
            let animator = UIViewPropertyAnimator(duration: 0.42, dampingRatio: 0.76) {
                view.alpha = 1
                view.transform = .identity
            }
            animator.startAnimation(afterDelay: 0.05 * Double(index))
        }
    }

    private static func letterspaced(
        _ text: String,
        font: UIFont,
        color: UIColor,
        kern: CGFloat
    ) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color, .kern: kern]
        )
    }

    private static func paragraph(
        _ text: String,
        font: UIFont,
        color: UIColor,
        lineSpacing: CGFloat
    ) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        return NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]
        )
    }
}
