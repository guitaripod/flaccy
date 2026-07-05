import StoreKit
import UIKit

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
            title: "Gapless lossless playback",
            detail: "FLAC albums flow track to track with zero silence."
        ),
        Feature(
            symbolName: "dot.radiowaves.left.and.right",
            title: "Last.fm scrobbling",
            detail: "Every listen counted, with an offline queue that never drops a play."
        ),
        Feature(
            symbolName: "text.quote",
            title: "Synced lyrics",
            detail: "Time-synced lyrics that follow along as you listen."
        ),
        Feature(
            symbolName: "sparkles",
            title: "Year in Music",
            detail: "A shareable recap built from your local play history."
        ),
        Feature(
            symbolName: "applewatch",
            title: "Standalone Apple Watch app",
            detail: "Sync tracks and play from your wrist, no phone needed."
        ),
    ]

    private let backdropView = AmbientPaletteBackdropView()
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let priceLabel = UILabel()
    private let statusLabel = UILabel()
    private let purchaseButton = UIButton(configuration: .filled())
    private let restoreButton = UIButton(configuration: .plain())

    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
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
        updatePriceLine()
        NotificationCenter.default.addObserver(
            self, selector: #selector(purchaseStateDidChange), name: PurchaseManager.stateDidChange, object: nil
        )
        Task {
            await PurchaseManager.shared.loadProductIfNeeded()
            updatePriceLine()
        }
        AppLogger.info("Paywall presented (state \(PurchaseManager.shared.state))", category: .purchases)
    }

    @objc private func purchaseStateDidChange() {
        updateStatusLine()
        if PurchaseManager.shared.state == .purchased, presentedViewController == nil, !isTransacting {
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

        configurePriceLabel()
        contentStack.addArrangedSubview(priceLabel)
        contentStack.setCustomSpacing(14, after: priceLabel)

        configurePurchaseButton()
        contentStack.addArrangedSubview(purchaseButton)
        contentStack.setCustomSpacing(4, after: purchaseButton)

        configureRestoreButton()
        contentStack.addArrangedSubview(restoreButton)
        contentStack.setCustomSpacing(10, after: restoreButton)

        configureStatusLabel()
        contentStack.addArrangedSubview(statusLabel)
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
            string: "FLACCY LIFETIME",
            attributes: [
                .font: UIFont.scaled(.caption1, size: 12, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.65),
                .kern: 2.2,
            ]
        )
        captionLabel.adjustsFontForContentSizeCategory = true

        let titleLabel = UILabel()
        titleLabel.text = "Own your music.\nForever."
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

    private func configurePriceLabel() {
        priceLabel.font = .scaled(.headline, size: 17, weight: .semibold)
        priceLabel.adjustsFontForContentSizeCategory = true
        priceLabel.textColor = .white
        priceLabel.textAlignment = .center
        priceLabel.numberOfLines = 0
    }

    private func configurePurchaseButton() {
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = .white
        config.baseForegroundColor = .black
        config.cornerStyle = .capsule
        config.attributedTitle = AttributedString(
            "Unlock Lifetime",
            attributes: AttributeContainer([.font: UIFont.scaled(.headline, size: 17, weight: .bold)])
        )
        purchaseButton.configuration = config
        purchaseButton.heightAnchor.constraint(equalToConstant: 54).isActive = true
        purchaseButton.accessibilityHint = "Buys lifetime access with a one-time purchase"
        purchaseButton.addAction(UIAction { [weak self] _ in
            self?.handlePurchaseTap()
        }, for: .touchUpInside)
    }

    private func configureRestoreButton() {
        var config = UIButton.Configuration.plain()
        config.attributedTitle = AttributedString(
            "Restore Purchases",
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

    private func updatePriceLine() {
        if let product = PurchaseManager.shared.product {
            priceLabel.text = "\(product.displayPrice) · once, forever"
        } else {
            priceLabel.text = "Once, forever"
        }
    }

    private func updateStatusLine() {
        switch PurchaseManager.shared.state {
        case .trial(let daysRemaining):
            statusLabel.text = daysRemaining == 1
                ? "1 day left in your trial"
                : "\(daysRemaining) days left in your trial"
        case .expired:
            statusLabel.text = "Your trial has ended"
        case .purchased:
            statusLabel.text = "Lifetime unlocked. Thank you."
        }
    }

    private func updateControlsForTransactionState() {
        purchaseButton.isEnabled = !isTransacting
        restoreButton.isEnabled = !isTransacting
        purchaseButton.configuration?.showsActivityIndicator = isTransacting
    }

    private func handlePurchaseTap() {
        guard !isTransacting else { return }
        impactMedium.impactOccurred()
        isTransacting = true
        Task {
            defer { isTransacting = false }
            do {
                switch try await PurchaseManager.shared.purchase() {
                case .purchased:
                    notificationFeedback.notificationOccurred(.success)
                    dismiss(animated: true)
                case .pending:
                    presentInfoAlert(
                        title: "Purchase Pending",
                        message: "Your purchase is awaiting approval. Playback unlocks automatically once it completes."
                    )
                case .cancelled:
                    break
                }
            } catch {
                AppLogger.error("Purchase failed: \(error.localizedDescription)", category: .purchases)
                notificationFeedback.notificationOccurred(.error)
                presentInfoAlert(
                    title: "Purchase Failed",
                    message: "The purchase couldn't be completed. Check your connection and try again."
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
                    title: "Nothing to Restore",
                    message: "No previous purchase was found for this Apple Account."
                )
            }
        }
    }

    private func presentInfoAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
