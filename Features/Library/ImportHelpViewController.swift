import MidgarCore
import UIKit

/// What a person sees when Add Music left them with nothing: they closed the Files picker with an empty library, or
/// what they picked held no music Flaccy can add. It names the reason when there is one, then the places music
/// usually is and the way in from each, so the next tap gets music in instead of another empty pick.
final class ImportHelpViewController: UIViewController {

    enum Action {
        case chooseFiles
        case wifiTransfer
        case musicServer
        case sample
    }

    private struct Place {
        let symbol: String
        let title: String
        let detail: String
        let action: Action?
        let identifier: String
    }

    var onAction: ((Action) -> Void)?

    private let reason: String?
    private let offersSample: Bool
    private let impact = UIImpactFeedbackGenerator(style: .light)

    /// Once a launch is enough for the picker closing on an empty library; a pick that found nothing always says so.
    private(set) static var offeredAfterCancel = false

    init(reason: String?, offersSample: Bool) {
        self.reason = reason
        self.offersSample = offersSample
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func noteOfferedAfterCancel() {
        offeredAfterCancel = true
    }

    /// The help in a sheet that opens at half height, with its own Done.
    static func sheet(reason: String?, offersSample: Bool, onAction: @escaping (Action) -> Void) -> UINavigationController {
        let help = ImportHelpViewController(reason: reason, offersSample: offersSample)
        help.onAction = onAction
        let navigation = UINavigationController(rootViewController: help)
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.detents = [.medium(), .large()]
        navigation.sheetPresentationController?.prefersGrabberVisible = true
        return navigation
    }

    private var places: [Place] {
        [
            Place(
                symbol: "laptopcomputer",
                title: WelcomeCopy.computerTitle,
                detail: WelcomeCopy.computerDetail,
                action: .wifiTransfer,
                identifier: "importHelp.computer"
            ),
            Place(
                symbol: "doc.zipper",
                title: String(localized: "In a zip you downloaded"),
                detail: String(localized: "Tap the zip in the Files app to unzip it, then choose the folder it makes."),
                action: nil,
                identifier: "importHelp.zip"
            ),
            Place(
                symbol: "server.rack",
                title: WelcomeCopy.serverTitle,
                detail: WelcomeCopy.serverDetail,
                action: .musicServer,
                identifier: "importHelp.server"
            ),
            Place(
                symbol: "dot.radiowaves.left.and.right",
                title: String(localized: "In a streaming app"),
                detail: String(localized: "Songs from Apple Music, Spotify and other streaming services are locked to their app, so no other player can add them. Flaccy plays music files you own."),
                action: nil,
                identifier: "importHelp.streaming"
            ),
        ]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.title = reason == nil ? String(localized: "Can't Find Your Music?") : String(localized: "Nothing Was Added")
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in
                self?.impact.impactOccurred()
                self?.dismiss(animated: true)
            }
        )
        buildContent()
        MidgarLog.info("Import help opened\(reason == nil ? " after the picker closed" : " after a pick that added nothing")", category: .ui)
    }

    private func buildContent() {
        var rows: [UIView] = []
        if let reason { rows.append(makeReasonCard(reason)) }
        rows.append(makeLead())
        rows += places.map(makePlaceCard)
        let stack = UIStackView(arrangedSubviews: rows)
        stack.axis = .vertical
        stack.spacing = 12
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 12, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let footer = makeButtons()
        footer.translatesAutoresizingMaskIntoConstraints = false
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)
        view.addSubview(footer)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    private func makeReasonCard(_ reason: String) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "exclamationmark.circle.fill"))
        icon.tintColor = .systemOrange
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        let label = UILabel()
        label.text = reason
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0

        let row = UIStackView(arrangedSubviews: [icon, label])
        row.spacing = 12
        row.alignment = .firstBaseline
        let card = wrapInCard(row, color: UIColor.systemOrange.withAlphaComponent(0.12))
        card.isAccessibilityElement = true
        card.accessibilityLabel = reason
        card.accessibilityIdentifier = "importHelp.reason"
        return card
    }

    private func makeLead() -> UIView {
        let label = UILabel()
        label.text = String(localized: "Flaccy plays music files you own: FLAC, ALAC, MP3, AAC, WAV and AIFF. Where is yours?")
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        let holder = UIView()
        label.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: holder.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -4),
        ])
        return holder
    }

    /// A place music lives, as a card. One the app can take the person straight into is a button with a chevron; one
    /// that only needs explaining is plain text.
    private func makePlaceCard(_ place: Place) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: place.symbol))
        icon.tintColor = .tintColor
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true

        let title = UILabel()
        title.text = place.title
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0

        let detail = UILabel()
        detail.text = place.detail
        detail.font = .preferredFont(forTextStyle: .subheadline)
        detail.textColor = .secondaryLabel
        detail.adjustsFontForContentSizeCategory = true
        detail.numberOfLines = 0

        let text = UIStackView(arrangedSubviews: [title, detail])
        text.axis = .vertical
        text.spacing = 3

        let row = UIStackView(arrangedSubviews: [icon, text])
        row.spacing = 14
        row.alignment = .center
        if place.action != nil {
            let chevron = UIImageView(image: UIImage(systemName: "chevron.forward"))
            chevron.tintColor = .tertiaryLabel
            chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)
            chevron.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(chevron)
        }
        row.isUserInteractionEnabled = false

        guard let action = place.action else {
            let card = wrapInCard(row, color: .secondarySystemGroupedBackground)
            card.isAccessibilityElement = true
            card.accessibilityLabel = "\(place.title). \(place.detail)"
            card.accessibilityIdentifier = place.identifier
            return card
        }
        let button = UIButton(configuration: .plain(), primaryAction: UIAction { [weak self] _ in
            self?.choose(action)
        })
        button.configurationUpdateHandler = { button in
            var background = UIBackgroundConfiguration.clear()
            background.backgroundColor = button.isHighlighted ? .tertiarySystemGroupedBackground : .secondarySystemGroupedBackground
            background.cornerRadius = 16
            button.configuration?.background = background
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: button.topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -14),
            row.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -16),
        ])
        button.accessibilityLabel = place.title
        button.accessibilityHint = place.detail
        button.accessibilityIdentifier = place.identifier
        button.isPointerInteractionEnabled = true
        return button
    }

    /// Pinned under the scrolling places, so the way back into Files is in reach at half height too.
    private func makeButtons() -> UIView {
        var again = UIButton.Configuration.filled()
        again.title = String(localized: "Choose Files Again")
        again.image = UIImage(systemName: "folder")
        again.imagePadding = 8
        again.cornerStyle = .capsule
        again.buttonSize = .large
        let chooseFiles = UIButton(configuration: again, primaryAction: UIAction { [weak self] _ in
            self?.choose(.chooseFiles)
        })
        chooseFiles.accessibilityIdentifier = "importHelp.chooseFiles"

        let stack = UIStackView(arrangedSubviews: [chooseFiles])
        stack.axis = .vertical
        stack.spacing = 6
        if offersSample {
            var sample = UIButton.Configuration.plain()
            sample.title = WelcomeCopy.sample
            sample.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = .preferredFont(forTextStyle: .subheadline)
                return attributes
            }
            let button = UIButton(configuration: sample, primaryAction: UIAction { [weak self] _ in
                self?.choose(.sample)
            })
            button.accessibilityIdentifier = "importHelp.sample"
            stack.addArrangedSubview(button)
        }
        return stack
    }

    private func wrapInCard(_ content: UIView, color: UIColor) -> UIView {
        let card = UIView()
        card.backgroundColor = color
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
        ])
        return card
    }

    /// Closes the help first, so whatever the action opens is presented from the Library rather than stacked on a
    /// sheet that is on its way out.
    private func choose(_ action: Action) {
        impact.impactOccurred()
        MidgarLog.info("Import help chose \(action)", category: .ui)
        let handler = onAction
        dismiss(animated: true) { handler?(action) }
    }
}
