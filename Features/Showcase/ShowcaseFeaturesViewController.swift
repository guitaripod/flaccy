import UIKit

/// The second page of the showcase: everything Flaccy can do, in groups, as long as it needs to be. It scrolls under
/// a bar that keeps Continue in reach.
final class ShowcaseFeaturesViewController: UIViewController {

    var onFinish: (() -> Void)?

    private let scrollView = UIScrollView()
    private let bar = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private lazy var continueButton = ShowcaseButtons.primary(title: ShowcaseCopy.proceed) { [weak self] in
        self?.onFinish?()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildContent()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let covered = max(view.bounds.maxY - bar.frame.minY - view.safeAreaInsets.bottom, 0)
        scrollView.contentInset.bottom = covered
        scrollView.verticalScrollIndicatorInsets.bottom = covered
    }

    private func buildContent() {
        let heading = WelcomeViewController.label(ShowcaseCopy.everythingTitle, style: .largeTitle, weight: .bold)
        heading.accessibilityTraits = .header

        let content = UIStackView(arrangedSubviews: [heading])
        content.axis = .vertical
        content.spacing = 10
        content.setCustomSpacing(22, after: heading)
        for section in ShowcaseCopy.sections(bringsMusicOverWiFi: true) {
            let title = WelcomeViewController.label(section.title, style: .title3, weight: .semibold)
            title.accessibilityTraits = .header
            let card = Self.card(for: section)
            content.addArrangedSubview(title)
            content.addArrangedSubview(card)
            content.setCustomSpacing(26, after: card)
        }
        content.isLayoutMarginsRelativeArrangement = true
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 24, bottom: 12, trailing: 24)
        content.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        continueButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        view.addSubview(bar)
        scrollView.addSubview(content)
        bar.contentView.addSubview(continueButton)

        let readable = content.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        readable.priority = .defaultHigh
        let buttonWide = continueButton.widthAnchor.constraint(equalTo: bar.widthAnchor, constant: -48)
        buttonWide.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            content.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.frameLayoutGuide.trailingAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            readable,
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            continueButton.topAnchor.constraint(equalTo: bar.topAnchor, constant: 12),
            continueButton.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            continueButton.leadingAnchor.constraint(greaterThanOrEqualTo: bar.leadingAnchor, constant: 24),
            continueButton.widthAnchor.constraint(lessThanOrEqualToConstant: 432),
            buttonWide,
            continueButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

    private static func card(for section: ShowcaseSection) -> UIView {
        let rows = UIStackView(arrangedSubviews: section.features.map { ShowcaseRowView(feature: $0) })
        rows.axis = .vertical
        rows.spacing = 18
        rows.isLayoutMarginsRelativeArrangement = true
        rows.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 16)
        rows.translatesAutoresizingMaskIntoConstraints = false

        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous
        card.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: card.topAnchor),
            rows.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return card
    }
}
