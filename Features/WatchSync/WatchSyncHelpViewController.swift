import UIKit

/// The sheet behind "Show Me How": three numbered steps for getting Flaccy onto
/// the Apple Watch, and a Check Again button that reports what it found without
/// leaving the sheet.
final class WatchSyncHelpViewController: UIViewController {

    enum Topic {
        case install
        case pair

        var symbol: String {
            switch self {
            case .install: "arrow.down.app.fill"
            case .pair: "applewatch.slash"
            }
        }

        var title: String {
            switch self {
            case .install: String(localized: "Add Flaccy to Your Watch")
            case .pair: String(localized: "Pair Your Apple Watch")
            }
        }

        var summary: String {
            switch self {
            case .install: String(localized: "Flaccy sends music to its own app on your Apple Watch. Installing it takes about a minute.")
            case .pair: String(localized: "Flaccy sends music to an Apple Watch that is paired with this iPhone.")
            }
        }

        var steps: [(text: String, symbol: String)] {
            switch self {
            case .install:
                [
                    (String(localized: "Open the Watch app on your iPhone"), "applewatch"),
                    (String(localized: "Find Flaccy under Available Apps"), "magnifyingglass"),
                    (String(localized: "Tap Install and wait a minute"), "arrow.down.circle"),
                ]
            case .pair:
                [
                    (String(localized: "Open the Watch app on your iPhone"), "applewatch"),
                    (String(localized: "Tap Pair New Watch and follow the steps"), "plus.circle"),
                    (String(localized: "Install Flaccy from Available Apps if it isn’t on your Watch yet"), "arrow.down.circle"),
                ]
            }
        }
    }

    typealias Readiness = WatchSyncService.Readiness

    var performCheck: ((@escaping (Readiness) -> Void) -> Void)?

    private let topic: Topic
    private let resultLabel = UILabel()
    private let checkButton = UIButton(type: .system)
    private var isChecking = false

    init(topic: Topic) {
        self.topic = topic
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let content = makeContent()
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        let footer = makeFooter()
        footer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        view.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    private func makeContent() -> UIView {
        let stack = UIStackView(arrangedSubviews: [makeHeader(), makeStepsCard()])
        stack.axis = .vertical
        stack.spacing = 16
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 22, leading: 20, bottom: 12, trailing: 20)
        return stack
    }

    private func makeHeader() -> UIView {
        let badge = UIView()
        badge.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.16)
        badge.layer.cornerRadius = 18
        badge.layer.cornerCurve = .continuous
        badge.translatesAutoresizingMaskIntoConstraints = false
        let icon = UIImageView(image: UIImage(systemName: topic.symbol))
        icon.tintColor = .systemOrange
        icon.contentMode = .center
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(icon)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 56),
            badge.heightAnchor.constraint(equalToConstant: 56),
            icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])

        let title = UILabel()
        title.text = topic.title
        title.font = .watchSyncFont(.title2, weight: .bold)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0
        title.textAlignment = .center
        title.accessibilityTraits = .header

        let summary = UILabel()
        summary.text = topic.summary
        summary.font = .preferredFont(forTextStyle: .body)
        summary.adjustsFontForContentSizeCategory = true
        summary.textColor = .secondaryLabel
        summary.numberOfLines = 0
        summary.textAlignment = .center

        let badgeRow = UIStackView(arrangedSubviews: [badge])
        badgeRow.alignment = .center
        badgeRow.axis = .vertical

        let stack = UIStackView(arrangedSubviews: [badgeRow, title, summary])
        stack.axis = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(14, after: badgeRow)
        return stack
    }

    private func makeStepsCard() -> UIView {
        let rows = topic.steps.enumerated().map { index, step in
            StepRow(number: index + 1, text: step.text, symbol: step.symbol)
        }
        let stack = UIStackView()
        stack.axis = .vertical
        for (index, row) in rows.enumerated() {
            if index > 0 { stack.addArrangedSubview(StepSeparator()) }
            stack.addArrangedSubview(row)
        }
        stack.backgroundColor = .secondarySystemGroupedBackground
        stack.layer.cornerRadius = 16
        stack.layer.cornerCurve = .continuous
        stack.clipsToBounds = true
        return stack
    }

    private func configureResultLabel() {
        resultLabel.font = .preferredFont(forTextStyle: .subheadline)
        resultLabel.adjustsFontForContentSizeCategory = true
        resultLabel.textColor = .secondaryLabel
        resultLabel.numberOfLines = 0
        resultLabel.textAlignment = .center
        resultLabel.isHidden = true
    }

    private func makeFooter() -> UIView {
        var check = UIButton.Configuration.filled()
        check.cornerStyle = .capsule
        check.baseBackgroundColor = .systemOrange
        check.baseForegroundColor = .white
        check.buttonSize = .large
        check.image = UIImage(systemName: "arrow.clockwise")
        check.imagePadding = 8
        check.title = String(localized: "Check Again")
        checkButton.configuration = check
        checkButton.titleLabel?.adjustsFontForContentSizeCategory = true
        checkButton.addAction(UIAction { [weak self] _ in self?.checkAgain() }, for: .touchUpInside)
        checkButton.accessibilityHint = String(localized: "Looks for your Apple Watch again")

        var done = UIButton.Configuration.plain()
        done.title = String(localized: "Done")
        done.buttonSize = .medium
        let doneButton = UIButton(configuration: done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        doneButton.titleLabel?.adjustsFontForContentSizeCategory = true

        configureResultLabel()
        let stack = UIStackView(arrangedSubviews: [resultLabel, checkButton, doneButton])
        stack.axis = .vertical
        stack.spacing = 2
        stack.setCustomSpacing(10, after: resultLabel)
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 8, trailing: 20)
        return stack
    }

    private func checkAgain() {
        guard !isChecking, let performCheck else { return }
        isChecking = true
        showChecking(true)
        performCheck { [weak self] readiness in
            self?.isChecking = false
            self?.showChecking(false)
            self?.show(result: readiness)
        }
    }

    private func showChecking(_ checking: Bool) {
        var configuration = checkButton.configuration
        configuration?.showsActivityIndicator = checking
        configuration?.image = checking ? nil : UIImage(systemName: "arrow.clockwise")
        configuration?.title = checking ? String(localized: "Checking…") : String(localized: "Check Again")
        checkButton.configuration = configuration
        checkButton.isEnabled = !checking
        if checking { resultLabel.isHidden = true }
    }

    private func show(result readiness: Readiness) {
        if readiness.isReady {
            dismiss(animated: true)
            return
        }
        resultLabel.text = readiness.stillNotReadyMessage
        resultLabel.isHidden = false
        sheetPresentationController?.animateChanges { sheetPresentationController?.selectedDetentIdentifier = .large }
        UIAccessibility.post(notification: .announcement, argument: readiness.stillNotReadyMessage)
    }
}

private final class StepSeparator: UIView {

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .separator
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

private final class StepRow: UIView {

    init(number: Int, text: String, symbol: String) {
        super.init(frame: .zero)
        let badge = UILabel()
        badge.text = "\(number)"
        badge.font = UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .bold)
        badge.textColor = .white
        badge.textAlignment = .center
        badge.backgroundColor = .systemOrange
        badge.layer.cornerRadius = 14
        badge.clipsToBounds = true
        badge.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0

        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = .systemOrange
        icon.contentMode = .center
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [badge, label, icon])
        stack.spacing = 14
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 28),
            badge.heightAnchor.constraint(equalToConstant: 28),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Step \(number): \(text)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
