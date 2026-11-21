import MidgarCore
import UIKit

/// The first page of the 2.0 showcase: the hero, four things Flaccy does, and the way on. It plays its entrance once,
/// about a second long, and only then offers Continue, so it is seen and never sat through.
final class ShowcaseViewController: UIViewController {

    var onFinish: (() -> Void)?

    private let wash = ShowcaseWashView()
    private let scrollView = UIScrollView()
    private let hero = ShowcaseHeroView()
    private let rows = ShowcaseCopy.highlights.map { ShowcaseRowView(feature: $0) }
    private let haptics = ShowcaseHaptics()
    private let tap = UIImpactFeedbackGenerator(style: .light)
    private lazy var everythingButton = ShowcaseButtons.onward(title: ShowcaseCopy.seeEverything) { [weak self] in
        self?.showEverything(animated: true)
    }
    private lazy var continueButton = ShowcaseButtons.primary(title: ShowcaseCopy.proceed) { [weak self] in
        self?.finish()
    }
    private var hasPlayedEntrance = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.backButtonTitle = ShowcaseCopy.back
        buildContent()
        prepareForEntrance()
        MidgarLog.info("Showcase \(ShowcaseCopy.version) shown", category: .ui)
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

    /// Opens the second page, where everything Flaccy can do is listed.
    func showEverything(animated: Bool) {
        tap.impactOccurred()
        let everything = ShowcaseFeaturesViewController()
        everything.onFinish = { [weak self] in self?.finish() }
        navigationController?.pushViewController(everything, animated: animated)
    }

    private func finish() {
        tap.impactOccurred()
        MidgarLog.info("Showcase \(ShowcaseCopy.version) closed", category: .ui)
        onFinish?()
    }

    private func buildContent() {
        let rowStack = UIStackView(arrangedSubviews: rows)
        rowStack.axis = .vertical
        rowStack.spacing = 18

        let content = UIStackView(arrangedSubviews: [hero, rowStack])
        content.axis = .vertical
        content.spacing = 30
        content.isLayoutMarginsRelativeArrangement = true
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 36, leading: 28, bottom: 20, trailing: 28)
        content.translatesAutoresizingMaskIntoConstraints = false

        let buttons = UIStackView(arrangedSubviews: [everythingButton, continueButton])
        buttons.axis = .vertical
        buttons.spacing = 10
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
        (rows + [everythingButton, continueButton]).forEach {
            $0.alpha = 0
            $0.transform = CGAffineTransform(translationX: 0, y: 14)
        }
        everythingButton.isEnabled = false
        continueButton.isEnabled = false
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
        for button in [everythingButton, continueButton] {
            if gentle { button.transform = .identity }
            ShowcaseHeroView.rise(button, delay: buttonsAt)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + buttonsAt) { [weak self] in
            self?.everythingButton.isEnabled = true
            self?.continueButton.isEnabled = true
            UIAccessibility.post(notification: .screenChanged, argument: self?.hero)
        }
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
