import UIKit

/// The routes that really get music from a computer onto the phone, each one
/// something the app supports today: Finder file sharing and the Files app's
/// On My iPhone folder (`UIFileSharingEnabled`), and the Add Music picker
/// reading iCloud Drive, network shares and wherever AirDrop saved a file.
final class ComputerTransferGuideViewController: UIViewController {

    private struct Route {
        let symbol: String
        let title: String
        let detail: String
    }

    private static var routes: [Route] {
        [
            Route(
                symbol: "cable.connector",
                title: String(localized: "Finder, with a cable"),
                detail: String(localized: "Connect your iPhone to a Mac, select it in the Finder sidebar, open the Files tab and drag songs or folders onto Flaccy.")
            ),
            Route(
                symbol: "icloud",
                title: String(localized: "iCloud Drive or a network share"),
                detail: String(localized: "Put your music in iCloud Drive, or connect to a server in the Files app. Then tap Add Music and pick it.")
            ),
            Route(
                symbol: "dot.radiowaves.left.and.right",
                title: String(localized: "AirDrop"),
                detail: String(localized: "AirDrop the files to your iPhone and save them to Files. Then tap Add Music and choose them.")
            ),
        ]
    }

    private let scrollView = UIScrollView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.title = String(localized: "Moving music from a computer")
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        buildContent()
        AppLogger.info("Computer transfer guide opened", category: .ui)
    }

    private func buildContent() {
        let stack = UIStackView(arrangedSubviews: Self.routes.map(makeRow) + [makeFootnote()])
        stack.axis = .vertical
        stack.spacing = 22
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 20, left: 24, bottom: 32, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    private func makeRow(_ route: Route) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: route.symbol))
        icon.tintColor = .tintColor
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: 34).isActive = true

        let title = UILabel()
        title.text = route.title
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0

        let detail = UILabel()
        detail.text = route.detail
        detail.font = .preferredFont(forTextStyle: .subheadline)
        detail.textColor = .secondaryLabel
        detail.adjustsFontForContentSizeCategory = true
        detail.numberOfLines = 0

        let text = UIStackView(arrangedSubviews: [title, detail])
        text.axis = .vertical
        text.spacing = 4

        let row = UIStackView(arrangedSubviews: [icon, text])
        row.spacing = 14
        row.alignment = .top
        row.isAccessibilityElement = true
        row.accessibilityLabel = "\(route.title). \(route.detail)"
        return row
    }

    private func makeFootnote() -> UIView {
        let label = UILabel()
        label.text = String(localized: "Songs copied in with Finder or the Files app (On My iPhone › Flaccy) appear the next time Flaccy launches.")
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .tertiaryLabel
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        return label
    }
}
