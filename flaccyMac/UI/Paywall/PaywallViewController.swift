import AppKit
import FlaccyCore
import RevenueCat
import StoreKit

/// The Flaccy Lifetime paywall, presented as a sheet on the main window: the
/// iOS paywall's visual language over an ambient palette backdrop, with the
/// Apple Watch bullet swapped for the desktop's menu-bar/folder-watch story.
/// The price and the call to action are pinned in a footer under the scroll
/// view so they are above the fold at every size the sheet can take.
final class PaywallViewController: NSViewController {

    private struct Feature {
        let symbolName: String
        let title: String
        let detail: String
    }

    private enum Metrics {
        static let width: CGFloat = 460
        static let height: CGFloat = 780
        static let inset: CGFloat = 30
    }

    private static let accent = NSColor(red: 0.45, green: 0.86, blue: 0.92, alpha: 1)

    private static let features: [Feature] = [
        Feature(
            symbolName: "infinity",
            title: String(localized: "Gapless lossless playback"),
            detail: String(localized: "FLAC albums flow track to track with zero silence.")
        ),
        Feature(
            symbolName: "dot.radiowaves.left.and.right",
            title: String(localized: "Last.fm scrobbling"),
            detail: String(localized: "Every listen counted, with an offline queue that never drops a play.")
        ),
        Feature(
            symbolName: "text.quote",
            title: String(localized: "Synced lyrics"),
            detail: String(localized: "Time-synced lyrics that follow along as you listen.")
        ),
        Feature(
            symbolName: "sparkles",
            title: String(localized: "Year in Music"),
            detail: String(localized: "A shareable recap built from your local play history.")
        ),
        Feature(
            symbolName: "menubar.dock.rectangle",
            title: String(localized: "Menu bar player & folder watching"),
            detail: String(localized: "Control playback from the menu bar; new files appear in your library instantly.")
        ),
    ]

    private let backdrop = AmbientBackdropView()
    private let scrollView = NSScrollView()
    private let planPicker = MacPlanPickerView()
    private let proofCard = MacPaywallProofCard()
    private let yearlyFootnote = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let purchaseButton = NSButton(title: String(localized: "Get Lifetime"), target: nil, action: nil)
    private let purchaseSubline = NSTextField(labelWithString: "")
    private let restoreButton = NSButton(title: String(localized: "Restore Purchases"), target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    private var hasCelebrated = false

    private var isTransacting = false {
        didSet {
            purchaseButton.isEnabled = !isTransacting && purchaseAvailable
            restoreButton.isEnabled = !isTransacting
            planPicker.isEnabled = !isTransacting
            if isTransacting {
                spinner.startAnimation(nil)
            } else {
                spinner.stopAnimation(nil)
            }
        }
    }

    private var purchaseAvailable = false

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.translatesAutoresizingMaskIntoConstraints = false
        root.widthAnchor.constraint(equalToConstant: Metrics.width).isActive = true
        root.heightAnchor.constraint(equalToConstant: Metrics.height).isActive = true

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(backdrop)

        let content = buildContent()
        configureScrollView(documentView: content)
        root.addSubview(scrollView)

        let footer = buildFooter()
        root.addSubview(footer)

        let closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: String(localized: "Close")) ?? NSImage(),
            target: self, action: #selector(closeTapped)
        )
        closeButton.isBordered = false
        closeButton.contentTintColor = MacColors.tertiaryLabel
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(closeButton)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            closeButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            closeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        backdrop.apply(ArtworkPaletteExtractor.fallbackPalette(seed: "flaccy-lifetime"), animated: false)
        NotificationCenter.default.addObserver(
            self, selector: #selector(purchaseStateDidChange), name: PurchaseManager.stateDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(purchaseStateDidChange), name: PurchaseManager.customerInfoDidLoad, object: nil
        )
        updateStatusLine()
        updateOffers()
        planPicker.onSelectionChange = { [weak self] _ in self?.updatePurchaseButton() }
        Task { [weak self] in
            let manager = PurchaseManager.shared
            async let proof = manager.loadProof()
            await manager.loadOffersIfNeeded()
            await manager.loadLapsedOfferIfNeeded()
            self?.updateOffers()
            self?.proofCard.render(await proof, state: manager.state)
        }
        AppLogger.info("Paywall presented (state \(PurchaseManager.shared.state))", category: .purchases)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        AppLogger.info("PaywallViewController deinit", category: .ui)
    }

    override func cancelOperation(_ sender: Any?) {
        closeTapped()
    }

    /// The document view is pinned to the clip view's width so wrapping labels
    /// measure against the sheet, and the content only ever scrolls vertically.
    private func configureScrollView(documentView: NSView) {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.drawsBackground = false

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        documentView.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(documentView)
        scrollView.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.topAnchor.constraint(equalTo: document.topAnchor, constant: 28),
            documentView.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Metrics.inset),
            documentView.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -Metrics.inset),
            documentView.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16),
        ])
    }

    private func buildContent() -> NSView {
        let tile = NSView()
        tile.wantsLayer = true
        tile.layer?.backgroundColor = Self.accent.withAlphaComponent(0.16).cgColor
        tile.layer?.cornerRadius = 16
        tile.layer?.cornerCurve = .continuous
        tile.translatesAutoresizingMaskIntoConstraints = false
        let symbol = NSImageView(image: NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) ?? NSImage())
        symbol.symbolConfiguration = .init(pointSize: 26, weight: .semibold)
        symbol.contentTintColor = Self.accent
        symbol.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(symbol)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 56),
            tile.heightAnchor.constraint(equalToConstant: 56),
            symbol.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])

        let kicker = NSTextField(labelWithString: "")
        kicker.attributedStringValue = NSAttributedString(
            string: String(localized: "FLACCY LIFETIME"),
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                .foregroundColor: MacColors.secondaryLabel,
                .kern: 2.2,
            ]
        )

        let title = NSTextField(wrappingLabelWithString: String(localized: "Own your music.\nForever."))
        title.font = .systemFont(ofSize: 32, weight: .heavy)
        title.textColor = MacColors.primaryLabel

        let featureCard = buildFeatureCard()

        yearlyFootnote.font = .systemFont(ofSize: 11)
        yearlyFootnote.textColor = MacColors.tertiaryLabel
        yearlyFootnote.isHidden = true

        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = MacColors.secondaryLabel

        let privacy = NSButton(title: String(localized: "Privacy Policy"), target: self, action: #selector(openPrivacy))
        privacy.isBordered = false
        privacy.contentTintColor = MacColors.tertiaryLabel
        privacy.font = .systemFont(ofSize: 11)
        let terms = NSButton(title: String(localized: "Terms of Use"), target: self, action: #selector(openTerms))
        terms.isBordered = false
        terms.contentTintColor = MacColors.tertiaryLabel
        terms.font = .systemFont(ofSize: 11)
        let legalRow = NSStackView(views: [privacy, terms])
        legalRow.orientation = .horizontal
        legalRow.spacing = 14

        proofCard.isHidden = true
        proofCard.alphaValue = 0

        let stack = NSStackView(views: [
            tile, kicker, title, planPicker, proofCard, featureCard, yearlyFootnote, statusLabel, legalRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: tile)
        stack.setCustomSpacing(4, after: kicker)
        stack.setCustomSpacing(18, after: title)
        stack.setCustomSpacing(14, after: planPicker)
        stack.setCustomSpacing(14, after: proofCard)
        stack.setCustomSpacing(12, after: featureCard)
        stack.setCustomSpacing(10, after: yearlyFootnote)
        stack.setCustomSpacing(6, after: statusLabel)
        for full in [planPicker, proofCard, featureCard, yearlyFootnote, statusLabel] {
            full.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func buildFooter() -> NSView {
        purchaseButton.bezelStyle = .rounded
        purchaseButton.controlSize = .large
        purchaseButton.keyEquivalent = "\r"
        purchaseButton.target = self
        purchaseButton.action = #selector(purchaseTapped)
        purchaseButton.font = .systemFont(ofSize: 15, weight: .bold)
        purchaseButton.widthAnchor.constraint(equalToConstant: 260).isActive = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        purchaseSubline.font = .systemFont(ofSize: 11, weight: .medium)
        purchaseSubline.textColor = MacColors.secondaryLabel

        restoreButton.isBordered = false
        restoreButton.contentTintColor = MacColors.secondaryLabel
        restoreButton.font = .systemFont(ofSize: 12, weight: .medium)
        restoreButton.target = self
        restoreButton.action = #selector(restoreTapped)

        let buyRow = NSStackView(views: [purchaseButton, spinner])
        buyRow.orientation = .horizontal
        buyRow.spacing = 8

        let stack = NSStackView(views: [buyRow, purchaseSubline, restoreButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.setCustomSpacing(8, after: purchaseSubline)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: Metrics.inset, bottom: 16, right: Metrics.inset)

        let footer = NSView()
        footer.wantsLayer = true
        footer.translatesAutoresizingMaskIntoConstraints = false
        let hairline = NSView()
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        hairline.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(hairline)
        footer.addSubview(stack)
        NSLayoutConstraint.activate([
            hairline.topAnchor.constraint(equalTo: footer.topAnchor),
            hairline.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
            stack.topAnchor.constraint(equalTo: footer.topAnchor),
            stack.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
        ])
        return footer
    }

    private func buildFeatureCard() -> NSView {
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 12
        list.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for feature in Self.features {
            let row = makeFeatureRow(feature)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -32).isActive = true
        }
        return RecapCard.host(list, cornerRadius: 20)
    }

    private func makeFeatureRow(_ feature: Feature) -> NSView {
        let tile = NSView()
        tile.wantsLayer = true
        tile.layer?.backgroundColor = Self.accent.withAlphaComponent(0.14).cgColor
        tile.layer?.cornerRadius = 9
        tile.layer?.cornerCurve = .continuous
        tile.translatesAutoresizingMaskIntoConstraints = false
        let symbol = NSImageView(image: NSImage(systemSymbolName: feature.symbolName, accessibilityDescription: nil) ?? NSImage())
        symbol.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        symbol.contentTintColor = Self.accent.withAlphaComponent(0.9)
        symbol.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(symbol)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 32),
            tile.heightAnchor.constraint(equalToConstant: 32),
            symbol.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])

        let titleLabel = NSTextField(labelWithString: feature.title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = MacColors.primaryLabel
        let detailLabel = NSTextField(wrappingLabelWithString: feature.detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = MacColors.secondaryLabel
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let row = NSStackView(views: [tile, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private func updateOffers() {
        let manager = PurchaseManager.shared
        var welcomeBackEnds: Date?
        if case .available(let endsAt) = manager.lapsedOfferState { welcomeBackEnds = endsAt }
        planPicker.configure(offers: manager.offersToPresent, welcomeBackEnds: welcomeBackEnds)
        updateYearlyFootnote(manager.yearlyOffer)
        updatePurchaseButton()
    }

    private func updateYearlyFootnote(_ yearly: PurchaseOffer?) {
        guard let yearly, !PurchaseManager.shared.state.isPurchased else {
            yearlyFootnote.isHidden = true
            return
        }
        yearlyFootnote.stringValue = PaywallCopy.yearlyFootnote(yearly: yearly)
        yearlyFootnote.isHidden = false
    }

    private func updatePurchaseButton() {
        let offer = planPicker.selectedOffer
        let plan = planPicker.selectedPlan
        purchaseAvailable = offer != nil
        purchaseButton.title = PaywallCopy.purchaseTitle(plan: plan, offer: offer)
        purchaseSubline.stringValue = PaywallCopy.purchaseSubline(plan: plan)
        purchaseButton.setAccessibilityHelp(PaywallCopy.purchaseHint(plan: plan))
        purchaseButton.isEnabled = purchaseAvailable && !isTransacting
    }

    private func updateStatusLine() {
        statusLabel.stringValue = PaywallCopy.statusLine(for: PurchaseManager.shared.state)
    }

    @objc private func purchaseStateDidChange() {
        updateStatusLine()
        updateOffers()
        proofCard.retitle(for: PurchaseManager.shared.state)
        if PurchaseManager.shared.state.isPurchased, !isTransacting {
            finishOwned()
        }
    }

    /// The moment the entitlement lands: the sheet goes away first, then the
    /// thank-you toast lands on the window underneath it, and a lifetime unlock
    /// tells the review prompt that the next completed play is the moment to ask.
    private func finishOwned() {
        let parent = view.window?.sheetParent
        let isLifetime = PurchaseManager.shared.state == .purchased(.lifetime)
        closeTapped()
        guard isLifetime, !hasCelebrated else { return }
        hasCelebrated = true
        MacToast.show(String(localized: "You own Flaccy. Thank you."), style: .success, in: parent)
        ReviewPrompt.recordLifetimePurchase()
    }

    @objc private func purchaseTapped() {
        guard !isTransacting, let offer = planPicker.selectedOffer else { return }
        isTransacting = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isTransacting = false }
            do {
                switch try await PurchaseManager.shared.purchase(offer) {
                case .purchased:
                    self.finishOwned()
                case .pending:
                    self.presentInfoAlert(
                        title: String(localized: "Purchase Pending"),
                        message: String(localized: "Your purchase is awaiting approval. Playback unlocks automatically once it completes.")
                    )
                case .cancelled:
                    break
                }
            } catch {
                AppLogger.error("Purchase failed: \(error.localizedDescription)", category: .purchases)
                self.presentInfoAlert(
                    title: String(localized: "Purchase Failed"),
                    message: String(localized: "The purchase couldn't be completed. Check your connection and try again.")
                )
            }
        }
    }

    @objc private func restoreTapped() {
        guard !isTransacting else { return }
        isTransacting = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isTransacting = false }
            switch await PurchaseManager.shared.restore() {
            case .restored:
                if PurchaseManager.shared.state == .purchased(.lifetime) {
                    self.finishOwned()
                } else {
                    let parent = self.view.window?.sheetParent
                    self.closeTapped()
                    MacToast.show(String(localized: "Purchase restored"), style: .success, in: parent)
                }
            case .nothingToRestore:
                self.presentInfoAlert(
                    title: String(localized: "Nothing to Restore"),
                    message: String(localized: "No previous purchase was found for this Apple Account.")
                )
            case .failed:
                self.presentInfoAlert(
                    title: String(localized: "Restore Failed"),
                    message: String(localized: "Couldn't reach the App Store. Check your connection and try again.")
                )
            }
        }
    }

    private func presentInfoAlert(title: String, message: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.beginSheetModal(for: window)
    }

    @objc private func closeTapped() {
        if let presenting = presentingViewController {
            presenting.dismiss(self)
        } else {
            dismiss(nil)
        }
    }

    @objc private func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "https://mako.midgarcorp.cc/privacy/flaccy")!)
    }

    @objc private func openTerms() {
        NSWorkspace.shared.open(URL(string: "https://mako.midgarcorp.cc/terms/flaccy")!)
    }
}

/// Two selectable plan rows, lifetime first and preselected, mirroring the iOS
/// `PlanPickerView`: a radio glyph, the plan's name, badge and caption, and the
/// store's localized price. The lifetime row becomes the welcome-back card
/// whenever the offer it is handed says so.
final class MacPlanPickerView: NSView {

    private(set) var selectedPlan: PurchasePlan = .lifetime
    var onSelectionChange: ((PurchasePlan) -> Void)?

    var isEnabled = true {
        didSet { cards.values.forEach { $0.isEnabled = isEnabled } }
    }

    private var offers: [PurchaseOffer] = []
    private var cards: [PurchasePlan: MacPlanCard] = [:]

    var selectedOffer: PurchaseOffer? {
        offers.first { $0.plan == selectedPlan }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for plan in [PurchasePlan.lifetime, .yearly] {
            let card = MacPlanCard(plan: plan) { [weak self] in self?.select(plan) }
            cards[plan] = card
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        configure(offers: [], welcomeBackEnds: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(offers: [PurchaseOffer], welcomeBackEnds: Date?) {
        self.offers = offers
        let lifetime = offers.first { $0.plan == .lifetime }
        let yearly = offers.first { $0.plan == .yearly }
        cards[.lifetime]?.render(
            offer: lifetime,
            caption: PaywallCopy.lifetimeCaption(lifetime: lifetime, yearly: yearly, welcomeBackEnds: welcomeBackEnds)
        )
        cards[.yearly]?.render(offer: yearly, caption: PaywallCopy.yearlyCaption)
        for (plan, card) in cards {
            card.isSelectedPlan = plan == selectedPlan
        }
    }

    private func select(_ plan: PurchasePlan) {
        guard isEnabled, plan != selectedPlan else { return }
        selectedPlan = plan
        for (candidate, card) in cards {
            card.isSelectedPlan = candidate == plan
        }
        onSelectionChange?(plan)
    }
}

private final class MacPlanCard: NSControl {

    private static let accent = NSColor(red: 0.45, green: 0.86, blue: 0.92, alpha: 1)

    private let plan: PurchasePlan
    private let onSelect: () -> Void
    private let radio = NSImageView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let captionLabel = NSTextField(wrappingLabelWithString: "")
    private let priceLabel = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")

    var isSelectedPlan = false {
        didSet { applySelection() }
    }

    init(plan: PurchasePlan, onSelect: @escaping () -> Void) {
        self.plan = plan
        self.onSelect = onSelect
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1.5
        setAccessibilityRole(.radioButton)

        radio.symbolConfiguration = .init(pointSize: 18, weight: .semibold)
        radio.translatesAutoresizingMaskIntoConstraints = false
        radio.widthAnchor.constraint(equalToConstant: 22).isActive = true

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = MacColors.primaryLabel
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        captionLabel.font = .systemFont(ofSize: 11)
        captionLabel.textColor = MacColors.secondaryLabel

        badge.font = .systemFont(ofSize: 9, weight: .bold)
        badge.textColor = .black
        badge.wantsLayer = true
        badge.layer?.backgroundColor = Self.accent.cgColor
        badge.layer?.cornerRadius = 6
        badge.layer?.cornerCurve = .continuous
        badge.alignment = .center
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)

        let titleRow = NSStackView(views: [titleLabel, badge])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        let text = NSStackView(views: [titleRow, captionLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        priceLabel.font = .systemFont(ofSize: 13, weight: .bold)
        priceLabel.textColor = MacColors.primaryLabel
        priceLabel.alignment = .right
        priceLabel.setContentHuggingPriority(.required, for: .horizontal)
        priceLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [radio, text, priceLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        text.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        switch plan {
        case .yearly:
            titleLabel.stringValue = String(localized: "Yearly")
        case .lifetime:
            titleLabel.stringValue = String(localized: "Lifetime")
        }
        render(offer: nil, caption: "")
        applySelection()
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func render(offer: PurchaseOffer?, caption: String) {
        captionLabel.stringValue = caption
        switch plan {
        case .yearly:
            badge.isHidden = true
            priceLabel.stringValue = offer.map { String(localized: "\($0.displayPrice)/yr") } ?? "—"
        case .lifetime:
            badge.stringValue = "  \(PaywallCopy.lifetimeBadge(for: offer))  "
            badge.isHidden = false
            priceLabel.stringValue = offer?.displayPrice ?? "—"
        }
        setAccessibilityLabel("\(titleLabel.stringValue), \(priceLabel.stringValue), \(captionLabel.stringValue)")
    }

    private func applySelection() {
        radio.image = NSImage(
            systemSymbolName: isSelectedPlan ? "checkmark.circle.fill" : "circle",
            accessibilityDescription: nil
        )
        radio.contentTintColor = isSelectedPlan ? Self.accent : MacColors.tertiaryLabel
        layer?.backgroundColor = (isSelectedPlan
            ? Self.accent.withAlphaComponent(0.14)
            : NSColor.white.withAlphaComponent(0.06)).cgColor
        layer?.borderColor = (isSelectedPlan ? Self.accent : NSColor.white.withAlphaComponent(0.1)).cgColor
        setAccessibilityValue(isSelectedPlan ? 1 : 0)
    }

    @objc private func clicked() {
        guard isEnabled else { return }
        onSelect()
    }
}

/// What the reader has already set up, on the paywall above the feature list:
/// up to three live counts from the library, faded in once they arrive and
/// never rendered for an empty library.
final class MacPaywallProofCard: NSView {

    private static let accent = NSColor(red: 0.45, green: 0.86, blue: 0.92, alpha: 1)

    private let titleLabel = NSTextField(labelWithString: "")
    private let lines = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = MacColors.primaryLabel
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 6
        let stack = NSStackView(views: [titleLabel, lines])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        let card = RecapCard.host(stack, cornerRadius: 20)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalTo: card.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func render(_ proof: PaywallProof, state: EntitlementState) {
        let rendered = proof.lines()
        guard proof.hasLibrary, !rendered.isEmpty else {
            isHidden = true
            return
        }
        retitle(for: state)
        lines.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for line in rendered {
            lines.addArrangedSubview(makeRow(PaywallCopy.proofLine(line)))
        }
        guard isHidden else { return }
        isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    func retitle(for state: EntitlementState) {
        titleLabel.stringValue = PaywallCopy.proofTitle(for: state)
    }

    private func makeRow(_ text: String) -> NSView {
        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) ?? NSImage())
        check.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        check.contentTintColor = Self.accent
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = MacColors.secondaryLabel
        let row = NSStackView(views: [check, label])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }
}
