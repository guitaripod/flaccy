import AppKit
import StoreKit

/// The Flaccy Pro paywall (yearly or lifetime), presented as a sheet on the main window: the
/// iOS paywall's visual language over an ambient palette backdrop, with the
/// Apple Watch bullet swapped for the desktop's menu-bar/folder-watch story.
final class PaywallViewController: NSViewController {

    private struct Feature {
        let symbolName: String
        let title: String
        let detail: String
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
    private let planPicker = MacPlanPickerView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let purchaseButton = NSButton(title: String(localized: "Start Yearly"), target: nil, action: nil)
    private let restoreButton = NSButton(title: String(localized: "Restore Purchases"), target: nil, action: nil)
    private let spinner = NSProgressIndicator()

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
        root.widthAnchor.constraint(equalToConstant: 460).isActive = true
        root.heightAnchor.constraint(equalToConstant: 700).isActive = true

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(backdrop)

        let content = buildContent()
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)

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
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 30),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -30),
            content.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
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
        updateStatusLine()
        updateOffers()
        planPicker.onSelectionChange = { [weak self] _ in self?.updatePurchaseButton() }
        Task { [weak self] in
            await PurchaseManager.shared.loadOffersIfNeeded()
            self?.updateOffers()
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
            string: String(localized: "FLACCY PRO"),
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

        purchaseButton.bezelStyle = .rounded
        purchaseButton.controlSize = .large
        purchaseButton.keyEquivalent = "\r"
        purchaseButton.target = self
        purchaseButton.action = #selector(purchaseTapped)
        purchaseButton.font = .systemFont(ofSize: 15, weight: .bold)

        restoreButton.isBordered = false
        restoreButton.contentTintColor = MacColors.secondaryLabel
        restoreButton.font = .systemFont(ofSize: 12, weight: .medium)
        restoreButton.target = self
        restoreButton.action = #selector(restoreTapped)

        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = MacColors.secondaryLabel
        statusLabel.alignment = .center

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

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

        let buyRow = NSStackView(views: [purchaseButton, spinner])
        buyRow.orientation = .horizontal
        buyRow.spacing = 8

        let stack = NSStackView(views: [
            tile, kicker, title, featureCard, planPicker, buyRow, restoreButton, statusLabel, legalRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: tile)
        stack.setCustomSpacing(4, after: kicker)
        stack.setCustomSpacing(18, after: title)
        stack.setCustomSpacing(18, after: featureCard)
        stack.setCustomSpacing(12, after: planPicker)
        planPicker.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(2, after: buyRow)
        stack.setCustomSpacing(8, after: restoreButton)
        featureCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        purchaseButton.widthAnchor.constraint(equalToConstant: 240).isActive = true
        return stack
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
        planPicker.configure(offers: PurchaseManager.shared.offers)
        updatePurchaseButton()
    }

    private func updatePurchaseButton() {
        let offer = planPicker.selectedOffer
        purchaseAvailable = offer != nil
        switch planPicker.selectedPlan {
        case .yearly:
            purchaseButton.title = offer.map { String(localized: "Start Yearly · \($0.displayPrice)") }
                ?? String(localized: "Start Yearly")
        case .lifetime:
            purchaseButton.title = offer.map { String(localized: "Unlock Lifetime · \($0.displayPrice)") }
                ?? String(localized: "Unlock Lifetime")
        }
        purchaseButton.isEnabled = purchaseAvailable && !isTransacting
    }

    private func updateStatusLine() {
        switch PurchaseManager.shared.state {
        case .trial(let daysRemaining):
            statusLabel.stringValue = String(localized: "\(daysRemaining) days left in your trial")
        case .expired:
            statusLabel.stringValue = String(localized: "Your trial has ended")
        case .purchased(.lifetime):
            statusLabel.stringValue = String(localized: "Lifetime unlocked. Thank you.")
        case .purchased(.yearly):
            statusLabel.stringValue = String(localized: "Flaccy Pro is active. Thank you.")
        }
    }

    @objc private func purchaseStateDidChange() {
        updateStatusLine()
        if PurchaseManager.shared.state.isPurchased, !isTransacting {
            closeTapped()
        }
    }

    @objc private func purchaseTapped() {
        guard !isTransacting else { return }
        isTransacting = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isTransacting = false }
            do {
                switch try await PurchaseManager.shared.purchase(self.planPicker.selectedPlan) {
                case .purchased:
                    self.closeTapped()
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
            let restored = await PurchaseManager.shared.restore()
            if restored {
                self.closeTapped()
            } else {
                self.presentInfoAlert(
                    title: String(localized: "Nothing to Restore"),
                    message: String(localized: "No previous purchase was found for this Apple Account.")
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

/// Two selectable plan rows, yearly and lifetime, mirroring the iOS
/// `PlanPickerView`: a radio glyph, the plan's name and caption, and the
/// store's localized price. Yearly is selected by default.
final class MacPlanPickerView: NSView {

    private(set) var selectedPlan: PurchasePlan = .yearly
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
        for plan in [PurchasePlan.yearly, .lifetime] {
            let card = MacPlanCard(plan: plan) { [weak self] in self?.select(plan) }
            cards[plan] = card
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        configure(offers: [])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(offers: [PurchaseOffer]) {
        self.offers = offers
        for (plan, card) in cards {
            card.setPrice(offers.first { $0.plan == plan }?.displayPrice)
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
    private let titleLabel = NSTextField(labelWithString: "")
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
        captionLabel.font = .systemFont(ofSize: 11)
        captionLabel.textColor = MacColors.secondaryLabel

        badge.font = .systemFont(ofSize: 9, weight: .bold)
        badge.textColor = .black
        badge.wantsLayer = true
        badge.layer?.backgroundColor = Self.accent.cgColor
        badge.layer?.cornerRadius = 6
        badge.layer?.cornerCurve = .continuous
        badge.alignment = .center

        let titleRow = NSStackView(views: [titleLabel, badge])
        titleRow.orientation = .horizontal
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
            captionLabel.stringValue = String(localized: "Everything, renews each year. Cancel anytime.")
            badge.stringValue = "  \(String(localized: "MOST POPULAR"))  "
        case .lifetime:
            titleLabel.stringValue = String(localized: "Lifetime")
            captionLabel.stringValue = String(localized: "Pay once, own it forever.")
            badge.stringValue = "  \(String(localized: "PAY ONCE"))  "
        }
        setPrice(nil)
        applySelection()
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPrice(_ price: String?) {
        switch (plan, price) {
        case (.yearly, let price?):
            priceLabel.stringValue = String(localized: "\(price)/yr")
        case (.lifetime, let price?):
            priceLabel.stringValue = price
        case (_, nil):
            priceLabel.stringValue = "—"
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
