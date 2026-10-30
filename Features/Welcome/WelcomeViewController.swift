import MidgarCore
import UIKit

/// The first thing a new Flaccy shows: where the person's music is, and the shortest way in from there. Picking a place
/// closes the welcome and starts that way in, except "On my computer", which goes on to connecting Flaccy Server.
final class WelcomeViewController: UIViewController {

    enum Choice: Equatable {
        case importFiles
        case musicServer
        case sample
        case notNow
        case serverConnected
    }

    var onChoice: ((Choice) -> Void)?

    private let scrollView = UIScrollView()
    private let impact = UIImpactFeedbackGenerator(style: .light)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.backButtonTitle = String(localized: "Back")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: WelcomeCopy.notNow, primaryAction: UIAction { [weak self] _ in self?.choose(.notNow) }
        )
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "welcome.notNow"
        buildContent()
        MidgarLog.info("Welcome shown", category: .ui)
    }

    /// Opens the Flaccy Server step at once, for a run that asked for it.
    func showServerStep(animated: Bool) {
        let guide = ServerSetupGuideViewController()
        guide.onConnected = { [weak self] in self?.choose(.serverConnected) }
        navigationController?.pushViewController(guide, animated: animated)
    }

    private func buildContent() {
        let header = UIStackView(arrangedSubviews: [Self.makeIcon(), Self.label(WelcomeCopy.title, style: .largeTitle, weight: .bold)])
        header.axis = .vertical
        header.alignment = .center
        header.spacing = 16

        let subtitle = Self.label(WelcomeCopy.subtitle, style: .title3, color: .secondaryLabel)
        subtitle.textAlignment = .center

        let question = Self.label(WelcomeCopy.question, style: .headline)
        question.accessibilityTraits = .header

        let computer = WelcomeChoiceButton(
            symbol: "desktopcomputer", title: WelcomeCopy.computerTitle, detail: WelcomeCopy.computerDetail, prominent: true
        )
        computer.accessibilityIdentifier = "welcome.computer"
        computer.addAction(UIAction { [weak self] _ in self?.computerTapped() }, for: .touchUpInside)

        let files = WelcomeChoiceButton(symbol: "folder", title: WelcomeCopy.filesTitle, detail: WelcomeCopy.filesDetail)
        files.accessibilityIdentifier = "welcome.files"
        files.addAction(UIAction { [weak self] _ in self?.choose(.importFiles) }, for: .touchUpInside)

        let server = WelcomeChoiceButton(symbol: "server.rack", title: WelcomeCopy.serverTitle, detail: WelcomeCopy.serverDetail)
        server.accessibilityIdentifier = "welcome.musicServer"
        server.addAction(UIAction { [weak self] _ in self?.choose(.musicServer) }, for: .touchUpInside)

        var sampleConfiguration = UIButton.Configuration.plain()
        sampleConfiguration.title = WelcomeCopy.sample
        sampleConfiguration.titleAlignment = .center
        sampleConfiguration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .subheadline)
            return attributes
        }
        let sample = UIButton(configuration: sampleConfiguration)
        sample.accessibilityIdentifier = "welcome.sample"
        sample.addAction(UIAction { [weak self] _ in self?.choose(.sample) }, for: .touchUpInside)

        let trial = Self.label(PaywallCopy.trialStartsLine, style: .footnote, color: .tertiaryLabel)
        trial.textAlignment = .center
        trial.isHidden = PurchaseManager.shared.state != .trialNotStarted

        let stack = UIStackView(arrangedSubviews: [header, subtitle, question, computer, files, server, sample, trial])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(8, after: header)
        stack.setCustomSpacing(36, after: subtitle)
        stack.setCustomSpacing(14, after: question)
        stack.setCustomSpacing(20, after: server)
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 24, bottom: 32, trailing: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)
        scrollView.addSubview(stack)
        let readable = stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        readable.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.frameLayoutGuide.trailingAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            readable,
        ])
    }

    private func computerTapped() {
        impact.impactOccurred()
        MidgarLog.info("Welcome: on my computer", category: .ui)
        showServerStep(animated: true)
    }

    private func choose(_ choice: Choice) {
        impact.impactOccurred()
        MidgarLog.info("Welcome closed with \(choice)", category: .ui)
        onChoice?(choice)
    }

    /// The app's own icon, the first time the person sees it inside the app; a note symbol if the icon cannot be read.
    private static func makeIcon() -> UIView {
        let image = appIcon()
        let icon = UIImageView(image: image ?? UIImage(systemName: "music.note"))
        icon.contentMode = .scaleAspectFit
        icon.tintColor = .tintColor
        icon.layer.cornerRadius = 20
        icon.layer.cornerCurve = .continuous
        icon.clipsToBounds = image != nil
        icon.isAccessibilityElement = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 88),
            icon.heightAnchor.constraint(equalToConstant: 88),
        ])
        return icon
    }

    private static func appIcon() -> UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let name = files.last else { return nil }
        return UIImage(named: name)
    }

    static func label(
        _ text: String, style: UIFont.TextStyle, weight: UIFont.Weight? = nil, color: UIColor = .label
    ) -> UILabel {
        let label = UILabel()
        label.text = text
        if let weight {
            let base = UIFont.preferredFont(forTextStyle: style)
            label.font = UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: base.pointSize, weight: weight))
        } else {
            label.font = .preferredFont(forTextStyle: style)
        }
        label.textColor = color
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        return label
    }
}

/// One answer to "Where is your music?": a symbol, a title and a line of detail on a rounded card that is one big button.
final class WelcomeChoiceButton: UIButton {

    init(symbol: String, title: String, detail: String, prominent: Bool = false) {
        super.init(frame: .zero)
        var configuration: UIButton.Configuration = prominent ? .tinted() : .gray()
        configuration.image = UIImage(systemName: symbol)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .title2)
        configuration.imagePlacement = .leading
        configuration.imagePadding = 16
        configuration.title = title
        configuration.subtitle = detail
        configuration.titleAlignment = .leading
        configuration.titlePadding = 4
        configuration.titleLineBreakMode = .byWordWrapping
        configuration.subtitleLineBreakMode = .byWordWrapping
        configuration.cornerStyle = .large
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .headline)
            return attributes
        }
        configuration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .subheadline)
            attributes.foregroundColor = UIColor.secondaryLabel
            return attributes
        }
        self.configuration = configuration
        contentHorizontalAlignment = .leading
        accessibilityLabel = "\(title). \(detail)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
