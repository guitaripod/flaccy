import FlaccyCore
import UIKit

/// The Meaning sheet on iPhone: the asked line, what it or the whole song
/// means, and what Wikipedia says about the song.
final class LyricsMeaningViewController: UIViewController {

    private static let padding: CGFloat = 20

    private let load: LyricsMeaningLoad
    private let feedback = UIImpactFeedbackGenerator(style: .light)
    private let stack = UIStackView()
    private let statusRow = UIStackView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()
    private let bodyLabel = UILabel()
    private let noteLabel = UILabel()
    private let failureLabel = UILabel()
    private lazy var actionButton = makeActionButton()
    private let wikipediaStack = UIStackView()
    private let wikipediaFailureLabel = UILabel()
    private var shownStory: SongStory?
    private var action: (() -> Void)?

    init(load: LyricsMeaningLoad) {
        self.load = load
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    /// Presents the sheet for line `line` of the document, or for the whole
    /// song with `nil`. Does nothing for an instrumental break.
    static func present(song: MeaningSong, document: LyricsDocument, line: Int?, from presenter: UIViewController) {
        guard let load = LyricsMeaningLoad(song: song, document: document, line: line) else { return }
        let meaning = LyricsMeaningViewController(load: load)
        let navigation = UINavigationController(rootViewController: meaning)
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }
        presenter.present(navigation, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = LyricsMeaningCopy.title
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in
                self?.feedback.impactOccurred()
                self?.dismiss(animated: true)
            }
        )
        buildContent()
        load.onChange = { [weak self] in self?.render() }
        load.start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            load.cancel()
        }
    }

    private func buildContent() {
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -32),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Self.padding),
        ])

        let song = label(
            "\(load.song.title) — \(load.song.artist)", style: .subheadline, color: .secondaryLabel)
        stack.addArrangedSubview(song)
        if let focus = load.focus {
            stack.addArrangedSubview(quote(focus.line))
        }
        let header = label(
            load.focus == nil ? LyricsMeaningCopy.songHeader : LyricsMeaningCopy.lineHeader,
            style: .title3, color: .label, weight: .semibold)
        header.accessibilityTraits = .header
        stack.addArrangedSubview(header)

        spinner.startAnimating()
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusRow.axis = .horizontal
        statusRow.spacing = 10
        statusRow.alignment = .center
        statusRow.addArrangedSubview(spinner)
        statusRow.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(statusRow)

        configure(bodyLabel, style: .body, color: .label)
        stack.addArrangedSubview(bodyLabel)
        configure(noteLabel, style: .footnote, color: .tertiaryLabel)
        noteLabel.text = LyricsMeaningCopy.writtenByAI
        stack.addArrangedSubview(noteLabel)
        configure(failureLabel, style: .callout, color: .secondaryLabel)
        stack.addArrangedSubview(failureLabel)
        let actionRow = UIStackView(arrangedSubviews: [actionButton, UIView()])
        actionRow.axis = .horizontal
        stack.addArrangedSubview(actionRow)

        wikipediaStack.axis = .vertical
        wikipediaStack.spacing = 10
        stack.addArrangedSubview(wikipediaStack)
        stack.setCustomSpacing(28, after: actionRow)
        configure(wikipediaFailureLabel, style: .footnote, color: .secondaryLabel)
        stack.addArrangedSubview(wikipediaFailureLabel)
    }

    private func render() {
        renderReading()
        renderStory()
    }

    private func renderReading() {
        bodyLabel.isHidden = true
        noteLabel.isHidden = true
        failureLabel.isHidden = true
        actionButton.superview?.isHidden = true
        statusRow.isHidden = true
        switch load.reading {
        case .lookingUp, .reading:
            statusLabel.text = load.reading == .lookingUp ? LyricsMeaningCopy.lookingUp : LyricsMeaningCopy.reading
            statusRow.isHidden = false
        case .answered(let text):
            bodyLabel.attributedText = Self.paragraphs(text)
            bodyLabel.isHidden = false
            noteLabel.isHidden = false
            UIAccessibility.post(notification: .layoutChanged, argument: bodyLabel)
        case .failed(let failure):
            failureLabel.text = LyricsMeaningCopy.failure(failure)
            failureLabel.isHidden = false
            showAction(for: failure)
        }
    }

    private func showAction(for failure: MeaningFailure) {
        switch failure {
        case .needsEntitlement:
            actionButton.configuration?.title = LyricsMeaningCopy.seePlans
            action = { [weak self] in
                guard let self else { return }
                PaywallViewController.presentSheet(from: self)
            }
        case .quotaReached:
            action = nil
        case .unreachable, .unavailable, .unreadable:
            actionButton.configuration?.title = LyricsMeaningCopy.tryAgain
            action = { [weak self] in self?.load.start() }
        }
        actionButton.superview?.isHidden = action == nil
    }

    private func renderStory() {
        wikipediaFailureLabel.isHidden = true
        switch load.story {
        case .found(let story):
            guard story != shownStory else { return }
            shownStory = story
            fill(story)
            wikipediaStack.isHidden = false
        case .loading, .missing:
            wikipediaStack.isHidden = true
        case .failed(let failure):
            wikipediaStack.isHidden = true
            wikipediaFailureLabel.text = LyricsMeaningCopy.wikipediaFailure(failure)
            wikipediaFailureLabel.isHidden = false
        }
    }

    private func fill(_ story: SongStory) {
        wikipediaStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let header = label(LyricsMeaningCopy.wikipediaHeader, style: .title3, color: .label, weight: .semibold)
        header.accessibilityTraits = .header
        wikipediaStack.addArrangedSubview(header)
        if !story.lead.isEmpty {
            let lead = UILabel()
            configure(lead, style: .body, color: .label)
            lead.attributedText = Self.paragraphs(story.lead)
            wikipediaStack.addArrangedSubview(lead)
        }
        for section in story.sections {
            let heading = label(section.heading, style: .headline, color: .label)
            heading.accessibilityTraits = .header
            wikipediaStack.addArrangedSubview(heading)
            wikipediaStack.setCustomSpacing(4, after: heading)
            let body = UILabel()
            configure(body, style: .body, color: .label)
            body.attributedText = Self.paragraphs(section.body)
            wikipediaStack.addArrangedSubview(body)
        }
        wikipediaStack.addArrangedSubview(label(
            LyricsMeaningCopy.wikipediaCredit(story.article), style: .footnote, color: .secondaryLabel))
        if let url = URL(string: story.url) {
            var config = UIButton.Configuration.plain()
            config.title = LyricsMeaningCopy.readOnWikipedia
            config.image = UIImage(systemName: "arrow.up.right.square")
            config.imagePlacement = .trailing
            config.imagePadding = 6
            config.contentInsets = .zero
            let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                self?.feedback.impactOccurred()
                UIApplication.shared.open(url)
            })
            button.contentHorizontalAlignment = .leading
            wikipediaStack.addArrangedSubview(button)
        }
    }

    #if DEBUG
    /// Opens the sheet all the way and scrolls to its end, for a screenshot of
    /// the Wikipedia section.
    func revealEndForScreenshot() {
        navigationController?.sheetPresentationController?.animateChanges {
            navigationController?.sheetPresentationController?.selectedDetentIdentifier = .large
        }
        guard let scroll = stack.superview as? UIScrollView else { return }
        view.layoutIfNeeded()
        let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        scroll.setContentOffset(CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top, bottom)), animated: false)
    }
    #endif

    private func makeActionButton() -> UIButton {
        var config = UIButton.Configuration.bordered()
        config.cornerStyle = .capsule
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            self?.feedback.impactOccurred()
            self?.action?()
        })
        return button
    }

    /// The asked line, set off by a bar in the accent colour.
    private func quote(_ text: String) -> UIView {
        let bar = UIView()
        bar.backgroundColor = view.tintColor
        bar.layer.cornerRadius = 1.5
        bar.widthAnchor.constraint(equalToConstant: 3).isActive = true
        let line = label(text, style: .title3, color: .label, weight: .semibold)
        let row = UIStackView(arrangedSubviews: [bar, line])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .fill
        return row
    }

    private func label(
        _ text: String, style: UIFont.TextStyle, color: UIColor, weight: UIFont.Weight? = nil
    ) -> UILabel {
        let label = UILabel()
        configure(label, style: style, color: color, weight: weight)
        label.text = text
        return label
    }

    private func configure(_ label: UILabel, style: UIFont.TextStyle, color: UIColor, weight: UIFont.Weight? = nil) {
        if let weight {
            let base = UIFont.preferredFont(forTextStyle: style)
            label.font = UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: base.pointSize, weight: weight))
        } else {
            label.font = .preferredFont(forTextStyle: style)
        }
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
    }

    /// Text whose paragraphs are separated by blank lines, drawn with the
    /// blank line as paragraph spacing instead of an empty line.
    private static func paragraphs(_ text: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 12
        return NSAttributedString(
            string: text.replacingOccurrences(of: "\n\n", with: "\n"),
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.label,
                .paragraphStyle: style,
            ]
        )
    }
}
