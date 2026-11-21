import MidgarCore
import UIKit

/// The first page of the 2.0 showcase: the hero, four things Flaccy does, where the person's trial or purchase
/// stands, and the way on. It plays its entrance once, about a second long, and only then offers its buttons, so it
/// is seen and never sat through.
final class ShowcaseViewController: UIViewController {

    var onFinish: ((ShowcaseFooter.Action) -> Void)?

    private let wash = ShowcaseWashView()
    private let scrollView = ShowcaseScrollView()
    private let hero = ShowcaseHeroView()
    private let rows = ShowcaseCopy.highlights.map { ShowcaseRowView(feature: $0) }
    private lazy var rowStack = UIStackView(arrangedSubviews: rows)
    private lazy var content = UIStackView(arrangedSubviews: [hero, rowStack])
    private var isTight = false
    private let haptics = ShowcaseHaptics()
    private let tap = UIImpactFeedbackGenerator(style: .light)
    private lazy var everythingButton = ShowcaseButtons.onward(title: ShowcaseCopy.seeEverything) { [weak self] in
        self?.showEverything(animated: true)
    }
    private let statusLabel = WelcomeViewController.label("", style: .footnote, color: .secondaryLabel)
    private lazy var primaryButton = ShowcaseButtons.primary(title: ShowcaseCopy.proceed) { [weak self] in
        self?.finish(with: self?.footer.primary ?? .listen)
    }
    private lazy var secondaryButton = ShowcaseButtons.quiet(title: ShowcaseCopy.seePlans) { [weak self] in
        self?.finish(with: self?.footer.secondary ?? .listen)
    }
    private var footer = ShowcaseFooter.make(for: nil)
    private var hasPlayedEntrance = false

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tightenIfThePageDoesNotFit()
    }

    /// Closes up the page's spacing the first time its content is taller than the room above the buttons (a long
    /// language, larger text, a small iPhone, a status line that takes two lines), which is often all the fourth row
    /// needs to fit whole. It never opens up again, so a foot that changes size cannot make the page breathe in and
    /// out; whatever still does not fit scrolls, and `ShowcaseScrollView` fades it out at the edge.
    private func tightenIfThePageDoesNotFit() {
        guard !isTight, scrollView.bounds.height > 0, content.bounds.height > scrollView.bounds.height + 0.5 else { return }
        isTight = true
        content.spacing = 20
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 20, leading: 28, bottom: 12, trailing: 28)
        rowStack.spacing = 13
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.backButtonTitle = ShowcaseCopy.back
        buildContent()
        apply(ShowcaseFooter.current)
        prepareForEntrance()
        NotificationCenter.default.addObserver(
            self, selector: #selector(entitlementsDidLoad), name: PurchaseManager.entitlementsDidLoad, object: nil
        )
        MidgarLog.info("Showcase \(ShowcaseCopy.version) shown", category: .ui)
    }

    /// The store answered after the showcase opened, so the foot can now say where the person stands.
    @objc private func entitlementsDidLoad() {
        apply(ShowcaseFooter.current)
    }

    /// Shows a foot: the status line, the main button's title, and the second button when there is one.
    private func apply(_ footer: ShowcaseFooter) {
        self.footer = footer
        statusLabel.text = footer.status
        statusLabel.font = .preferredFont(forTextStyle: footer.statusLeads ? .subheadline : .footnote)
        statusLabel.textColor = footer.statusLeads ? .label : .secondaryLabel
        statusLabel.isHidden = footer.status == nil
        primaryButton.configuration?.title = footer.primaryTitle
        secondaryButton.configuration?.title = footer.secondaryTitle
        secondaryButton.isHidden = footer.secondaryTitle == nil
        (navigationController?.viewControllers.last as? ShowcaseFeaturesViewController)?.apply(footer)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        guard !hasPlayedEntrance else { return }
        hasPlayedEntrance = true
        haptics.prepare()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.entranceDelay) { [weak self] in self?.playEntrance() }
    }

    /// How long after the sheet starts to rise the entrance begins, so the two overlap and neither waits for the other.
    private static let entranceDelay: TimeInterval = 0.24

    /// Opens the second page, where everything Flaccy can do is listed. The first page is loaded first, so the second
    /// takes the foot the person's trial calls for even when a launch opens straight on it.
    func showEverything(animated: Bool) {
        loadViewIfNeeded()
        tap.impactOccurred()
        let everything = ShowcaseFeaturesViewController(footer: footer)
        everything.onFinish = { [weak self] action in self?.finish(with: action) }
        navigationController?.pushViewController(everything, animated: animated)
    }

    private func finish(with action: ShowcaseFooter.Action) {
        tap.impactOccurred()
        MidgarLog.info("Showcase \(ShowcaseCopy.version) closed for \(action)", category: .ui)
        onFinish?(action)
    }

    private func buildContent() {
        rowStack.axis = .vertical
        rowStack.spacing = 18

        content.axis = .vertical
        content.spacing = 30
        content.isLayoutMarginsRelativeArrangement = true
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 36, leading: 28, bottom: 20, trailing: 28)
        content.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textAlignment = .center
        let buttons = UIStackView(arrangedSubviews: [statusLabel, everythingButton, primaryButton, secondaryButton])
        buttons.axis = .vertical
        buttons.spacing = 10
        buttons.setCustomSpacing(4, after: statusLabel)
        buttons.setCustomSpacing(2, after: primaryButton)
        buttons.translatesAutoresizingMaskIntoConstraints = false

        wash.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = false
        scrollView.showsVerticalScrollIndicator = false
        view.addSubview(wash)
        view.addSubview(scrollView)
        view.addSubview(buttons)
        scrollView.addSubview(content)

        let readable = content.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        readable.priority = .defaultHigh
        let buttonsWide = buttons.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -48)
        buttonsWide.priority = .defaultHigh
        NSLayoutConstraint.activate([
            wash.topAnchor.constraint(equalTo: view.topAnchor),
            wash.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            wash.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            wash.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.5),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),
            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            content.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.frameLayoutGuide.trailingAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            readable,
            buttons.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            buttons.widthAnchor.constraint(lessThanOrEqualToConstant: 432),
            buttonsWide,
            buttons.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

    private func prepareForEntrance() {
        hero.prepareForEntrance()
        (rows + footerViews).forEach {
            $0.alpha = 0
            $0.transform = CGAffineTransform(translationX: 0, y: 14)
        }
        footerButtons.forEach { $0.isEnabled = false }
    }

    private func playEntrance() {
        let gentle = UIAccessibility.isReduceMotionEnabled
        haptics.playEntrance(rowCount: rows.count, gentle: gentle)
        hero.playEntrance(gentle: gentle)
        let buttonsAt = gentle ? 0 : ShowcaseTiming.buttons(rowCount: rows.count)
        for (index, row) in rows.enumerated() {
            if gentle { row.transform = .identity }
            ShowcaseHeroView.rise(row, delay: gentle ? 0 : ShowcaseTiming.row(index))
        }
        for view in footerViews {
            if gentle { view.transform = .identity }
            ShowcaseHeroView.rise(view, delay: buttonsAt)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + buttonsAt) { [weak self] in
            self?.footerButtons.forEach { $0.isEnabled = true }
            UIAccessibility.post(notification: .screenChanged, argument: self?.hero)
        }
    }

    private var footerButtons: [UIButton] { [everythingButton, primaryButton, secondaryButton] }
    private var footerViews: [UIView] { [statusLabel] + footerButtons }
}

/// The showcase's scroll area. While more of the page lies below its bottom edge the last stretch fades out, so a
/// page too tall for the sheet reads as one that scrolls and never as one cut off; at the end it is whole again.
final class ShowcaseScrollView: UIScrollView {

    private static let fadeHeight: CGFloat = 40

    private let fade = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.mask = fade
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Runs at every scroll step, so the mask follows the visible bounds and its fade shrinks to nothing over the
    /// last stretch of the content.
    override func layoutSubviews() {
        super.layoutSubviews()
        let below = contentSize.height - (contentOffset.y + bounds.height)
        let reach = min(1, max(0, below / Self.fadeHeight))
        let solidUntil = bounds.height > 0 ? 1 - Self.fadeHeight * reach / bounds.height : 1
        let solid = UIColor.black.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        fade.colors = [solid, solid, reach > 0 ? UIColor.clear.cgColor : solid]
        fade.locations = [0, NSNumber(value: Double(solidUntil)), 1]
        CATransaction.commit()
    }
}

/// The two kinds of button the showcase uses.
@MainActor
enum ShowcaseButtons {

    /// The filled capsule that finishes the showcase.
    static func primary(title: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.cornerStyle = .capsule
        configuration.buttonSize = .large
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .headline)
            return attributes
        }
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.accessibilityIdentifier = "showcase.continue"
        return button
    }

    /// The small plain button under the main one, for the other way on.
    static func quiet(title: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.buttonSize = .small
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .subheadline)
            return attributes
        }
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.accessibilityIdentifier = "showcase.secondary"
        return button
    }

    /// The plain button with a chevron that leads further in.
    static func onward(title: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = UIImage(systemName: "chevron.forward")
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 6
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)
        configuration.buttonSize = .medium
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .subheadline)
            return attributes
        }
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.accessibilityIdentifier = "showcase.everything"
        return button
    }
}

/// A wash of the accent over the top of the page that fades out downwards.
final class ShowcaseWashView: UIView {

    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ShowcaseWashView, _) in view.applyColors() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyColors()
    }

    private func applyColors() {
        guard let gradient = layer as? CAGradientLayer else { return }
        let accent = tintColor.resolvedColor(with: traitCollection)
        let strength: CGFloat = traitCollection.userInterfaceStyle == .dark ? 0.22 : 0.13
        gradient.colors = [accent.withAlphaComponent(strength).cgColor, accent.withAlphaComponent(0).cgColor]
    }
}
