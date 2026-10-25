import AppKit
import FlaccyCore

/// What a Home promo card asks the page to do. The page owns every effect, so
/// the card is only words and buttons.
enum MacHomePromoAction {
    case chooseFolder
    case importFiles
    case playSample
    case seePlans
    case getLifetime
    case restorePurchases
}

/// The card Home spends on getting music in and on Flaccy Pro, in the Mac's
/// surface style: a rounded panel with a hairline border, a column of words
/// and a row of buttons. It never opens a paywall by itself.
final class MacHomePromoCard: MacHomeSurfaceView {

    static let preferredWidth: CGFloat = 540

    var onAction: ((MacHomePromoAction) -> Void)?

    private let column = NSStackView()
    private var sampleButton: GlassCapsuleButton?
    private var sampleObserver: NSObjectProtocol?

    init() {
        super.init(cornerRadius: 22)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 24, left: 26, bottom: 24, right: 26)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        let width = widthAnchor.constraint(equalToConstant: Self.preferredWidth)
        width.priority = NSLayoutConstraint.Priority(750)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            width,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit {
        sampleObserver.map(NotificationCenter.default.removeObserver)
    }

    func configure(getStarted content: HomeGetStartedContent) {
        let title = titleLabel(content.title)
        addFull(title)
        addFull(label(content.body, size: 13, weight: .regular, color: .secondaryLabelColor))
        column.setCustomSpacing(18, after: column.arrangedSubviews.last ?? title)

        let add = MacHomeFilledButton(title: HomeCopy.addMusic, symbol: "plus")
        add.onClick = { [weak self, weak add] in
            guard let self, let add else { return }
            add.popUp(self.addMusicMenu())
        }
        let sample = GlassCapsuleButton(title: HomeSampleButton.current().title, symbolName: "play.circle")
        sample.onClick = { [weak self] in self?.onAction?(.playSample) }
        sampleButton = sample
        observeSample()
        refreshSample()
        column.addArrangedSubview(buttonRow([add, sample]))
        if let footnote = content.footnote {
            column.setCustomSpacing(14, after: column.arrangedSubviews.last ?? title)
            addFull(label(footnote, size: 11, weight: .regular, color: .tertiaryLabelColor))
        }
        setAccessibilityRole(.group)
        setAccessibilityLabel(content.title)
    }

    func configure(plan content: HomePlanCardContent) {
        addFull(label(content.kicker, size: 13, weight: .semibold, color: .secondaryLabelColor))
        let title = titleLabel(content.title)
        addFull(title)
        for line in content.proofLines {
            column.addArrangedSubview(proofRow(line))
        }
        column.setCustomSpacing(18, after: column.arrangedSubviews.last ?? title)

        let primary = MacHomeFilledButton(title: content.primaryTitle, symbol: nil)
        primary.onClick = { [weak self] in self?.onAction?(.getLifetime) }
        let plans = GlassCapsuleButton(title: HomeCopy.seePlans, symbolName: nil)
        plans.onClick = { [weak self] in self?.onAction?(.seePlans) }
        column.addArrangedSubview(buttonRow([primary, plans]))
        if let caption = content.caption {
            column.setCustomSpacing(12, after: column.arrangedSubviews.last ?? title)
            addFull(label(caption, size: 12, weight: .regular, color: .secondaryLabelColor))
        }
        if content.offersRestore {
            let restore = MacHomeLinkButton(title: HomeCopy.restorePurchases, size: 12, weight: .medium, color: .secondaryLabelColor)
            restore.onClick = { [weak self] in self?.onAction?(.restorePurchases) }
            column.setCustomSpacing(10, after: column.arrangedSubviews.last ?? title)
            column.addArrangedSubview(restore)
        }
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(content.kicker). \(content.title)")
    }

    private func addMusicMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: String(localized: "Choose Music Folder…"), systemImage: "folder") { [weak self] in
            self?.onAction?(.chooseFolder)
        })
        menu.addItem(ClosureMenuItem(title: String(localized: "Import Files…"), systemImage: "square.and.arrow.down") { [weak self] in
            self?.onAction?(.importFiles)
        })
        return menu
    }

    private func observeSample() {
        guard sampleObserver == nil else { return }
        sampleObserver = NotificationCenter.default.addObserver(
            forName: SampleMusicService.progressDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSample() }
        }
    }

    /// The sample button names the download while it runs and what to do when
    /// it stopped, the same words the iPhone's card uses.
    private func refreshSample() {
        guard let sampleButton else { return }
        let state = HomeSampleButton.current()
        sampleButton.title = state.title
        sampleButton.isEnabled = !state.isDownloading
        sampleButton.toolTip = state.subtitle
        sampleButton.setAccessibilityLabel(state.title)
    }

    private func addFull(_ view: NSView) {
        column.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -(column.edgeInsets.left + column.edgeInsets.right)).isActive = true
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.maximumNumberOfLines = 0
        field.isSelectable = false
        return field
    }

    private func titleLabel(_ text: String) -> NSTextField {
        let field = label(text, size: 28, weight: .heavy, color: .labelColor)
        field.setAccessibilityRole(.staticText)
        return field
    }

    private func proofRow(_ text: String) -> NSView {
        let icon = NSImageView(image: MacSymbolImage.configured("checkmark.circle.fill", pointSize: 13, weight: .semibold) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let line = label(text, size: 13, weight: .regular, color: .labelColor)
        line.maximumNumberOfLines = 2
        line.lineBreakMode = .byTruncatingTail
        let row = NSStackView(views: [icon, line])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    private func buttonRow(_ buttons: [NSView]) -> NSView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return MacLiquidGlass.grouping(row, spacing: 10)
    }
}

/// One quiet line under the hero, for a trial that waits on the first song.
final class MacHomePromoNote: NSView {

    init(text: String) {
        super.init(frame: .zero)
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        field.maximumNumberOfLines = 0
        field.isSelectable = false
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: topAnchor),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
