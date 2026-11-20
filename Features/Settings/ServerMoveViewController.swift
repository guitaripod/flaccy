import FlaccyCore
import MidgarCore
import UIKit

/// The sheet that moves the songs on this iPhone or iPad that a server also holds to the server's copies: what it would
/// do, the choice between freeing the room and keeping them downloaded, the move with its progress, and what it did.
final class ServerMoveViewController: UIViewController, UIAdaptivePresentationControllerDelegate {

    private let serverID: String
    private let stack = UIStackView()
    private var choice = ServerMoveChoice.stream(keepLoved: true)
    private var observer: NSObjectProtocol?
    private var lastPhase: ServerMoveService.Phase?
    private var isClosing = false
    private let selection = UISelectionFeedbackGenerator()
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let notification = UINotificationFeedbackGenerator()

    init(serverID: String) {
        self.serverID = serverID
        super.init(nibName: nil, bundle: nil)
        if let sheet = sheetPresentationController {
            sheet.detents = [.custom(identifier: Self.fittingDetent) { [weak self] context in
                min(self?.fittedHeight() ?? context.maximumDetentValue, context.maximumDetentValue)
            }]
            sheet.prefersGrabberVisible = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func present(serverID: String, from presenter: UIViewController) {
        let controller = ServerMoveViewController(serverID: serverID)
        presenter.present(controller, animated: true)
        controller.presentationController?.delegate = controller
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        view.accessibilityIdentifier = "serverMove.sheet"
        layoutStack()
        observer = NotificationCenter.default.addObserver(
            forName: ServerMoveService.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        let service = ServerMoveService.shared
        switch service.phase(for: serverID) {
        case .idle, .failed, .finished, .unavailable, .offer:
            Task { await service.prepare(serverID: serverID) }
        case .checking, .moving:
            break
        }
        render()
    }

    deinit {
        MainActor.assumeIsolated {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        isClosing = true
        ServerMoveService.shared.reset(serverID: serverID)
    }

    private func layoutStack() {
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)
        scroll.addSubview(stack)
        let readable = view.readableContentGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Self.topInset),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Self.bottomInset),
            stack.leadingAnchor.constraint(equalTo: readable.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: readable.trailingAnchor, constant: -8),
        ])
    }

    private func render() {
        let phase = ServerMoveService.shared.phase(for: serverID)
        if let lastPhase, Self.sameScreen(lastPhase, phase), case .moving(let done, let total) = phase {
            updateProgress(done: done, total: total)
            self.lastPhase = phase
            return
        }
        playHaptic(for: phase)
        lastPhase = phase
        isModalInPresentation = false
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch phase {
        case .idle:
            renderChecking()
            if !isClosing, view.window != nil {
                Task { await ServerMoveService.shared.prepare(serverID: serverID) }
            }
        case .checking:
            renderChecking()
        case .offer(let offer) where offer.songs == 0:
            renderMessage(symbol: "checkmark.circle", tint: .secondaryLabel, text: ServerMoveCopy.nothing(server: offer.serverName))
        case .offer(let offer):
            renderOffer(offer)
        case .unavailable(let reason):
            renderMessage(symbol: "info.circle", tint: .secondaryLabel, text: reason)
        case .moving(let done, let total):
            renderMoving(done: done, total: total)
        case .finished(let summary):
            renderFinished(summary)
        case .failed(let message):
            renderFailed(message)
        }
        fitSheet()
        UIAccessibility.post(notification: .screenChanged, argument: stack.arrangedSubviews.first)
    }

    private static let fittingDetent = UISheetPresentationController.Detent.Identifier("serverMove.fitting")
    private static let topInset: CGFloat = 36
    private static let bottomInset: CGFloat = 28

    /// The sheet is as tall as what it says, on a phone and in an iPad's form sheet alike, up to the full height, where it scrolls.
    private func fitSheet() {
        view.layoutIfNeeded()
        if traitCollection.horizontalSizeClass == .regular {
            preferredContentSize = CGSize(width: Self.formSheetWidth, height: fittedHeight())
        }
        guard let sheet = sheetPresentationController else { return }
        sheet.animateChanges { sheet.invalidateDetents() }
    }

    private static let formSheetWidth: CGFloat = 540

    private func fittedHeight() -> CGFloat {
        let margins = view.directionalLayoutMargins.leading + view.directionalLayoutMargins.trailing + 16
        let width = traitCollection.horizontalSizeClass == .regular
            ? Self.formSheetWidth - margins
            : (stack.bounds.width > 0 ? stack.bounds.width : view.readableContentGuide.layoutFrame.width - 16)
        let size = stack.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        )
        return ceil(size.height) + Self.topInset + Self.bottomInset + max(view.safeAreaInsets.bottom, 12)
    }

    private static func sameScreen(_ a: ServerMoveService.Phase, _ b: ServerMoveService.Phase) -> Bool {
        if case .moving = a, case .moving = b { return true }
        return false
    }

    private func playHaptic(for phase: ServerMoveService.Phase) {
        switch phase {
        case .finished: notification.notificationOccurred(.success)
        case .failed: notification.notificationOccurred(.error)
        default: break
        }
    }

    private var serverName: String {
        (try? DatabaseManager.shared.fetchRemoteServer(id: serverID))?.name ?? serverID
    }

    private func renderChecking() {
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.startAnimating()
        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(label(ServerMoveCopy.checking(server: serverName), style: .body, color: .secondaryLabel, centered: true))
    }

    private func renderOffer(_ offer: ServerMoveOffer) {
        stack.addArrangedSubview(badge(symbol: "server.rack", tint: .systemIndigo))
        stack.addArrangedSubview(heading(ServerMoveCopy.title(server: offer.serverName)))
        stack.addArrangedSubview(label(ServerMoveCopy.lead(songs: offer.songs, server: offer.serverName), style: .body))
        stack.addArrangedSubview(label(ServerMoveCopy.promise(server: offer.serverName), style: .subheadline, color: .secondaryLabel))
        stack.setCustomSpacing(24, after: stack.arrangedSubviews.last!)

        let streams: Bool
        let keepsLoved: Bool
        switch choice {
        case .stream(let keepLoved):
            streams = true
            keepsLoved = keepLoved
        case .keepDownloaded:
            streams = false
            keepsLoved = false
        }
        let freeUp = ServerMoveOptionCard(
            title: ServerMoveCopy.freeUpTitle(bytes: offer.bytesFreed(by: .stream(keepLoved: streams ? keepsLoved : true))),
            detail: ServerMoveCopy.freeUpDetail(server: offer.serverName),
            isSelected: streams
        )
        freeUp.accessibilityIdentifier = "serverMove.freeUp"
        freeUp.addAction(UIAction { [weak self] _ in self?.choose(.stream(keepLoved: keepsLoved || !streams)) }, for: .touchUpInside)
        if streams, offer.lovedSongs > 0 {
            freeUp.addFooter(keepLovedSwitch(offer, isOn: keepsLoved))
        }
        stack.addArrangedSubview(freeUp)

        let keep = ServerMoveOptionCard(
            title: ServerMoveCopy.keepTitle,
            detail: ServerMoveCopy.keepDetail(server: offer.serverName),
            isSelected: !streams
        )
        keep.accessibilityIdentifier = "serverMove.keep"
        keep.addAction(UIAction { [weak self] _ in self?.choose(.keepDownloaded) }, for: .touchUpInside)
        stack.addArrangedSubview(keep)

        if offer.staying > 0 {
            stack.addArrangedSubview(label(ServerMoveCopy.staying(songs: offer.staying, server: offer.serverName), style: .footnote, color: .secondaryLabel))
        }
        stack.setCustomSpacing(28, after: stack.arrangedSubviews.last!)
        let move = filledButton(ServerMoveCopy.moveButton(songs: offer.songs, server: offer.serverName), identifier: "serverMove.move") { [weak self] in
            guard let self else { return }
            self.impact.impactOccurred()
            let choice = self.choice
            Task { await ServerMoveService.shared.start(offer, choice: choice) }
        }
        move.isEnabled = !ServerMoveService.shared.isMoving
        stack.addArrangedSubview(move)
        stack.addArrangedSubview(plainButton(ServerMoveCopy.notNow, identifier: "serverMove.notNow") { [weak self] in
            self?.close()
        })
    }

    private func keepLovedSwitch(_ offer: ServerMoveOffer, isOn: Bool) -> UIView {
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.accessibilityIdentifier = "serverMove.keepLoved"
        toggle.addAction(UIAction { [weak self, weak toggle] _ in
            guard let toggle else { return }
            self?.choose(.stream(keepLoved: toggle.isOn))
        }, for: .valueChanged)
        let title = label(ServerMoveCopy.keepLovedTitle, style: .subheadline)
        let detail = label(ServerMoveCopy.keepLovedDetail(songs: offer.lovedSongs, bytes: offer.lovedBytes), style: .footnote, color: .secondaryLabel)
        let texts = UIStackView(arrangedSubviews: [title, detail])
        texts.axis = .vertical
        texts.spacing = 2
        let row = UIStackView(arrangedSubviews: [texts, toggle])
        row.alignment = .center
        row.spacing = 12
        toggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        toggle.accessibilityLabel = ServerMoveCopy.keepLovedTitle
        toggle.accessibilityValue = ServerMoveCopy.keepLovedDetail(songs: offer.lovedSongs, bytes: offer.lovedBytes)
        return row
    }

    private func choose(_ newChoice: ServerMoveChoice) {
        guard newChoice != choice else { return }
        selection.selectionChanged()
        choice = newChoice
        lastPhase = nil
        render()
    }

    private func renderMoving(done: Int, total: Int) {
        isModalInPresentation = false
        stack.addArrangedSubview(badge(symbol: "arrow.triangle.2.circlepath", tint: .systemIndigo))
        stack.addArrangedSubview(heading(ServerMoveCopy.moving(server: serverName)))
        let bar = UIProgressView(progressViewStyle: .default)
        bar.tag = Self.progressTag
        bar.accessibilityIdentifier = "serverMove.progress"
        stack.addArrangedSubview(bar)
        let detail = label("", style: .subheadline, color: .secondaryLabel)
        detail.tag = Self.progressTextTag
        stack.addArrangedSubview(detail)
        stack.addArrangedSubview(label(ServerMoveCopy.closeHint, style: .footnote, color: .tertiaryLabel))
        updateProgress(done: done, total: total)
    }

    private static let progressTag = 41
    private static let progressTextTag = 42

    private func updateProgress(done: Int, total: Int) {
        let fraction = total > 0 ? Float(min(done, total)) / Float(total) : 0
        (stack.viewWithTag(Self.progressTag) as? UIProgressView)?.setProgress(fraction, animated: true)
        let text = total > 0 ? ServerMoveCopy.progress(done: done, total: total) : ""
        if let detail = stack.viewWithTag(Self.progressTextTag) as? UILabel, detail.text != text {
            detail.text = text
            detail.accessibilityTraits = [.staticText, .updatesFrequently]
        }
    }

    private func renderFinished(_ summary: ServerMoveSummary) {
        stack.addArrangedSubview(badge(symbol: "checkmark.circle.fill", tint: .systemGreen))
        stack.addArrangedSubview(heading(ServerMoveCopy.finished(songs: summary.moved, server: summary.serverName)))
        var lines: [String] = []
        if summary.freedBytes > 0 { lines.append(ServerMoveCopy.freed(bytes: summary.freedBytes)) }
        if summary.kept > 0 { lines.append(ServerMoveCopy.kept(songs: summary.kept)) }
        if summary.notKept > 0 { lines.append(ServerMoveCopy.notKept(songs: summary.notKept, server: summary.serverName)) }
        if summary.staying > 0 { lines.append(ServerMoveCopy.staying(songs: summary.staying, server: summary.serverName)) }
        for line in lines {
            stack.addArrangedSubview(label(line, style: .body, identifier: "serverMove.summary"))
        }
        stack.setCustomSpacing(28, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(filledButton(ServerMoveCopy.done, identifier: "serverMove.done") { [weak self] in self?.close() })
    }

    private func renderFailed(_ message: String) {
        stack.addArrangedSubview(badge(symbol: "exclamationmark.triangle.fill", tint: .systemOrange))
        stack.addArrangedSubview(heading(ServerMoveCopy.failedTitle))
        stack.addArrangedSubview(label(message, style: .body, identifier: "serverMove.failure"))
        stack.setCustomSpacing(28, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(filledButton(ServerMoveCopy.tryAgain, identifier: "serverMove.tryAgain") { [weak self] in
            guard let self else { return }
            self.impact.impactOccurred()
            Task { await ServerMoveService.shared.prepare(serverID: self.serverID) }
        })
        stack.addArrangedSubview(plainButton(ServerMoveCopy.notNow, identifier: "serverMove.notNow") { [weak self] in self?.close() })
    }

    private func renderMessage(symbol: String, tint: UIColor, text: String) {
        stack.addArrangedSubview(badge(symbol: symbol, tint: tint))
        stack.addArrangedSubview(label(text, style: .body, centered: true, identifier: "serverMove.message"))
        stack.setCustomSpacing(28, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(filledButton(ServerMoveCopy.done, identifier: "serverMove.done") { [weak self] in self?.close() })
    }

    private func close() {
        isClosing = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if case .moving = ServerMoveService.shared.phase(for: serverID) {} else {
            ServerMoveService.shared.reset(serverID: serverID)
        }
        dismiss(animated: true)
    }

    private func badge(symbol: String, tint: UIColor) -> UIView {
        let configuration = UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold)
        let image = UIImageView(image: UIImage(systemName: symbol, withConfiguration: configuration))
        image.tintColor = tint
        image.contentMode = .center
        image.translatesAutoresizingMaskIntoConstraints = false
        let circle = UIView()
        circle.backgroundColor = tint.withAlphaComponent(0.14)
        circle.layer.cornerRadius = 32
        circle.translatesAutoresizingMaskIntoConstraints = false
        circle.addSubview(image)
        let holder = UIView()
        holder.addSubview(circle)
        holder.isAccessibilityElement = false
        NSLayoutConstraint.activate([
            circle.widthAnchor.constraint(equalToConstant: 64),
            circle.heightAnchor.constraint(equalToConstant: 64),
            circle.topAnchor.constraint(equalTo: holder.topAnchor),
            circle.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            circle.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            image.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
        ])
        return holder
    }

    private func heading(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        let descriptor = UIFont.preferredFont(forTextStyle: .title2).fontDescriptor
        label.font = UIFont(descriptor: descriptor.withSymbolicTraits(.traitBold) ?? descriptor, size: 0)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.accessibilityTraits = .header
        label.accessibilityIdentifier = "serverMove.heading"
        return label
    }

    private func label(
        _ text: String, style: UIFont.TextStyle, color: UIColor = .label, centered: Bool = false, identifier: String? = nil
    ) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        label.textAlignment = centered ? .center : .natural
        label.accessibilityIdentifier = identifier
        return label
    }

    private func filledButton(_ title: String, identifier: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.cornerStyle = .large
        configuration.buttonSize = .large
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.accessibilityIdentifier = identifier
        button.titleLabel?.numberOfLines = 0
        return button
    }

    private func plainButton(_ title: String, identifier: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.buttonSize = .large
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.accessibilityIdentifier = identifier
        return button
    }
}

/// One of the two ways to move: a card with a title, a line about it, a mark when chosen, and room for a switch beneath.
final class ServerMoveOptionCard: UIControl {

    private let content = UIStackView()

    init(title: String, detail: String, isSelected: Bool) {
        super.init(frame: .zero)
        self.isSelected = isSelected
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        layer.borderWidth = isSelected ? 2 : 0
        layer.borderColor = UIColor.tintColor.cgColor
        let titleLabel = UILabel()
        titleLabel.text = title
        let descriptor = UIFont.preferredFont(forTextStyle: .headline).fontDescriptor
        titleLabel.font = UIFont(descriptor: descriptor, size: 0)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        let detailLabel = UILabel()
        detailLabel.text = detail
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0
        let mark = UIImageView(image: UIImage(systemName: isSelected ? "checkmark.circle.fill" : "circle"))
        mark.tintColor = isSelected ? .tintColor : .tertiaryLabel
        mark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title3)
        mark.setContentHuggingPriority(.required, for: .horizontal)
        let texts = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        texts.axis = .vertical
        texts.spacing = 4
        let header = UIStackView(arrangedSubviews: [texts, mark])
        header.alignment = .top
        header.spacing = 12
        header.isUserInteractionEnabled = false
        content.axis = .vertical
        content.spacing = 14
        content.addArrangedSubview(header)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
        isAccessibilityElement = false
        header.isAccessibilityElement = true
        header.accessibilityLabel = title
        header.accessibilityValue = detail
        header.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func addFooter(_ footer: UIView) {
        let divider = UIView()
        divider.backgroundColor = .separator
        divider.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1)).isActive = true
        content.addArrangedSubview(divider)
        content.addArrangedSubview(footer)
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.7 : 1 }
    }
}

/// Offers the move once per server, right after the server's songs first reach the library and only when it holds songs
/// that are on this device, and says what a move did when it finishes while its sheet is closed.
@MainActor
final class ServerMovePresenter {

    private weak var window: UIWindow?
    private var observers: [NSObjectProtocol] = []
    private var announced: Set<String> = []

    init(window: UIWindow?) {
        self.window = window
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: RemoteCatalogSync.firstSyncDidFinish, object: nil, queue: .main) { [weak self] note in
            guard let serverID = note.object as? String else { return }
            MainActor.assumeIsolated { self?.offerOnce(serverID: serverID) }
        })
        observers.append(center.addObserver(forName: ServerMoveService.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.announceFinishedMoves() }
        })
    }

    private func offerOnce(serverID: String) {
        guard !ServerMoveOfferLedger.wasOffered(serverID), !ServerMoveService.shared.isMoving else { return }
        Task {
            guard let offer = await ServerMoveService.shared.quietOffer(serverID: serverID) else { return }
            ServerMoveService.shared.show(offer)
            present(serverID: serverID)
        }
    }

    /// Lets the merge summary of the same connection go first: the offer waits while the first sync settles, while the summary
    /// waits to be shown and while it is on screen, then opens over whatever the person is looking at.
    private func present(serverID: String, attempt: Int = 0) {
        guard let top = TrialRunwayPresenter.topmostViewController(in: window) else { return }
        if top is ServerMoveViewController {
            ServerMoveOfferLedger.markOffered(serverID)
            return
        }
        let waiting = top.isBeingDismissed || top.isBeingPresented || top is ServerMergeSummaryViewController
            || ServerMergeReporter.shared.isAhead
        guard !waiting else {
            guard attempt < 400 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.present(serverID: serverID, attempt: attempt + 1) }
            return
        }
        guard !ServerMoveOfferLedger.wasOffered(serverID) else { return }
        ServerMoveOfferLedger.markOffered(serverID)
        MidgarLog.info("Offering to play the songs on this device from the server", category: .content)
        ServerMoveViewController.present(serverID: serverID, from: top)
    }

    private func announceFinishedMoves() {
        for (serverID, phase) in ServerMoveService.shared.phases {
            guard case .finished(let summary) = phase, !announced.contains(serverID) else { continue }
            announced.insert(serverID)
            guard let top = TrialRunwayPresenter.topmostViewController(in: window), !(top is ServerMoveViewController) else { continue }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            ToastView.show(ServerMoveCopy.finished(songs: summary.moved, server: summary.serverName), in: top.view, style: .success)
            ServerMoveService.shared.reset(serverID: serverID)
        }
        announced = announced.filter { serverID in
            if case .finished = ServerMoveService.shared.phase(for: serverID) { true } else { false }
        }
    }
}
