import AppKit
import FlaccyCore

/// The Meaning popover on the Mac: the asked line, what it or the whole song
/// means, and what Wikipedia says about the song.
final class MacLyricsMeaningViewController: NSViewController {

    private static let contentWidth: CGFloat = 420
    private static let maximumHeight: CGFloat = 560
    private static let padding: CGFloat = 18
    private static var textWidth: CGFloat { contentWidth - 2 * padding }

    private let load: LyricsMeaningLoad
    private let stack = NSStackView()
    private let scrollView = NSScrollView()
    private let statusRow = NSStackView()
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let noteLabel = NSTextField(wrappingLabelWithString: LyricsMeaningCopy.writtenByAI)
    private let failureLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let wikipediaStack = NSStackView()
    private let wikipediaFailureLabel = NSTextField(wrappingLabelWithString: "")
    private var heightConstraint: NSLayoutConstraint?
    private var shownStory: SongStory?
    private var action: (() -> Void)?
    private var storyURL: URL?

    init(load: LyricsMeaningLoad) {
        self.load = load
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    /// Shows the popover for line `line` of the document, or for the whole
    /// song with `nil`, beside `anchor`. Returns it so the panel can close it.
    static func show(
        song: MeaningSong, document: LyricsDocument, line: Int?, relativeTo anchor: NSView, edge: NSRectEdge
    ) -> NSPopover? {
        guard let load = LyricsMeaningLoad(song: song, document: document, line: line) else { return nil }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = MacLyricsMeaningViewController(load: load)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: edge)
        return popover
    }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: Self.padding, left: Self.padding, bottom: Self.padding, right: Self.padding)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(scrollView)
        let height = root.heightAnchor.constraint(equalToConstant: 200)
        heightConstraint = height
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            height,
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
        view = root
        buildContent()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        load.onChange = { [weak self] in self?.render() }
        load.start()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        load.cancel()
    }

    private func buildContent() {
        stack.addArrangedSubview(text(
            "\(load.song.title) — \(load.song.artist)", size: 11.5, weight: .regular, color: .secondaryLabelColor))
        if let focus = load.focus {
            stack.addArrangedSubview(quote(focus.line))
        }
        stack.addArrangedSubview(text(
            load.focus == nil ? LyricsMeaningCopy.songHeader : LyricsMeaningCopy.lineHeader,
            size: 15, weight: .semibold, color: .labelColor))

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        statusLabel.font = .systemFont(ofSize: 12.5)
        statusLabel.textColor = .secondaryLabelColor
        statusRow.orientation = .horizontal
        statusRow.spacing = 8
        statusRow.addArrangedSubview(spinner)
        statusRow.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(statusRow)

        style(bodyLabel, size: 13.5, weight: .regular, color: .labelColor)
        stack.addArrangedSubview(bodyLabel)
        style(noteLabel, size: 11, weight: .regular, color: .tertiaryLabelColor)
        stack.addArrangedSubview(noteLabel)
        style(failureLabel, size: 12.5, weight: .regular, color: .secondaryLabelColor)
        stack.addArrangedSubview(failureLabel)
        actionButton.bezelStyle = .push
        actionButton.target = self
        actionButton.action = #selector(runAction)
        stack.addArrangedSubview(actionButton)

        wikipediaStack.orientation = .vertical
        wikipediaStack.alignment = .leading
        wikipediaStack.spacing = 8
        stack.addArrangedSubview(wikipediaStack)
        stack.setCustomSpacing(22, after: actionButton)
        stack.setCustomSpacing(22, after: noteLabel)
        style(wikipediaFailureLabel, size: 11.5, weight: .regular, color: .secondaryLabelColor)
        stack.addArrangedSubview(wikipediaFailureLabel)
    }

    private func render() {
        renderReading()
        renderStory()
        fitHeight()
    }

    private func renderReading() {
        for hidden in [bodyLabel, noteLabel, failureLabel] as [NSView] { hidden.isHidden = true }
        actionButton.isHidden = true
        statusRow.isHidden = true
        switch load.reading {
        case .lookingUp, .reading:
            statusLabel.stringValue = load.reading == .lookingUp ? LyricsMeaningCopy.lookingUp : LyricsMeaningCopy.reading
            statusRow.isHidden = false
        case .answered(let answer):
            bodyLabel.attributedStringValue = Self.paragraphs(answer, size: 13.5)
            bodyLabel.isHidden = false
            noteLabel.isHidden = false
        case .failed(let failure):
            failureLabel.stringValue = LyricsMeaningCopy.failure(failure)
            failureLabel.isHidden = false
            showAction(for: failure)
        }
    }

    private func showAction(for failure: MeaningFailure) {
        switch failure {
        case .needsEntitlement:
            actionButton.title = LyricsMeaningCopy.seePlans
            action = { (NSApp.delegate as? MacAppDelegate)?.presentPaywall() }
        case .quotaReached:
            action = nil
        case .unreachable, .unavailable, .unreadable:
            actionButton.title = LyricsMeaningCopy.tryAgain
            action = { [weak self] in self?.load.start() }
        }
        actionButton.isHidden = action == nil
    }

    @objc private func runAction() {
        action?()
    }

    #if DEBUG
    /// What the popover is showing, for the debug drive's log.
    var captureState: String {
        let story = switch load.story {
        case .loading: "loading"
        case .found(let story): "found(\(story.article), \(story.sections.count) sections)"
        case .missing: "missing"
        case .failed(let failure): "failed(\(failure))"
        }
        let reading = switch load.reading {
        case .lookingUp: "lookingUp"
        case .reading: "reading"
        case .answered(let text): "answered(\(text.count) characters)"
        case .failed(let failure): "failed(\(failure))"
        }
        return "story=\(story) reading=\(reading)"
    }
    #endif

    private func renderStory() {
        wikipediaFailureLabel.isHidden = true
        switch load.story {
        case .found(let story):
            if story != shownStory {
                shownStory = story
                fill(story)
            }
            wikipediaStack.isHidden = false
        case .loading, .missing:
            wikipediaStack.isHidden = true
        case .failed(let failure):
            wikipediaStack.isHidden = true
            wikipediaFailureLabel.stringValue = LyricsMeaningCopy.wikipediaFailure(failure)
            wikipediaFailureLabel.isHidden = false
        }
    }

    private func fill(_ story: SongStory) {
        wikipediaStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        wikipediaStack.addArrangedSubview(text(LyricsMeaningCopy.wikipediaHeader, size: 15, weight: .semibold, color: .labelColor))
        if !story.lead.isEmpty {
            wikipediaStack.addArrangedSubview(paragraphLabel(story.lead))
        }
        for section in story.sections {
            let heading = text(section.heading, size: 13, weight: .semibold, color: .labelColor)
            wikipediaStack.addArrangedSubview(heading)
            wikipediaStack.setCustomSpacing(3, after: heading)
            wikipediaStack.addArrangedSubview(paragraphLabel(section.body))
        }
        wikipediaStack.addArrangedSubview(text(
            LyricsMeaningCopy.wikipediaCredit(story.article), size: 11, weight: .regular, color: .secondaryLabelColor))
        storyURL = URL(string: story.url)
        if storyURL != nil {
            let link = NSButton(title: LyricsMeaningCopy.readOnWikipedia, target: self, action: #selector(openStory))
            link.bezelStyle = .inline
            link.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil)
            link.imagePosition = .imageTrailing
            wikipediaStack.addArrangedSubview(link)
        }
    }

    @objc private func openStory() {
        guard let storyURL else { return }
        NSWorkspace.shared.open(storyURL)
    }

    /// Grows the popover with its content up to `maximumHeight`, past which
    /// it scrolls.
    private func fitHeight() {
        view.layoutSubtreeIfNeeded()
        let wanted = stack.fittingSize.height
        heightConstraint?.constant = min(max(wanted, 120), Self.maximumHeight)
    }

    /// The asked line, set off by a bar in the accent colour.
    private func quote(_ line: String) -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        bar.layer?.cornerRadius = 1.5
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 3).isActive = true
        let label = text(line, size: 15, weight: .semibold, color: .labelColor)
        label.preferredMaxLayoutWidth = Self.textWidth - 15
        let row = NSStackView(views: [bar, label])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        bar.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true
        return row
    }

    private func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: string)
        style(label, size: size, weight: weight, color: color)
        return label
    }

    private func paragraphLabel(_ string: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        style(label, size: 13, weight: .regular, color: .labelColor)
        label.attributedStringValue = Self.paragraphs(string, size: 13)
        return label
    }

    private func style(_ label: NSTextField, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.isSelectable = true
        label.allowsEditingTextAttributes = true
        label.preferredMaxLayoutWidth = Self.textWidth
    }

    /// Text whose paragraphs are separated by blank lines, drawn with the
    /// blank line as paragraph spacing instead of an empty line.
    private static func paragraphs(_ string: String, size: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = 9
        return NSAttributedString(
            string: string.replacingOccurrences(of: "\n\n", with: "\n"),
            attributes: [
                .font: NSFont.systemFont(ofSize: size),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style,
            ]
        )
    }
}
