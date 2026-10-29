import UIKit

/// The one informational sheet after the first sync with data on both sides (docs/server/UX.md section 4): what was combined, and OK.
final class ServerMergeSummaryViewController: UIViewController {

    private let summary: ServerMergeSummary
    private let stack = UIStackView()
    private let impact = UIImpactFeedbackGenerator(style: .light)

    init(summary: ServerMergeSummary) {
        self.summary = summary
        super.init(nibName: nil, bundle: nil)
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func present(_ summary: ServerMergeSummary, from presenter: UIViewController) {
        presenter.present(ServerMergeSummaryViewController(summary: summary), animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 32),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
        ])
        build()
    }

    private func build() {
        if !summary.playlistNames.isEmpty {
            stack.addArrangedSubview(heading(String(localized: "We combined your playlists.")))
            stack.addArrangedSubview(line(Self.playlistsLine(summary.playlistNames), identifier: "mergeSummary.playlists"))
        }
        if summary.lovesAdded > 0 {
            stack.addArrangedSubview(line(Self.lovesLine(summary.lovesAdded), identifier: "mergeSummary.loves"))
        }
        stack.addArrangedSubview(okButton())
    }

    private func heading(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFont(descriptor: UIFont.preferredFont(forTextStyle: .title2).fontDescriptor.withSymbolicTraits(.traitBold) ?? UIFont.preferredFont(forTextStyle: .title2).fontDescriptor, size: 0)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.accessibilityTraits = .header
        return label
    }

    private func line(_ text: String, identifier: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.accessibilityIdentifier = identifier
        return label
    }

    private func okButton() -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = String(localized: "OK")
        configuration.cornerStyle = .large
        let button = UIButton(configuration: configuration)
        button.addAction(UIAction { [weak self] _ in
            self?.impact.impactOccurred()
            self?.dismiss(animated: true)
        }, for: .touchUpInside)
        button.accessibilityIdentifier = "mergeSummary.ok"
        return button
    }

    static func playlistsLine(_ names: [String]) -> String {
        let list = ListFormatter.localizedString(byJoining: names)
        return names.count == 1
            ? String(localized: "\(list) was on both devices and is now one.")
            : String(localized: "\(list) were on both devices and are now one each.")
    }

    static func lovesLine(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 song is now loved here, from your other devices.")
            : String(localized: "\(count) songs are now loved here, from your other devices.")
    }
}

/// Shows the merge summary over whatever is on screen when the reporter has one, once.
@MainActor
final class ServerMergePresenter {

    private weak var window: UIWindow?

    init(window: UIWindow?) {
        self.window = window
        NotificationCenter.default.addObserver(
            forName: ServerMergeReporter.didFinish, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.present() }
        }
    }

    private func present(attempt: Int = 0) {
        guard let top = TrialRunwayPresenter.topmostViewController(in: window) else { return }
        guard !top.isBeingDismissed, !top.isBeingPresented else {
            guard attempt < 10 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.present(attempt: attempt + 1) }
            return
        }
        guard let summary = ServerMergeReporter.shared.take() else { return }
        ServerMergeSummaryViewController.present(summary, from: top)
    }
}
