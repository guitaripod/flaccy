import SafariServices
import StoreKit
import UIKit

enum LegalLinks {
    static let privacyURL = URL(string: "https://mako.midgarcorp.cc/privacy/flaccy")!
    static let termsURL = URL(string: "https://mako.midgarcorp.cc/terms/flaccy")!
}

final class PaywallViewController: UIViewController {

    private static let accent = QualityBadgeView.losslessTint

    private struct Feature {
        let symbolName: String
        let title: String
        let detail: String
    }

    private static let features: [Feature] = [
        Feature(
            symbolName: "infinity",
            title: String(localized: "Gapless lossless playback"),
            detail: String(localized: "FLAC albums flow track to track with zero silence.")
        ),
        Feature(
            symbolName: "wand.and.stars",
            title: String(localized: "AI tag cleanup"),
            detail: String(localized: "Scrambled filenames become real titles, artists and albums.")
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
            symbolName: "applewatch",
            title: String(localized: "Standalone Apple Watch app"),
            detail: String(localized: "Sync tracks and play from your wrist, no phone needed.")
        ),
    ]

    private let backdropView = AmbientPaletteBackdropView()
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let planPicker = PlanPickerView()
    private let statusLabel = UILabel()
    private let purchaseButton = UIButton(configuration: .filled())
    private let restoreButton = UIButton(configuration: .plain())

    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private let notificationFeedback = UINotificationFeedbackGenerator()

    private var isTransacting = false {
        didSet { updateControlsForTransactionState() }
    }

    static func presentSheet(from presenter: UIViewController) {
        let paywall = PaywallViewController()
        if let sheet = paywall.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        presenter.present(paywall, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        setupBackdrop()
        setupScrollView()
        buildContent()
        updateStatusLine()
        updateOffers()
        NotificationCenter.default.addObserver(
            self, selector: #selector(purchaseStateDidChange), name: PurchaseManager.stateDidChange, object: nil
        )
        Task {
            await PurchaseManager.shared.loadOffersIfNeeded()
            updateOffers()
        }
        AppLogger.info("Paywall presented (state \(PurchaseManager.shared.state))", category: .purchases)
    }

    @objc private func purchaseStateDidChange() {
        updateStatusLine()
        if PurchaseManager.shared.state.isPurchased, presentedViewController == nil, !isTransacting {
            dismiss(animated: true)
        }
    }

    private func setupBackdrop() {
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdropView)
        NSLayoutConstraint.activate([
            backdropView.topAnchor.constraint(equalTo: view.topAnchor),
            backdropView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdropView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        backdropView.apply(
            ArtworkPaletteExtractor.fallbackPalette(seed: "flaccy-lifetime"),
            animated: false
        )
    }

    private func setupScrollView() {
        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = 14
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.layoutMargins = UIEdgeInsets(top: 28, left: 24, bottom: 32, right: 24)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    private func buildContent() {
        let header = makeHeaderView()
        contentStack.addArrangedSubview(header)
        contentStack.setCustomSpacing(24, after: header)

        let featureCard = makeFeatureCard()
        contentStack.addArrangedSubview(featureCard)
        contentStack.setCustomSpacing(28, after: featureCard)

        planPicker.onSelectionChange = { [weak self] _ in
            self?.selectionFeedback.selectionChanged()
            self?.updatePurchaseButtonTitle()
        }
        contentStack.addArrangedSubview(planPicker)
        contentStack.setCustomSpacing(16, after: planPicker)

        configurePurchaseButton()
        contentStack.addArrangedSubview(purchaseButton)
        contentStack.setCustomSpacing(4, after: purchaseButton)

        configureRestoreButton()
        contentStack.addArrangedSubview(restoreButton)
        contentStack.setCustomSpacing(10, after: restoreButton)

        configureStatusLabel()
        contentStack.addArrangedSubview(statusLabel)
        contentStack.setCustomSpacing(10, after: statusLabel)

        contentStack.addArrangedSubview(makeLegalLinksRow())
    }

    private func makeLegalLinksRow() -> UIView {
        let row = UIStackView(arrangedSubviews: [
            makeLegalLinkButton(title: String(localized: "Privacy Policy"), url: LegalLinks.privacyURL),
            makeLegalLinkButton(title: String(localized: "Terms of Use"), url: LegalLinks.termsURL),
        ])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center

        let container = UIStackView(arrangedSubviews: [row])
        container.axis = .vertical
        container.alignment = .center
        return container
    }

    private func makeLegalLinkButton(title: String, url: URL) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.attributedTitle = AttributedString(
            title,
            attributes: AttributeContainer([.font: UIFont.scaled(.footnote, size: 13, weight: .regular)])
        )
        config.baseForegroundColor = UIColor.white.withAlphaComponent(0.55)
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        let button = UIButton(configuration: config)
        button.addAction(UIAction { [weak self] _ in
            self?.presentLegalPage(url)
        }, for: .touchUpInside)
        return button
    }

    private func presentLegalPage(_ url: URL) {
        let safari = SFSafariViewController(url: url)
        safari.preferredControlTintColor = Self.accent
        present(safari, animated: true)
    }

    private func makeHeaderView() -> UIView {
        let tile = UIView()
        tile.backgroundColor = Self.accent.withAlphaComponent(0.16)
        tile.layer.cornerRadius = 16
        tile.layer.cornerCurve = .continuous
        tile.translatesAutoresizingMaskIntoConstraints = false

        let symbolView = UIImageView(
            image: UIImage(
                systemName: "waveform",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
            )
        )
        symbolView.tintColor = Self.accent
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(symbolView)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 56),
            tile.heightAnchor.constraint(equalToConstant: 56),
            symbolView.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])

        let captionLabel = UILabel()
        captionLabel.attributedText = NSAttributedString(
            string: String(localized: "FLACCY PRO"),
            attributes: [
                .font: UIFont.scaled(.caption1, size: 12, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.65),
                .kern: 2.2,
            ]
        )
        captionLabel.adjustsFontForContentSizeCategory = true

        let titleLabel = UILabel()
        titleLabel.text = String(localized: "Own your music.\nForever.")
        titleLabel.font = .scaled(.largeTitle, size: 34, weight: .heavy)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits = .header

        let stack = UIStackView(arrangedSubviews: [tile, captionLabel, titleLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(18, after: tile)
        return stack
    }

    private func makeFeatureCard() -> UIView {
        let card = UIView()
        card.backgroundColor = UIColor.white.withAlphaComponent(
            UIAccessibility.isReduceTransparencyEnabled ? 0.1 : 0.06
        )
        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 0.5
        card.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor

        let stack = UIStackView(arrangedSubviews: Self.features.map(makeFeatureRow))
        stack.axis = .vertical
        stack.spacing = 16
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 20, left: 18, bottom: 20, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return card
    }

    private func makeFeatureRow(_ feature: Feature) -> UIView {
        let tile = UIView()
        tile.backgroundColor = Self.accent.withAlphaComponent(0.14)
        tile.layer.cornerRadius = 10
        tile.layer.cornerCurve = .continuous
        tile.translatesAutoresizingMaskIntoConstraints = false

        let symbolView = UIImageView(
            image: UIImage(
                systemName: feature.symbolName,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            )
        )
        symbolView.tintColor = Self.accent.withAlphaComponent(0.9)
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(symbolView)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 34),
            tile.heightAnchor.constraint(equalToConstant: 34),
            symbolView.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])

        let titleLabel = UILabel()
        titleLabel.text = feature.title
        titleLabel.font = .scaled(.subheadline, size: 15, weight: .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 0

        let detailLabel = UILabel()
        detailLabel.text = feature.detail
        detailLabel.font = .scaled(.footnote, size: 13, weight: .regular)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        detailLabel.numberOfLines = 0

        let textStack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        let row = UIStackView(arrangedSubviews: [tile, textStack])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.isAccessibilityElement = true
        row.accessibilityLabel = "\(feature.title). \(feature.detail)"
        return row
    }

    private func configurePurchaseButton() {
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = .white
        config.baseForegroundColor = .black
        config.cornerStyle = .capsule
        purchaseButton.configuration = config
        purchaseButton.heightAnchor.constraint(equalToConstant: 54).isActive = true
        updatePurchaseButtonTitle()
        purchaseButton.addAction(UIAction { [weak self] _ in
            self?.handlePurchaseTap()
        }, for: .touchUpInside)
    }

    private func configureRestoreButton() {
        var config = UIButton.Configuration.plain()
        config.attributedTitle = AttributedString(
            String(localized: "Restore Purchases"),
            attributes: AttributeContainer([.font: UIFont.scaled(.subheadline, size: 15, weight: .medium)])
        )
        config.baseForegroundColor = UIColor.white.withAlphaComponent(0.7)
        restoreButton.configuration = config
        restoreButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        restoreButton.addAction(UIAction { [weak self] _ in
            self?.handleRestoreTap()
        }, for: .touchUpInside)
    }

    private func configureStatusLabel() {
        statusLabel.font = .scaled(.footnote, size: 13, weight: .medium)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
    }

    private func updateOffers() {
        planPicker.configure(offers: PurchaseManager.shared.offers)
        updatePurchaseButtonTitle()
    }

    private func updatePurchaseButtonTitle() {
        let title: String
        let hint: String
        switch planPicker.selectedPlan {
        case .yearly:
            title = planPicker.selectedOffer.map { String(localized: "Start Yearly · \($0.displayPrice)") }
                ?? String(localized: "Start Yearly")
            hint = String(localized: "Subscribes for a year, renewing automatically until cancelled")
        case .lifetime:
            title = planPicker.selectedOffer.map { String(localized: "Unlock Lifetime · \($0.displayPrice)") }
                ?? String(localized: "Unlock Lifetime")
            hint = String(localized: "Buys lifetime access with a one-time purchase")
        }
        purchaseButton.configuration?.attributedTitle = AttributedString(
            title,
            attributes: AttributeContainer([.font: UIFont.scaled(.headline, size: 17, weight: .bold)])
        )
        purchaseButton.accessibilityHint = hint
        purchaseButton.isEnabled = !isTransacting && planPicker.selectedOffer != nil
    }

    private func updateStatusLine() {
        switch PurchaseManager.shared.state {
        case .trial(let daysRemaining):
            statusLabel.text = String(localized: "\(daysRemaining) days left in your trial")
        case .expired:
            statusLabel.text = String(localized: "Your trial has ended")
        case .purchased(.lifetime):
            statusLabel.text = String(localized: "Lifetime unlocked. Thank you.")
        case .purchased(.yearly):
            statusLabel.text = String(localized: "Flaccy Pro is active. Thank you.")
        }
    }

    private func updateControlsForTransactionState() {
        purchaseButton.isEnabled = !isTransacting && planPicker.selectedOffer != nil
        restoreButton.isEnabled = !isTransacting
        planPicker.isUserInteractionEnabled = !isTransacting
        purchaseButton.configuration?.showsActivityIndicator = isTransacting
    }

    private func handlePurchaseTap() {
        guard !isTransacting else { return }
        impactMedium.impactOccurred()
        isTransacting = true
        Task {
            defer { isTransacting = false }
            do {
                switch try await PurchaseManager.shared.purchase(planPicker.selectedPlan) {
                case .purchased:
                    notificationFeedback.notificationOccurred(.success)
                    dismiss(animated: true)
                case .pending:
                    presentInfoAlert(
                        title: String(localized: "Purchase Pending"),
                        message: String(localized: "Your purchase is awaiting approval. Playback unlocks automatically once it completes.")
                    )
                case .cancelled:
                    break
                }
            } catch {
                AppLogger.error("Purchase failed: \(error.localizedDescription)", category: .purchases)
                notificationFeedback.notificationOccurred(.error)
                presentInfoAlert(
                    title: String(localized: "Purchase Failed"),
                    message: String(localized: "The purchase couldn't be completed. Check your connection and try again.")
                )
            }
        }
    }

    private func handleRestoreTap() {
        guard !isTransacting else { return }
        isTransacting = true
        Task {
            defer { isTransacting = false }
            let restored = await PurchaseManager.shared.restore()
            if restored {
                notificationFeedback.notificationOccurred(.success)
                dismiss(animated: true)
            } else {
                presentInfoAlert(
                    title: String(localized: "Nothing to Restore"),
                    message: String(localized: "No previous purchase was found for this Apple Account.")
                )
            }
        }
    }

    private func presentInfoAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }
}

/// Two selectable plan cards — yearly and lifetime — with a radio affordance,
/// the store's localized price, and a caption that says what each one buys.
/// Yearly is the default because it is the lower commitment; lifetime is
/// labeled as the one-time option so the choice reads at a glance.
final class PlanPickerView: UIView {

    private(set) var selectedPlan: PurchasePlan = .yearly
    var onSelectionChange: ((PurchasePlan) -> Void)?

    private var offers: [PurchaseOffer] = []
    private let stack = UIStackView()
    private var cards: [PurchasePlan: PlanCardControl] = [:]

    var selectedOffer: PurchaseOffer? {
        offers.first { $0.plan == selectedPlan }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for plan in [PurchasePlan.yearly, .lifetime] {
            let card = PlanCardControl(plan: plan)
            card.addAction(UIAction { [weak self] _ in self?.select(plan) }, for: .touchUpInside)
            cards[plan] = card
            stack.addArrangedSubview(card)
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
        guard plan != selectedPlan else { return }
        selectedPlan = plan
        for (candidate, card) in cards {
            card.isSelectedPlan = candidate == plan
        }
        onSelectionChange?(plan)
    }
}

private final class PlanCardControl: UIControl {

    private static let accent = QualityBadgeView.losslessTint

    let plan: PurchasePlan
    private let radio = UIImageView()
    private let titleLabel = UILabel()
    private let captionLabel = UILabel()
    private let priceLabel = UILabel()
    private let badge = UILabel()

    var isSelectedPlan = false {
        didSet { applySelection() }
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.15) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.985, y: 0.985) : .identity
            }
        }
    }

    init(plan: PurchasePlan) {
        self.plan = plan
        super.init(frame: .zero)
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        layer.borderWidth = 1.5
        isAccessibilityElement = true
        accessibilityTraits = .button

        radio.contentMode = .center
        radio.setContentHuggingPriority(.required, for: .horizontal)
        radio.translatesAutoresizingMaskIntoConstraints = false
        radio.widthAnchor.constraint(equalToConstant: 24).isActive = true

        titleLabel.font = .scaled(.headline, size: 16, weight: .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white

        captionLabel.font = .scaled(.footnote, size: 13, weight: .regular)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        captionLabel.numberOfLines = 2

        badge.font = .scaled(.caption2, size: 10, weight: .bold)
        badge.adjustsFontForContentSizeCategory = true
        badge.textColor = .black
        badge.backgroundColor = Self.accent
        badge.layer.cornerRadius = 7
        badge.layer.cornerCurve = .continuous
        badge.layer.masksToBounds = true
        badge.textAlignment = .center
        badge.setContentHuggingPriority(.required, for: .horizontal)

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, badge, UIView()])
        titleRow.axis = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .center

        let textStack = UIStackView(arrangedSubviews: [titleRow, captionLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        priceLabel.font = .scaled(.headline, size: 16, weight: .bold)
        priceLabel.adjustsFontForContentSizeCategory = true
        priceLabel.textColor = .white
        priceLabel.textAlignment = .right
        priceLabel.setContentHuggingPriority(.required, for: .horizontal)
        priceLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [radio, textStack, priceLabel])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])

        switch plan {
        case .yearly:
            titleLabel.text = String(localized: "Yearly")
            captionLabel.text = String(localized: "Everything, renews each year. Cancel anytime.")
            badge.text = "  \(String(localized: "MOST POPULAR").uppercased())  "
        case .lifetime:
            titleLabel.text = String(localized: "Lifetime")
            captionLabel.text = String(localized: "Pay once, own it forever.")
            badge.text = "  \(String(localized: "PAY ONCE").uppercased())  "
        }
        setPrice(nil)
        applySelection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPrice(_ price: String?) {
        switch (plan, price) {
        case (.yearly, let price?):
            priceLabel.text = String(localized: "\(price)/yr")
        case (.lifetime, let price?):
            priceLabel.text = price
        case (_, nil):
            priceLabel.text = "—"
        }
        refreshAccessibility()
    }

    private func applySelection() {
        let symbol = isSelectedPlan ? "checkmark.circle.fill" : "circle"
        radio.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        )
        radio.tintColor = isSelectedPlan ? Self.accent : UIColor.white.withAlphaComponent(0.35)
        backgroundColor = isSelectedPlan
            ? Self.accent.withAlphaComponent(0.14)
            : UIColor.white.withAlphaComponent(UIAccessibility.isReduceTransparencyEnabled ? 0.1 : 0.06)
        layer.borderColor = (isSelectedPlan ? Self.accent : UIColor.white.withAlphaComponent(0.1)).cgColor
        if isSelectedPlan {
            accessibilityTraits.insert(.selected)
        } else {
            accessibilityTraits.remove(.selected)
        }
        refreshAccessibility()
    }

    private func refreshAccessibility() {
        accessibilityLabel = [titleLabel.text, priceLabel.text, captionLabel.text].compactMap { $0 }.joined(separator: ", ")
    }
}
