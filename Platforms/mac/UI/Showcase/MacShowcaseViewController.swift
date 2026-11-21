import AppKit
import MidgarCore

/// Opens the 2.0 showcase as a sheet over the main window on the launch that should have it.
@MainActor
enum MacShowcase {

    private static var hasPresented = false

    static func presentIfNeeded(over windowController: NSWindowController?) {
        let forced = ShowcaseGate.isForced()
        guard !hasPresented, ShowcaseGate.shouldPresent(
            seenEdition: ShowcaseGate.seenEdition, isAutomated: ShowcaseGate.isAutomatedRun(), forced: forced
        ) else { return }
        hasPresented = true
        if !forced { ShowcaseGate.markSeen() }
        Task { @MainActor in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let window = windowController?.window, let host = window.contentViewController else { return }
                guard window.isVisible, window.sheets.isEmpty else { continue }
                let showcase = MacShowcaseViewController()
                host.presentAsSheet(showcase)
                if forced && ShowcaseGate.opensOnEverything() { showcase.showEverything(animated: false) }
                #if DEBUG
                captureIfRequested(window: window)
                #endif
                return
            }
        }
    }

    #if DEBUG
    /// With `--shot-showcase`, saves a picture of the sheet once its entrance has played and quits, for a look at
    /// it without a hand on the Mac.
    private static func captureIfRequested(window: NSWindow) {
        guard CommandLine.arguments.contains("--shot-showcase") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            DebugDrive.captureSheet(of: window, name: "flaccy-shot-showcase")
            exit(0)
        }
    }
    #endif
}

/// The 2.0 showcase on the Mac: a first page with the hero and four things Flaccy does, and a second that lists
/// everything and scrolls. Continue comes up once the entrance has played, about a second in.
final class MacShowcaseViewController: NSViewController {

    private static let size = NSSize(width: 480, height: 664)

    private let hero = MacShowcaseHeroView()
    private let rows = ShowcaseCopy.highlights.map { MacShowcaseRowView(feature: $0) }
    private let firstPage = NSView()
    private let everythingPage = NSView()
    private lazy var everythingButton = MacShowcaseButtons.onward(
        title: ShowcaseCopy.seeEverything, target: self, action: #selector(everythingTapped)
    )
    private lazy var continueButton = MacShowcaseButtons.primary(target: self, action: #selector(primaryTapped))
    private lazy var everythingContinueButton = MacShowcaseButtons.primary(target: self, action: #selector(primaryTapped))
    private lazy var secondaryButton = MacShowcaseButtons.quiet(target: self, action: #selector(secondaryTapped))
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var footer = ShowcaseFooter.make(for: nil)
    private var hasPlayedEntrance = false

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: Self.size))
        preferredContentSize = Self.size
        buildFirstPage()
        buildEverythingPage()
        everythingPage.isHidden = true
        for page in [firstPage, everythingPage] {
            page.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(page)
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: view.topAnchor),
                page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
        apply(ShowcaseFooter.current)
        prepareForEntrance()
        NotificationCenter.default.addObserver(
            self, selector: #selector(entitlementsDidLoad), name: PurchaseManager.entitlementsDidLoad, object: nil
        )
        MidgarLog.info("Showcase \(ShowcaseCopy.version) shown", category: .ui)
    }

    /// The store answered after the showcase opened, so the foot can now say where the person stands.
    @objc private func entitlementsDidLoad() {
        apply(ShowcaseFooter.current)
    }

    /// Shows a foot: the status line, the main button's title, and the second button when there is one.
    private func apply(_ footer: ShowcaseFooter) {
        self.footer = footer
        statusLabel.stringValue = footer.status ?? ""
        statusLabel.isHidden = footer.status == nil
        continueButton.title = footer.primaryTitle
        everythingContinueButton.title = footer.primaryTitle
        MacShowcaseButtons.retitle(secondaryButton, footer.secondaryTitle ?? "")
        secondaryButton.isHidden = footer.secondaryTitle == nil
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !hasPlayedEntrance else { return }
        hasPlayedEntrance = true
        playEntrance()
    }

    /// Opens the second page, where everything Flaccy can do is listed.
    func showEverything(animated: Bool) {
        swap(from: firstPage, to: everythingPage, animated: animated)
        view.window?.makeFirstResponder(everythingContinueButton)
    }

    @objc private func everythingTapped() {
        showEverything(animated: true)
    }

    @objc private func backTapped() {
        swap(from: everythingPage, to: firstPage, animated: true)
    }

    @objc private func primaryTapped() {
        finish(with: footer.primary)
    }

    @objc private func secondaryTapped() {
        finish(with: footer.secondary ?? .listen)
    }

    /// Closes the showcase, and opens the plans when that is what the person chose.
    private func finish(with action: ShowcaseFooter.Action) {
        MidgarLog.info("Showcase \(ShowcaseCopy.version) closed for \(action)", category: .ui)
        dismiss(nil)
        guard action == .plans else { return }
        DispatchQueue.main.async {
            (NSApp.delegate as? MacAppDelegate)?.presentPaywall()
        }
    }

    private func swap(from old: NSView, to new: NSView, animated: Bool) {
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            old.isHidden = true
            new.alphaValue = 1
            new.isHidden = false
            return
        }
        new.alphaValue = 0
        new.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            old.animator().alphaValue = 0
            new.animator().alphaValue = 1
        } completionHandler: {
            MainActor.assumeIsolated {
                old.isHidden = true
                old.alphaValue = 1
            }
        }
    }

    private func buildFirstPage() {
        let rowStack = NSStackView(views: rows)
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 12

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        let buttons = NSStackView(views: [statusLabel, everythingButton, continueButton, secondaryButton])
        buttons.orientation = .vertical
        buttons.alignment = .centerX
        buttons.spacing = 10

        let content = NSStackView(views: [hero, rowStack])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 20

        for subview in [content, buttons] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            firstPage.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: firstPage.topAnchor, constant: 24),
            content.leadingAnchor.constraint(equalTo: firstPage.leadingAnchor, constant: 44),
            content.trailingAnchor.constraint(equalTo: firstPage.trailingAnchor, constant: -44),
            rowStack.widthAnchor.constraint(equalTo: content.widthAnchor),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: content.bottomAnchor, constant: 16),
            buttons.centerXAnchor.constraint(equalTo: firstPage.centerXAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            buttons.bottomAnchor.constraint(equalTo: firstPage.bottomAnchor, constant: -20),
            continueButton.widthAnchor.constraint(equalToConstant: 220),
        ])
    }

    private func buildEverythingPage() {
        let back = MacShowcaseButtons.back(target: self, action: #selector(backTapped))
        let heading = NSTextField(labelWithString: ShowcaseCopy.everythingTitle)
        heading.font = .systemFont(ofSize: 22, weight: .bold)

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 10
        for section in ShowcaseCopy.sections(bringsMusicOverWiFi: false) {
            let title = NSTextField(labelWithString: section.title)
            title.font = .systemFont(ofSize: 15, weight: .semibold)
            let card = MacShowcaseCardView(features: section.features)
            list.addArrangedSubview(title)
            list.addArrangedSubview(card)
            list.setCustomSpacing(22, after: card)
            card.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        list.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 12, right: 0)

        let document = MacShowcaseFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        list.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = document

        for subview in [back, heading, scroll, everythingContinueButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            everythingPage.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            back.topAnchor.constraint(equalTo: everythingPage.topAnchor, constant: 18),
            back.leadingAnchor.constraint(equalTo: everythingPage.leadingAnchor, constant: 22),
            heading.topAnchor.constraint(equalTo: back.bottomAnchor, constant: 10),
            heading.leadingAnchor.constraint(equalTo: everythingPage.leadingAnchor, constant: 32),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: everythingPage.trailingAnchor, constant: -32),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: everythingPage.leadingAnchor, constant: 32),
            scroll.trailingAnchor.constraint(equalTo: everythingPage.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: everythingContinueButton.topAnchor, constant: -16),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            everythingContinueButton.centerXAnchor.constraint(equalTo: everythingPage.centerXAnchor),
            everythingContinueButton.widthAnchor.constraint(equalToConstant: 220),
            everythingContinueButton.bottomAnchor.constraint(equalTo: everythingPage.bottomAnchor, constant: -24),
        ])
    }

    private func prepareForEntrance() {
        hero.prepareForEntrance()
        (rows + [statusLabel, everythingButton, continueButton, secondaryButton]).forEach { $0.alphaValue = 0 }
        [everythingButton, continueButton, secondaryButton].forEach { $0.isEnabled = false }
    }

    private func playEntrance() {
        let gentle = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        hero.playEntrance(gentle: gentle)
        for (index, row) in rows.enumerated() {
            MacShowcaseHeroView.fadeIn(row, after: gentle ? 0 : ShowcaseTiming.row(index))
        }
        let buttonsAt = gentle ? 0 : ShowcaseTiming.buttons(rowCount: rows.count)
        [statusLabel, everythingButton, continueButton, secondaryButton].forEach {
            MacShowcaseHeroView.fadeIn($0, after: buttonsAt)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (gentle ? 0 : ShowcaseTiming.versionLands)) {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + buttonsAt) { [weak self] in
            guard let self else { return }
            [self.everythingButton, self.continueButton, self.secondaryButton].forEach { $0.isEnabled = true }
            self.view.window?.makeFirstResponder(self.continueButton)
        }
    }
}

/// The top of the Mac showcase: the app's icon, its name, the version in large numerals filled with the accent, and
/// one line under them.
final class MacShowcaseHeroView: NSView {

    private let icon = NSImageView(image: NSApp.applicationIconImage)
    private let nameLabel = NSTextField(labelWithString: ShowcaseCopy.name)
    private let versionView = MacShowcaseVersionView(text: ShowcaseCopy.version)
    private let taglineLabel = NSTextField(labelWithString: ShowcaseCopy.tagline)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        nameLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        taglineLabel.font = .systemFont(ofSize: 13)
        taglineLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [icon, nameLabel, versionView, taglineLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 2
        stack.setCustomSpacing(8, after: icon)
        stack.setCustomSpacing(-4, after: nameLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(ShowcaseCopy.name) \(ShowcaseCopy.version). \(ShowcaseCopy.tagline)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func prepareForEntrance() {
        [icon, nameLabel, versionView, taglineLabel].forEach { $0.alphaValue = 0 }
    }

    /// Brings the parts in on the showcase's clock. With `gentle` they arrive together.
    func playEntrance(gentle: Bool) {
        Self.fadeIn(icon, after: gentle ? 0 : ShowcaseTiming.icon)
        Self.fadeIn(nameLabel, after: gentle ? 0 : ShowcaseTiming.name)
        Self.fadeIn(versionView, after: gentle ? 0 : ShowcaseTiming.version)
        Self.fadeIn(taglineLabel, after: gentle ? 0 : ShowcaseTiming.tagline)
        if !gentle { versionView.shine(after: ShowcaseTiming.versionLands) }
    }

    static func fadeIn(_ view: NSView, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = ShowcaseTiming.settle
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                view.animator().alphaValue = 1
            }
        }
    }
}

/// The version in large rounded numerals, filled with a gradient of the accent, with one pass of light across it.
final class MacShowcaseVersionView: NSView {

    private let gradient = CAGradientLayer()
    private let light = CAGradientLayer()
    private let numerals = CATextLayer()
    private let font: NSFont
    private let text: String

    init(text: String) {
        self.text = text
        let base = NSFont.systemFont(ofSize: 76, weight: .heavy)
        font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 76) } ?? base
        super.init(frame: .zero)
        wantsLayer = true
        numerals.string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        numerals.alignmentMode = .center
        gradient.startPoint = CGPoint(x: 0, y: 0.8)
        gradient.endPoint = CGPoint(x: 1, y: 0.2)
        light.startPoint = CGPoint(x: 0, y: 0.5)
        light.endPoint = CGPoint(x: 1, y: 0.5)
        light.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.75).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        light.opacity = 0
        gradient.addSublayer(light)
        gradient.mask = numerals
        layer?.addSublayer(gradient)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        let size = (text as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(size.width) + 8, height: ceil(size.height))
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        numerals.frame = bounds
        numerals.contentsScale = window?.backingScaleFactor ?? 2
        light.frame = CGRect(x: -bounds.width, y: 0, width: bounds.width * 0.6, height: bounds.height)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = NSColor.controlAccentColor.usingColorSpace(.deviceRGB) ?? .systemBlue
            gradient.colors = [accent.cgColor, Self.neighbour(of: accent).cgColor]
        }
    }

    private static func neighbour(of color: NSColor) -> NSColor {
        guard color.saturationComponent > 0.08 else {
            return NSColor(
                hue: color.hueComponent, saturation: color.saturationComponent,
                brightness: min(color.brightnessComponent + 0.25, 1), alpha: color.alphaComponent
            )
        }
        return NSColor(
            hue: (color.hueComponent + 0.11).truncatingRemainder(dividingBy: 1),
            saturation: max(color.saturationComponent * 0.85, 0.35),
            brightness: min(color.brightnessComponent * 1.12, 1),
            alpha: color.alphaComponent
        )
    }

    /// Sends one band of light across the numerals, left to right, and leaves nothing behind.
    func shine(after delay: TimeInterval) {
        layoutSubtreeIfNeeded()
        let travel = CABasicAnimation(keyPath: "position.x")
        travel.fromValue = -bounds.width * 0.3
        travel.toValue = bounds.width * 1.3
        let show = CAKeyframeAnimation(keyPath: "opacity")
        show.values = [0, 1, 1, 0]
        show.keyTimes = [0, 0.15, 0.85, 1]
        let pass = CAAnimationGroup()
        pass.animations = [travel, show]
        pass.duration = 0.65
        pass.beginTime = CACurrentMediaTime() + delay
        pass.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        light.add(pass, forKey: "shine")
    }
}

/// One feature as a row on the Mac: its symbol on a tinted tile, its name, and a line about it.
final class MacShowcaseRowView: NSView {

    init(feature: ShowcaseFeature) {
        super.init(frame: .zero)
        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: feature.symbol, accessibilityDescription: nil)
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        symbol.contentTintColor = .controlAccentColor
        symbol.translatesAutoresizingMaskIntoConstraints = false

        let tile = MacShowcaseTileView()
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(symbol)

        let title = NSTextField(labelWithString: feature.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: feature.detail)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        let words = NSStackView(views: [title, detail])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 2

        let row = NSStackView(views: [tile, words])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 34),
            tile.heightAnchor.constraint(equalToConstant: 34),
            symbol.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(feature.title). \(feature.detail)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// The rounded tile a row's symbol sits on, washed with the accent.
final class MacShowcaseTileView: NSView {

    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
    }
}

/// A group of features on a rounded card.
final class MacShowcaseCardView: NSView {

    override var wantsUpdateLayer: Bool { true }

    init(features: [ShowcaseFeature]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        let rows = NSStackView(views: features.map { MacShowcaseRowView(feature: $0) })
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 14
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
    }
}

/// A document view that lays out from the top, so the list starts at its beginning.
final class MacShowcaseFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The buttons of the Mac showcase.
@MainActor
enum MacShowcaseButtons {

    /// The large default button that finishes the showcase, answering Return.
    static func primary(target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: ShowcaseCopy.proceed, target: target, action: action)
        button.bezelStyle = .push
        button.controlSize = .large
        button.keyEquivalent = "\r"
        button.setAccessibilityIdentifier("showcase.continue")
        return button
    }

    /// The borderless accent-coloured button with a chevron that leads further in.
    static func onward(title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: nil)
        button.imagePosition = .imageTrailing
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        button.contentTintColor = .controlAccentColor
        button.attributedTitle = NSAttributedString(
            string: title, attributes: [.foregroundColor: NSColor.controlAccentColor, .font: NSFont.systemFont(ofSize: 13)]
        )
        button.setAccessibilityIdentifier("showcase.everything")
        return button
    }

    /// The small borderless button under the main one, for the other way on.
    static func quiet(target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: target, action: action)
        button.isBordered = false
        button.setAccessibilityIdentifier("showcase.secondary")
        return button
    }

    /// Gives a borderless button its title in the accent colour.
    static func retitle(_ button: NSButton, _ title: String) {
        button.attributedTitle = NSAttributedString(
            string: title, attributes: [.foregroundColor: NSColor.controlAccentColor, .font: NSFont.systemFont(ofSize: 13)]
        )
    }

    /// The borderless button that returns to the first page.
    static func back(target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: ShowcaseCopy.back, target: target, action: action)
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        button.contentTintColor = .controlAccentColor
        button.attributedTitle = NSAttributedString(
            string: ShowcaseCopy.back, attributes: [.foregroundColor: NSColor.controlAccentColor, .font: NSFont.systemFont(ofSize: 13)]
        )
        button.setAccessibilityIdentifier("showcase.back")
        return button
    }
}
