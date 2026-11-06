import MidgarCore
import UIKit

/// Wi-Fi Transfer: the address to open on a computer, three steps, and what is arriving. The fastest way in for music
/// that lives on a computer, because the computer needs nothing but a web browser. The screen keeps the iPhone awake
/// while it is open, since a locked phone stops receiving.
final class WiFiTransferViewController: UIViewController {

    /// Called when the person taps Done or connects Flaccy Server from here; a sheet that has no handler dismisses itself.
    var onDone: (() -> Void)?

    private let offersFlaccyServer: Bool
    private let session = WiFiTransferSession()
    private let scrollView = UIScrollView()
    private let addressCaption = WiFiTransferViewController.label(WiFiTransferCopy.openThis, style: .subheadline, color: .secondaryLabel)
    private let addressLabel = UILabel()
    private let copyButton = UIButton(configuration: .gray())
    private let shareButton = UIButton(configuration: .gray())
    private let addressButtons = UIStackView()
    private let statusIcon = UIImageView()
    private let statusSpinner = UIActivityIndicatorView(style: .medium)
    private let statusTitle = WiFiTransferViewController.label("", style: .headline)
    private let statusDetail = WiFiTransferViewController.label("", style: .subheadline, color: .secondaryLabel)
    private let statusProgress = UIProgressView(progressViewStyle: .default)
    private let playButton = UIButton(configuration: .filled())
    private var foregroundObserver: NSObjectProtocol?

    init(offersFlaccyServer: Bool) {
        self.offersFlaccyServer = offersFlaccyServer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Opens Wi-Fi Transfer as a sheet over `presenter`.
    static func present(from presenter: UIViewController) {
        let navigation = UINavigationController(rootViewController: WiFiTransferViewController(offersFlaccyServer: true))
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.prefersGrabberVisible = true
        presenter.present(navigation, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.finish() }
        )
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "wifiTransfer.done"
        buildContent()
        session.presenter = self
        session.onChange = { [weak self] state in self?.render(state) }
        render(session.state)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.session.resume() }
        }
        FunnelSignals.shared.noteWiFiTransferOpened()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        session.start()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || isMovingFromParent || navigationController?.isBeingDismissed == true else { return }
        UIApplication.shared.isIdleTimerDisabled = false
        session.close()
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        foregroundObserver = nil
    }

    private func finish() {
        if let onDone {
            onDone()
        } else {
            dismiss(animated: true)
        }
    }

    private func buildContent() {
        let icon = UIImageView(image: UIImage(systemName: "wifi"))
        icon.tintColor = .tintColor
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold)
        icon.contentMode = .center
        icon.isAccessibilityElement = false

        let title = Self.label(WiFiTransferCopy.title, style: .title1, weight: .bold)
        title.textAlignment = .center
        title.accessibilityTraits = .header
        let subtitle = Self.label(WiFiTransferCopy.subtitle, style: .body, color: .secondaryLabel)
        subtitle.textAlignment = .center

        var arranged: [UIView] = [icon, title, subtitle, makeAddressCard(), makeSteps(), makeStatusCard()]
        if offersFlaccyServer { arranged.append(makeServerFooter()) }

        let stack = UIStackView(arrangedSubviews: arranged)
        stack.axis = .vertical
        stack.spacing = 20
        stack.setCustomSpacing(12, after: icon)
        stack.setCustomSpacing(6, after: title)
        stack.setCustomSpacing(28, after: subtitle)
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 20, bottom: 32, trailing: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)
        scrollView.addSubview(stack)
        let readable = stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        readable.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.frameLayoutGuide.trailingAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            readable,
        ])
    }

    private func makeAddressCard() -> UIView {
        addressLabel.font = UIFontMetrics(forTextStyle: .title2).scaledFont(
            for: .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .title2).pointSize, weight: .semibold)
        )
        addressLabel.adjustsFontForContentSizeCategory = true
        addressLabel.adjustsFontSizeToFitWidth = true
        addressLabel.minimumScaleFactor = 0.5
        addressLabel.numberOfLines = 1
        addressLabel.textAlignment = .center
        addressLabel.accessibilityIdentifier = "wifiTransfer.address"
        addressCaption.textAlignment = .center

        copyButton.configuration?.title = WiFiTransferCopy.copy
        copyButton.configuration?.image = UIImage(systemName: "doc.on.doc")
        copyButton.configuration?.imagePadding = 6
        copyButton.configuration?.cornerStyle = .capsule
        copyButton.addAction(UIAction { [weak self] _ in self?.copyAddress() }, for: .touchUpInside)

        shareButton.configuration?.title = WiFiTransferCopy.share
        shareButton.configuration?.image = UIImage(systemName: "square.and.arrow.up")
        shareButton.configuration?.imagePadding = 6
        shareButton.configuration?.cornerStyle = .capsule
        shareButton.addAction(UIAction { [weak self] _ in self?.shareAddress() }, for: .touchUpInside)

        addressButtons.addArrangedSubview(copyButton)
        addressButtons.addArrangedSubview(shareButton)
        addressButtons.spacing = 10
        addressButtons.distribution = .fillEqually

        let content = UIStackView(arrangedSubviews: [addressCaption, addressLabel, addressButtons])
        content.axis = .vertical
        content.spacing = 12
        return Self.card(content)
    }

    private func makeSteps() -> UIView {
        let steps = [WiFiTransferCopy.stepNetwork, WiFiTransferCopy.stepBrowser, WiFiTransferCopy.stepDrop]
        let rows = steps.enumerated().map { index, text -> UIView in
            let number = UILabel()
            number.text = "\(index + 1)"
            number.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15, weight: .bold))
            number.adjustsFontForContentSizeCategory = true
            number.textColor = .tintColor
            number.textAlignment = .center
            number.backgroundColor = .tintColor.withAlphaComponent(0.14)
            number.layer.cornerRadius = 13
            number.layer.masksToBounds = true
            number.isAccessibilityElement = false
            NSLayoutConstraint.activate([
                number.widthAnchor.constraint(equalToConstant: 26),
                number.heightAnchor.constraint(equalToConstant: 26),
            ])
            let body = Self.label(text, style: .body)
            let row = UIStackView(arrangedSubviews: [number, body])
            row.spacing = 12
            row.alignment = .firstBaseline
            row.isAccessibilityElement = true
            row.accessibilityLabel = "\(index + 1). \(text)"
            return row
        }
        let stack = UIStackView(arrangedSubviews: rows)
        stack.axis = .vertical
        stack.spacing = 14
        return stack
    }

    private func makeStatusCard() -> UIView {
        statusIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title3)
        statusIcon.contentMode = .scaleAspectFit
        statusIcon.setContentHuggingPriority(.required, for: .horizontal)
        statusSpinner.hidesWhenStopped = true
        let leading = UIStackView(arrangedSubviews: [statusSpinner, statusIcon])
        leading.setContentHuggingPriority(.required, for: .horizontal)
        let text = UIStackView(arrangedSubviews: [statusTitle, statusDetail])
        text.axis = .vertical
        text.spacing = 2
        let top = UIStackView(arrangedSubviews: [leading, text])
        top.spacing = 12
        top.alignment = .center
        playButton.configuration?.title = String(localized: "Play")
        playButton.configuration?.image = UIImage(systemName: "play.fill")
        playButton.configuration?.imagePadding = 6
        playButton.configuration?.cornerStyle = .capsule
        playButton.accessibilityIdentifier = "wifiTransfer.play"
        playButton.addAction(UIAction { [weak self] _ in self?.playImported() }, for: .touchUpInside)
        playButton.isHidden = true
        let content = UIStackView(arrangedSubviews: [top, statusProgress, playButton])
        content.axis = .vertical
        content.spacing = 12
        let card = Self.card(content)
        card.accessibilityIdentifier = "wifiTransfer.status"
        return card
    }

    private func makeServerFooter() -> UIView {
        let prompt = Self.label(WiFiTransferCopy.serverPrompt, style: .footnote, color: .secondaryLabel)
        prompt.textAlignment = .center
        var configuration = UIButton.Configuration.plain()
        configuration.title = WiFiTransferCopy.serverButton
        configuration.image = UIImage(systemName: "server.rack")
        configuration.imagePadding = 6
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.showFlaccyServer() })
        button.accessibilityIdentifier = "wifiTransfer.server"
        let stack = UIStackView(arrangedSubviews: [prompt, button])
        stack.axis = .vertical
        stack.spacing = 2
        return stack
    }

    private func render(_ state: WiFiTransferSession.State) {
        let address = state.address
        addressLabel.text = address.map(Self.typeable) ?? "—"
        addressCaption.text = state.isOffline ? WiFiTransferCopy.offline : WiFiTransferCopy.openThis
        addressLabel.isHidden = state.isOffline
        addressButtons.isHidden = address == nil
        renderStatus(state)
    }

    private func renderStatus(_ state: WiFiTransferSession.State) {
        let received = state.received > 0 ? WiFiTransferCopy.received(state.received) : nil
        statusProgress.isHidden = true
        playButton.isHidden = true
        if state.listenerFailed {
            showStatus(symbol: "exclamationmark.triangle.fill", tint: .systemOrange, title: WiFiTransferCopy.listenerFailed, detail: nil)
            return
        }
        if state.outOfSpace {
            showStatus(symbol: "externaldrive.badge.exclamationmark", tint: .systemOrange, title: WiFiTransferCopy.outOfSpace, detail: received)
            return
        }
        switch state.activity {
        case .idle:
            if state.isOffline {
                showStatus(symbol: "wifi.slash", tint: .secondaryLabel, title: WiFiTransferCopy.offline, detail: nil)
            } else {
                showStatus(symbol: nil, tint: nil, title: WiFiTransferCopy.waiting, detail: nil)
            }
        case .receiving(let fileName, let fraction):
            showStatus(symbol: "arrow.down.circle.fill", tint: .tintColor, title: WiFiTransferCopy.receiving(fileName), detail: received)
            statusProgress.isHidden = false
            statusProgress.setProgress(Float(fraction), animated: true)
        case .importing(let count):
            showStatus(symbol: nil, tint: nil, title: WiFiTransferCopy.adding(count), detail: received)
        case .reported(let message, let isFailure, let playable):
            showStatus(
                symbol: isFailure ? "exclamationmark.circle.fill" : "checkmark.circle.fill",
                tint: isFailure ? .systemOrange : .systemGreen, title: message, detail: received
            )
            playButton.isHidden = playable == 0
        }
    }

    /// A symbol, or the spinner when `symbol` is nil, beside a title and an optional detail.
    private func showStatus(symbol: String?, tint: UIColor?, title: String, detail: String?) {
        if let symbol {
            statusSpinner.stopAnimating()
            statusIcon.image = UIImage(systemName: symbol)
            statusIcon.tintColor = tint
            statusIcon.isHidden = false
        } else {
            statusIcon.isHidden = true
            statusSpinner.startAnimating()
        }
        statusTitle.text = title
        statusDetail.text = detail
        statusDetail.isHidden = detail == nil
    }

    /// The address as a person types it: browsers add `http://` themselves, and a shorter line stays on one line.
    private static func typeable(_ address: String) -> String {
        var shown = address
        if shown.hasPrefix("http://") { shown.removeFirst("http://".count) }
        if shown.hasSuffix("/") { shown.removeLast() }
        return shown
    }

    /// Plays what just arrived and closes, so the first thing after the transfer is the music itself.
    private func playImported() {
        let tracks = session.lastImported
        guard !tracks.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        AudioPlayer.shared.play(tracks, startingAt: 0)
        MidgarLog.info("Wi-Fi Transfer played \(tracks.count) imported songs", category: .ui)
        finish()
    }

    private func copyAddress() {
        guard let address = session.state.address else { return }
        UIPasteboard.general.string = address
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        copyButton.configuration?.title = WiFiTransferCopy.copied
        copyButton.configuration?.image = UIImage(systemName: "checkmark")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.copyButton.configuration?.title = WiFiTransferCopy.copy
            self?.copyButton.configuration?.image = UIImage(systemName: "doc.on.doc")
        }
    }

    /// AirDrop to a Mac opens the link there at once; Messages or Mail reach any other computer.
    private func shareAddress() {
        guard let address = session.state.address, let url = URL(string: address) else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = shareButton
        present(sheet, animated: true)
    }

    private func showFlaccyServer() {
        let guide = ServerSetupGuideViewController()
        guide.onConnected = { [weak self] in self?.finish() }
        navigationController?.pushViewController(guide, animated: true)
    }

    private static func card(_ content: UIView) -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])
        return card
    }

    private static func label(_ text: String, style: UIFont.TextStyle, weight: UIFont.Weight? = nil, color: UIColor = .label) -> UILabel {
        WelcomeViewController.label(text, style: style, weight: weight, color: color)
    }
}
