import AppKit

/// The audio-quality explainer rebuilt for desktop: the five fact cards from
/// the shared ListeningGuideContent in a scrollable glass layout, reordered so
/// the wired-DAC card leads — on a Mac the wired-lossless story is the pitch,
/// not the caveat. Source links open in the browser.
final class ListeningGuideViewController: NSViewController {

    private let backdrop = AmbientBackdropView()
    private let scrollView = NSScrollView()
    private let documentView = FlippedView()
    private let contentStack = NSStackView()

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.appearance = NSAppearance(named: .darkAqua)

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(backdrop)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 16
        buildContent()

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 28),
            contentStack.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
            contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 680),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: documentView.leadingAnchor, constant: 28),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -36),
        ])
        let preferredWidth = contentStack.widthAnchor.constraint(equalTo: documentView.widthAnchor, constant: -56)
        preferredWidth.priority = .defaultHigh
        preferredWidth.isActive = true

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        backdrop.apply(ArtworkPaletteExtractor.fallbackPalette(seed: "listening-guide"), animated: false)
    }

    deinit {
        AppLogger.info("ListeningGuideViewController deinit", category: .ui)
    }

    private func buildContent() {
        let caption = NSTextField(labelWithString: ListeningGuideContent.caption.uppercased())
        caption.font = .systemFont(ofSize: 11, weight: .bold)
        caption.textColor = NSColor.white.withAlphaComponent(0.55)

        let headline = NSTextField(labelWithString: ListeningGuideContent.headline)
        headline.font = .systemFont(ofSize: 28, weight: .heavy)
        headline.textColor = .white

        let intro = NSTextField(wrappingLabelWithString: ListeningGuideContent.intro)
        intro.font = .systemFont(ofSize: 13)
        intro.textColor = NSColor.white.withAlphaComponent(0.7)

        contentStack.addArrangedSubview(caption)
        contentStack.setCustomSpacing(2, after: caption)
        contentStack.addArrangedSubview(headline)
        contentStack.setCustomSpacing(6, after: headline)
        contentStack.addArrangedSubview(intro)
        intro.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        contentStack.setCustomSpacing(22, after: intro)

        for card in desktopOrderedCards() {
            let view = makeCard(card)
            contentStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
    }

    /// Desktop reorder: lead with "When FLAC is worth it" — the wired-DAC
    /// story is the reason this app exists on a Mac.
    private func desktopOrderedCards() -> [ListeningGuideCard] {
        let cards = ListeningGuideContent.cards
        guard let wiredIndex = cards.firstIndex(where: { $0.symbolName == "cable.connector" }) else {
            return cards
        }
        var reordered = cards
        let wired = reordered.remove(at: wiredIndex)
        reordered.insert(wired, at: 0)
        return reordered
    }

    private func makeCard(_ card: ListeningGuideCard) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)

        let icon = NSImageView(image: NSImage(
            systemSymbolName: card.symbolName, accessibilityDescription: nil
        ) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 16, weight: .semibold)
        icon.contentTintColor = NSColor(red: 0.45, green: 0.86, blue: 0.92, alpha: 1)

        let title = NSTextField(labelWithString: card.title)
        title.font = .systemFont(ofSize: 17, weight: .bold)
        title.textColor = .white

        let header = NSStackView(views: [icon, title])
        header.orientation = .horizontal
        header.spacing = 10
        header.alignment = .centerY
        stack.addArrangedSubview(header)

        let body = NSTextField(wrappingLabelWithString: card.body)
        body.font = .systemFont(ofSize: 13)
        body.textColor = NSColor.white.withAlphaComponent(0.8)
        stack.addArrangedSubview(body)
        body.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true

        if !card.bullets.isEmpty {
            if let bulletsCaption = card.bulletsCaption {
                stack.addArrangedSubview(captionLabel(bulletsCaption))
            }
            for bullet in card.bullets {
                let bulletLabel = NSTextField(wrappingLabelWithString: "•  \(bullet)")
                bulletLabel.font = .systemFont(ofSize: 12)
                bulletLabel.textColor = NSColor.white.withAlphaComponent(0.7)
                stack.addArrangedSubview(bulletLabel)
                bulletLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
            }
        }

        if let takeaway = card.takeaway {
            if let takeawayCaption = card.takeawayCaption {
                stack.addArrangedSubview(captionLabel(takeawayCaption))
            }
            let takeawayLabel = NSTextField(wrappingLabelWithString: takeaway)
            takeawayLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            takeawayLabel.textColor = NSColor(red: 0.45, green: 0.86, blue: 0.92, alpha: 1)
            stack.addArrangedSubview(takeawayLabel)
            takeawayLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
        }

        if let sourceLabel = card.sourceLabel, let sourceURL = card.sourceURL {
            let link = NSButton(title: sourceLabel, target: self, action: #selector(openSource(_:)))
            link.bezelStyle = .inline
            link.font = .systemFont(ofSize: 11, weight: .medium)
            link.contentTintColor = NSColor.white.withAlphaComponent(0.6)
            objc_setAssociatedObject(link, &Self.sourceURLKey, sourceURL, .OBJC_ASSOCIATION_RETAIN)
            stack.addArrangedSubview(link)
        }

        return RecapCard.host(stack, cornerRadius: 20)
    }

    private func captionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = NSColor.white.withAlphaComponent(0.5)
        return label
    }

    private static var sourceURLKey: UInt8 = 0

    @objc private func openSource(_ sender: NSButton) {
        guard let url = objc_getAssociatedObject(sender, &Self.sourceURLKey) as? URL else { return }
        NSWorkspace.shared.open(url)
        AppLogger.info("Listening guide source opened: \(url.absoluteString)", category: .ui)
    }
}
