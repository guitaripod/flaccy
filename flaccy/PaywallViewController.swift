import FlaccyCore
import RevenueCat
import SafariServices
import StoreKit
import UIKit

enum LegalLinks {
    static let privacyURL = URL(string: "https://mako.midgarcorp.cc/privacy/flaccy")!
    static let termsURL = URL(string: "https://mako.midgarcorp.cc/terms/flaccy")!
}

/// The lifetime-first paywall: a scrolling story — header, plan picker, what
/// the person has already set up, what the app does, the yearly disclosure —
/// under a pinned bar that always shows the price and the one button that
/// matters. Everything it sells comes from `PurchaseManager.offersToPresent`,
/// so the welcome-back price appears here only when the manager says it may.
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
    private let proofCard = PaywallProofCardView()
    private let yearlyFootnoteLabel = UILabel()
    private let statusLabel = UILabel()
    private let bottomBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    private let purchaseButton = UIButton(configuration: .filled())
    private let purchaseSublineLabel = UILabel()
    private let restoreButton = UIButton(configuration: .plain())

    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private let notificationFeedback = UINotificationFeedbackGenerator()

    private var hasCelebrated = false

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
        setupBottomBar()
        setupScrollView()
        buildContent()
        updateStatusLine()
        updateOffers()
        NotificationCenter.default.addObserver(
            self, selector: #selector(purchaseStateDidChange), name: PurchaseManager.stateDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(purchaseStateDidChange), name: PurchaseManager.customerInfoDidLoad, object: nil
        )
        Task {
            let manager = PurchaseManager.shared
            async let proof = manager.loadProof()
            await manager.loadOffersIfNeeded()
            await manager.loadLapsedOfferIfNeeded()
            updateOffers()
            showProof(await proof)
        }
        AppLogger.info("Paywall presented (state \(PurchaseManager.shared.state))", category: .purchases)
    }

    @objc private func purchaseStateDidChange() {
        updateStatusLine()
        updateOffers()
        guard PurchaseManager.shared.state.isPurchased, presentedViewController == nil, !isTransacting else { return }
        finishAfterPurchase()
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

    /// The price, the button, its promise and Restore live over the scroll view
    /// on a material bar, so the offer is on screen whatever the person is reading.
    private func setupBottomBar() {
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomBar)

        let hairline = UIView()
        hairline.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        hairline.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.contentView.addSubview(hairline)

        configurePurchaseButton()
        configurePurchaseSubline()
        configureRestoreButton()

        let stack = UIStackView(arrangedSubviews: [purchaseButton, purchaseSublineLabel, restoreButton])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 8
        stack.setCustomSpacing(2, after: purchaseSublineLabel)
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 12, left: 24, bottom: 4, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            hairline.topAnchor.constraint(equalTo: bottomBar.contentView.topAnchor),
            hairline.leadingAnchor.constraint(equalTo: bottomBar.contentView.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: bottomBar.contentView.trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 0.5),

            stack.topAnchor.constraint(equalTo: bottomBar.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: bottomBar.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bottomBar.contentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    private func setupScrollView() {
        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(scrollView, belowSubview: bottomBar)

        contentStack.axis = .vertical
        contentStack.spacing = 14
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.layoutMargins = UIEdgeInsets(top: 28, left: 24, bottom: 24, right: 24)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

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

        planPicker.onSelectionChange = { [weak self] _ in
            self?.selectionFeedback.selectionChanged()
            self?.updatePurchaseButtonTitle()
        }
        contentStack.addArrangedSubview(planPicker)
        contentStack.setCustomSpacing(16, after: planPicker)

        proofCard.isHidden = true
        proofCard.alpha = 0
        contentStack.addArrangedSubview(proofCard)
        contentStack.setCustomSpacing(16, after: proofCard)

        let featureCard = makeFeatureCard()
        contentStack.addArrangedSubview(featureCard)
        contentStack.setCustomSpacing(18, after: featureCard)

        configureYearlyFootnote()
        contentStack.addArrangedSubview(yearlyFootnoteLabel)
        contentStack.setCustomSpacing(14, after: yearlyFootnoteLabel)

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
            string: String(localized: "FLACCY LIFETIME"),
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
        let card = PaywallCardView()
        let stack = UIStackView(arrangedSubviews: Self.features.map(makeFeatureRow))
        stack.axis = .vertical
        stack.spacing = 16
        card.install(stack)
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
        purchaseButton.accessibilityIdentifier = "paywall.purchase"
        purchaseButton.heightAnchor.constraint(equalToConstant: 54).isActive = true
        purchaseButton.addAction(UIAction { [weak self] _ in
            self?.handlePurchaseTap()
        }, for: .touchUpInside)
    }

    private func configurePurchaseSubline() {
        purchaseSublineLabel.font = .scaled(.footnote, size: 13, weight: .medium)
        purchaseSublineLabel.adjustsFontForContentSizeCategory = true
        purchaseSublineLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        purchaseSublineLabel.textAlignment = .center
        purchaseSublineLabel.numberOfLines = 0
    }

    private func configureRestoreButton() {
        var config = UIButton.Configuration.plain()
        config.attributedTitle = AttributedString(
            String(localized: "Restore Purchases"),
            attributes: AttributeContainer([.font: UIFont.scaled(.subheadline, size: 15, weight: .medium)])
        )
        config.baseForegroundColor = UIColor.white.withAlphaComponent(0.7)
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        restoreButton.configuration = config
        restoreButton.accessibilityIdentifier = "paywall.restore"
        restoreButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        restoreButton.addAction(UIAction { [weak self] _ in
            self?.handleRestoreTap()
        }, for: .touchUpInside)
    }

    private func configureYearlyFootnote() {
        yearlyFootnoteLabel.font = .scaled(.caption1, size: 12, weight: .regular)
        yearlyFootnoteLabel.adjustsFontForContentSizeCategory = true
        yearlyFootnoteLabel.textColor = UIColor.white.withAlphaComponent(0.5)
        yearlyFootnoteLabel.textAlignment = .center
        yearlyFootnoteLabel.numberOfLines = 0
        yearlyFootnoteLabel.isHidden = true
    }

    private func configureStatusLabel() {
        statusLabel.font = .scaled(.footnote, size: 13, weight: .medium)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
    }

    private func updateOffers() {
        let manager = PurchaseManager.shared
        var welcomeBackEnds: Date?
        if case .available(let endsAt) = manager.lapsedOfferState { welcomeBackEnds = endsAt }
        planPicker.configure(offers: manager.offersToPresent, welcomeBackEnds: welcomeBackEnds)
        updateYearlyFootnote(manager.yearlyOffer)
        updatePurchaseButtonTitle()
    }

    private func updateYearlyFootnote(_ yearly: PurchaseOffer?) {
        guard let yearly else {
            yearlyFootnoteLabel.isHidden = true
            return
        }
        yearlyFootnoteLabel.text = PaywallCopy.yearlyFootnote(yearly: yearly)
        yearlyFootnoteLabel.isHidden = false
    }

    private func updatePurchaseButtonTitle() {
        let plan = planPicker.selectedPlan
        purchaseButton.configuration?.attributedTitle = AttributedString(
            PaywallCopy.purchaseTitle(plan: plan, offer: planPicker.selectedOffer),
            attributes: AttributeContainer([.font: UIFont.scaled(.headline, size: 17, weight: .bold)])
        )
        purchaseSublineLabel.text = PaywallCopy.purchaseSubline(plan: plan)
        purchaseButton.accessibilityHint = PaywallCopy.purchaseHint(plan: plan)
        purchaseButton.isEnabled = !isTransacting && planPicker.selectedOffer != nil
    }

    private func updateStatusLine() {
        statusLabel.text = PaywallCopy.statusLine(for: PurchaseManager.shared.state)
        proofCard.setTitle(for: PurchaseManager.shared.state)
    }

    private func showProof(_ proof: PaywallProof) {
        guard proof.hasLibrary, !proof.lines().isEmpty else { return }
        proofCard.render(proof, state: PurchaseManager.shared.state)
        proofCard.isHidden = false
        let animator = UIViewPropertyAnimator(duration: 0.35, curve: .easeOut) {
            self.proofCard.alpha = 1
        }
        animator.startAnimation()
    }

    private func updateControlsForTransactionState() {
        purchaseButton.isEnabled = !isTransacting && planPicker.selectedOffer != nil
        restoreButton.isEnabled = !isTransacting
        planPicker.isUserInteractionEnabled = !isTransacting
        purchaseButton.configuration?.showsActivityIndicator = isTransacting
    }

    private func handlePurchaseTap() {
        guard !isTransacting, let offer = planPicker.selectedOffer else { return }
        impactMedium.impactOccurred()
        isTransacting = true
        Task {
            defer { isTransacting = false }
            do {
                switch try await PurchaseManager.shared.purchase(offer) {
                case .purchased:
                    finishAfterPurchase()
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
            switch await PurchaseManager.shared.restore() {
            case .restored:
                finishAfterPurchase()
            case .nothingToRestore:
                presentInfoAlert(
                    title: String(localized: "Nothing to Restore"),
                    message: String(localized: "No previous purchase was found for this Apple Account.")
                )
            case .failed:
                notificationFeedback.notificationOccurred(.error)
                presentInfoAlert(
                    title: String(localized: "Restore Failed"),
                    message: String(localized: "Couldn't reach the App Store. Check your connection and try again.")
                )
            }
        }
    }

    /// Closes the sheet once the entitlement is active. A lifetime unlock gets
    /// the moment it deserves — a thank-you toast over whatever presented the
    /// paywall, and the next completed play asks for a review.
    private func finishAfterPurchase() {
        guard !hasCelebrated else { return }
        hasCelebrated = true
        notificationFeedback.notificationOccurred(.success)
        let isLifetime = PurchaseManager.shared.state == .purchased(.lifetime)
        let host = presentingViewController?.view
        dismiss(animated: true) {
            guard isLifetime else { return }
            ReviewPrompt.recordLifetimePurchase()
            guard let host else { return }
            ToastView.show(String(localized: "You own Flaccy. Thank you."), in: host, style: .success)
        }
    }

    private func presentInfoAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }
}

/// The paywall's translucent card chrome, shared by the feature list and the
/// proof card so the two read as one system.
private final class PaywallCardView: UIView {

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.white.withAlphaComponent(
            UIAccessibility.isReduceTransparencyEnabled ? 0.1 : 0.06
        )
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func install(_ stack: UIStackView) {
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 20, left: 18, bottom: 20, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

/// What the person has already set up in Flaccy, as a short list of counted
/// facts — the most honest argument the paywall has. It renders nothing for an
/// empty library and fades in once the counts arrive.
final class PaywallProofCardView: UIView {

    private static let accent = QualityBadgeView.losslessTint

    private let card = PaywallCardView()
    private let titleLabel = UILabel()
    private let linesStack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = .scaled(.subheadline, size: 15, weight: .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits = .header

        linesStack.axis = .vertical
        linesStack.spacing = 10

        let stack = UIStackView(arrangedSubviews: [titleLabel, linesStack])
        stack.axis = .vertical
        stack.spacing = 14
        card.install(stack)

        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTitle(for state: EntitlementState) {
        titleLabel.text = PaywallCopy.proofTitle(for: state)
    }

    func render(_ proof: PaywallProof, state: EntitlementState) {
        setTitle(for: state)
        linesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for line in proof.lines() {
            linesStack.addArrangedSubview(makeRow(symbolName: Self.symbolName(for: line), text: PaywallCopy.proofLine(line)))
        }
    }

    private func makeRow(symbolName: String, text: String) -> UIView {
        let symbolView = UIImageView(
            image: UIImage(
                systemName: symbolName,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            )
        )
        symbolView.tintColor = Self.accent
        symbolView.contentMode = .center
        symbolView.setContentHuggingPriority(.required, for: .horizontal)
        symbolView.setContentCompressionResistancePriority(.required, for: .horizontal)
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let label = UILabel()
        label.text = text
        label.font = .scaled(.subheadline, size: 15, weight: .medium)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = UIColor.white.withAlphaComponent(0.88)
        label.numberOfLines = 0

        let row = UIStackView(arrangedSubviews: [symbolView, label])
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .center
        row.isAccessibilityElement = true
        row.accessibilityLabel = text
        return row
    }

    private static func symbolName(for line: PaywallProof.Line) -> String {
        switch line {
        case .lossless: "waveform"
        case .scrobbled: "dot.radiowaves.left.and.right"
        case .playsCounted: "play.circle"
        case .lyrics: "text.quote"
        case .covers: "photo.on.rectangle.angled"
        case .aiReviewed: "wand.and.stars"
        }
    }
}

/// Two selectable plan cards — lifetime first and preselected, yearly second —
/// with a radio affordance, the store's localized price, and a caption that
/// says what each one buys. Lifetime leads because it is the product; yearly
/// stays listed for the person who wants the lower commitment.
final class PlanPickerView: UIView {

    private(set) var selectedPlan: PurchasePlan = .lifetime
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
        for plan in [PurchasePlan.lifetime, .yearly] {
            let card = PlanCardControl(plan: plan)
            card.addAction(UIAction { [weak self] _ in self?.select(plan) }, for: .touchUpInside)
            cards[plan] = card
            stack.addArrangedSubview(card)
        }
        configure(offers: [], welcomeBackEnds: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(offers: [PurchaseOffer], welcomeBackEnds: Date?) {
        self.offers = offers
        let lifetime = offers.first { $0.plan == .lifetime }
        let yearly = offers.first { $0.plan == .yearly }
        cards[.lifetime]?.configure(
            offer: lifetime,
            caption: PaywallCopy.lifetimeCaption(lifetime: lifetime, yearly: yearly, welcomeBackEnds: welcomeBackEnds)
        )
        cards[.yearly]?.configure(offer: yearly, caption: PaywallCopy.yearlyCaption)
        for (plan, card) in cards {
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
        accessibilityIdentifier = "paywall.plan.\(plan.rawValue)"

        radio.contentMode = .center
        radio.setContentHuggingPriority(.required, for: .horizontal)
        radio.translatesAutoresizingMaskIntoConstraints = false
        radio.widthAnchor.constraint(equalToConstant: 24).isActive = true

        titleLabel.font = .scaled(.headline, size: 16, weight: .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 0

        captionLabel.font = .scaled(.footnote, size: 13, weight: .regular)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        captionLabel.numberOfLines = 0

        badge.font = .scaled(.caption2, size: 10, weight: .bold)
        badge.adjustsFontForContentSizeCategory = true
        badge.textColor = .black
        badge.backgroundColor = Self.accent
        badge.layer.cornerRadius = 7
        badge.layer.cornerCurve = .continuous
        badge.layer.masksToBounds = true
        badge.textAlignment = .center
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

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
            badge.isHidden = true
        case .lifetime:
            titleLabel.text = String(localized: "Lifetime")
        }
        configure(offer: nil, caption: "")
        applySelection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(offer: PurchaseOffer?, caption: String) {
        captionLabel.text = caption
        switch (plan, offer) {
        case (.yearly, let offer?):
            priceLabel.text = String(localized: "\(offer.displayPrice)/yr")
        case (.lifetime, let offer?):
            priceLabel.text = offer.displayPrice
        case (_, nil):
            priceLabel.text = "—"
        }
        if plan == .lifetime {
            badge.text = "  \(PaywallCopy.lifetimeBadge(for: offer).uppercased())  "
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
        let badgeText = badge.isHidden ? nil : badge.text?.trimmingCharacters(in: .whitespaces)
        accessibilityLabel = [titleLabel.text, badgeText, priceLabel.text, captionLabel.text]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}
