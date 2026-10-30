import MidgarCore
import UIKit

/// The welcome's Flaccy Server step: three numbered steps from nothing to a connected iPhone, the last one a camera.
/// Scanning the code the computer shows connects at once; the person never types a URL unless they ask to.
final class ServerSetupGuideViewController: UIViewController {

    var onConnected: (() -> Void)?

    private let scrollView = UIScrollView()
    private let impact = UIImpactFeedbackGenerator(style: .light)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.title = WelcomeCopy.guideTitle
        navigationItem.largeTitleDisplayMode = .never
        buildContent()
        MidgarLog.info("Welcome: Flaccy Server step shown", category: .ui)
    }

    private func buildContent() {
        let lead = WelcomeViewController.label(WelcomeCopy.guideLead, style: .body, color: .secondaryLabel)

        let tailscale = Self.button(WelcomeCopy.getTailscale, symbol: "arrow.up.forward.app", style: .gray())
        tailscale.accessibilityIdentifier = "welcome.guide.tailscale"
        tailscale.addAction(UIAction { [weak self] _ in
            self?.impact.impactOccurred()
            AddFlaccyServerViewController.openTailscale()
        }, for: .touchUpInside)

        let send = Self.button(WelcomeCopy.sendGuide, symbol: "square.and.arrow.up", style: .gray())
        send.accessibilityIdentifier = "welcome.guide.send"
        send.addAction(UIAction { [weak self, weak send] _ in self?.shareGuide(from: send) }, for: .touchUpInside)

        let scan = Self.button(WelcomeCopy.scan, symbol: "qrcode.viewfinder", style: .filled())
        scan.accessibilityIdentifier = "welcome.guide.scan"
        scan.addAction(UIAction { [weak self] _ in self?.openAddServer(scanning: true) }, for: .touchUpInside)

        var typeConfiguration = UIButton.Configuration.plain()
        typeConfiguration.title = WelcomeCopy.typeInstead
        let type = UIButton(configuration: typeConfiguration)
        type.contentHorizontalAlignment = .leading
        type.accessibilityIdentifier = "welcome.guide.type"
        type.addAction(UIAction { [weak self] _ in self?.openAddServer(scanning: false) }, for: .touchUpInside)

        let steps = [
            Self.step(1, WelcomeCopy.stepTailscaleTitle, WelcomeCopy.stepTailscaleDetail, actions: [tailscale]),
            Self.step(2, WelcomeCopy.stepServerTitle, WelcomeCopy.stepServerDetail, actions: [send]),
            Self.step(3, WelcomeCopy.stepScanTitle, WelcomeCopy.stepScanDetail, actions: [scan, type]),
        ]

        let note = WelcomeViewController.label(WelcomeCopy.proNote, style: .footnote, color: .tertiaryLabel)

        let stack = UIStackView(arrangedSubviews: [lead] + steps + [note])
        stack.axis = .vertical
        stack.spacing = 28
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 24, bottom: 32, trailing: 24)
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

    private func openAddServer(scanning: Bool) {
        impact.impactOccurred()
        let add = AddFlaccyServerViewController()
        add.opensScannerOnAppear = scanning
        add.onFinish = { [weak self] in self?.onConnected?() }
        navigationController?.pushViewController(add, animated: true)
    }

    /// The guide's address goes to the computer by AirDrop, Messages or Mail, so the person opens it where the commands run.
    private func shareGuide(from source: UIView?) {
        impact.impactOccurred()
        let share = UIActivityViewController(activityItems: [WelcomeCopy.sendGuideMessage, WelcomeCopy.setupGuideURL], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = source
        present(share, animated: true)
    }

    private static func step(_ number: Int, _ title: String, _ detail: String, actions: [UIView]) -> UIView {
        let badge = UILabel()
        badge.text = number.formatted()
        badge.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .monospacedDigitSystemFont(ofSize: 15, weight: .bold))
        badge.adjustsFontForContentSizeCategory = true
        badge.textColor = .white
        badge.textAlignment = .center
        badge.backgroundColor = .tintColor
        badge.layer.cornerRadius = 14
        badge.layer.masksToBounds = true
        badge.isAccessibilityElement = false
        badge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 28),
            badge.heightAnchor.constraint(equalToConstant: 28),
        ])

        let titleLabel = WelcomeViewController.label(title, style: .headline)
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityLabel = String(localized: "Step \(number): \(title)")
        let detailLabel = WelcomeViewController.label(detail, style: .subheadline, color: .secondaryLabel)

        let text = UIStackView(arrangedSubviews: [titleLabel, detailLabel] + actions)
        text.axis = .vertical
        text.alignment = .fill
        text.spacing = 6
        text.setCustomSpacing(12, after: detailLabel)

        let row = UIStackView(arrangedSubviews: [badge, text])
        row.alignment = .top
        row.spacing = 14
        return row
    }

    private static func button(_ title: String, symbol: String, style: UIButton.Configuration) -> UIButton {
        var configuration = style
        configuration.title = title
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePadding = 8
        configuration.cornerStyle = .large
        configuration.buttonSize = .large
        return UIButton(configuration: configuration)
    }
}
