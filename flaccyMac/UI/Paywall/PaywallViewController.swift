import AppKit
import StoreKit

/// The lifetime-unlock paywall, presented as a sheet on the main window: the
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
            symbolName: "menubar.dock.rectangle",
            title: "Menu bar player & folder watching",
            detail: "Control playback from the menu bar; new files appear in your library instantly."
        ),
    ]

    private let backdrop = AmbientBackdropView()
    private let priceLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let purchaseButton = NSButton(title: "Unlock Lifetime", target: nil, action: nil)
    private let restoreButton = NSButton(title: "Restore Purchases", target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    private var isTransacting = false {
        didSet {
            purchaseButton.isEnabled = !isTransacting && purchaseAvailable
            restoreButton.isEnabled = !isTransacting
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
        root.heightAnchor.constraint(equalToConstant: 640).isActive = true

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(backdrop)

        let content = buildContent()
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)

        let closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close") ?? NSImage(),
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
        updatePriceLine()
        Task { [weak self] in
            await PurchaseManager.shared.loadProductIfNeeded()
            self?.updatePriceLine()
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
            string: "FLACCY LIFETIME",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                .foregroundColor: MacColors.secondaryLabel,
                .kern: 2.2,
            ]
        )

        let title = NSTextField(wrappingLabelWithString: "Own your music.\nForever.")
        title.font = .systemFont(ofSize: 32, weight: .heavy)
        title.textColor = MacColors.primaryLabel

        let featureCard = buildFeatureCard()

        priceLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        priceLabel.textColor = MacColors.primaryLabel
        priceLabel.alignment = .center

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

        let privacy = NSButton(title: "Privacy Policy", target: self, action: #selector(openPrivacy))
        privacy.isBordered = false
        privacy.contentTintColor = MacColors.tertiaryLabel
        privacy.font = .systemFont(ofSize: 11)
        let terms = NSButton(title: "Terms of Use", target: self, action: #selector(openTerms))
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
            tile, kicker, title, featureCard, priceLabel, buyRow, restoreButton, statusLabel, legalRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: tile)
        stack.setCustomSpacing(4, after: kicker)
        stack.setCustomSpacing(18, after: title)
        stack.setCustomSpacing(18, after: featureCard)
        stack.setCustomSpacing(10, after: priceLabel)
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

    private func updatePriceLine() {
        if let product = PurchaseManager.shared.product {
            priceLabel.stringValue = "\(product.displayPrice) · once, forever"
            purchaseAvailable = true
        } else {
            priceLabel.stringValue = "$9.99 · once, forever (store unavailable)"
            purchaseAvailable = false
        }
        purchaseButton.isEnabled = purchaseAvailable && !isTransacting
    }

    private func updateStatusLine() {
        switch PurchaseManager.shared.state {
        case .trial(let daysRemaining):
            statusLabel.stringValue = daysRemaining == 1
                ? "1 day left in your trial"
                : "\(daysRemaining) days left in your trial"
        case .expired:
            statusLabel.stringValue = "Your trial has ended"
        case .purchased:
            statusLabel.stringValue = "Lifetime unlocked. Thank you."
        }
    }

    @objc private func purchaseStateDidChange() {
        updateStatusLine()
        if PurchaseManager.shared.state == .purchased, !isTransacting {
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
                switch try await PurchaseManager.shared.purchase() {
                case .purchased:
                    self.closeTapped()
                case .pending:
                    self.presentInfoAlert(
                        title: "Purchase Pending",
                        message: "Your purchase is awaiting approval. Playback unlocks automatically once it completes."
                    )
                case .cancelled:
                    break
                }
            } catch {
                AppLogger.error("Purchase failed: \(error.localizedDescription)", category: .purchases)
                self.presentInfoAlert(
                    title: "Purchase Failed",
                    message: "The purchase couldn't be completed. Check your connection and try again."
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
                    title: "Nothing to Restore",
                    message: "No previous purchase was found for this Apple Account."
                )
            }
        }
    }

    private func presentInfoAlert(title: String, message: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
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
