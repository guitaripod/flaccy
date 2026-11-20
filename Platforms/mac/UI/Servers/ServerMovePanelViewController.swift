import AppKit
import FlaccyCore
import MidgarCore

/// The Mac sheet that moves the songs in this Mac's library that a server also holds to the server's copies: what it would do,
/// the choice between freeing the room and keeping them downloaded, the move with its progress, and what it did.
final class ServerMovePanelViewController: NSViewController {

    private let serverID: String
    private let content = NSStackView()
    private var choice = ServerMoveChoice.stream(keepLoved: true)
    private var observer: NSObjectProtocol?
    private var shownPhase: ServerMoveService.Phase?
    private weak var progressBar: NSProgressIndicator?
    private weak var progressText: NSTextField?
    private var isClosing = false

    init(serverID: String) {
        self.serverID = serverID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setAccessibilityIdentifier("serverMove.sheet")
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(equalToConstant: 460),
        ])
        observer = NotificationCenter.default.addObserver(forName: ServerMoveService.didChange, object: nil, queue: .main) { [weak self] _ in
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

    override func viewDidDisappear() {
        super.viewDidDisappear()
        isClosing = true
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if case .moving = ServerMoveService.shared.phase(for: serverID) { return }
        ServerMoveService.shared.reset(serverID: serverID)
    }

    private var serverName: String {
        (try? DatabaseManager.shared.fetchRemoteServer(id: serverID))?.name ?? serverID
    }

    private func render() {
        guard isViewLoaded else { return }
        let phase = ServerMoveService.shared.phase(for: serverID)
        if case .moving(let done, let total) = phase, case .moving? = shownPhase {
            updateProgress(done: done, total: total)
            shownPhase = phase
            return
        }
        feedback(for: phase)
        shownPhase = phase
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch phase {
        case .idle, .checking:
            if case .idle = phase, !isClosing, view.window != nil {
                Task { await ServerMoveService.shared.prepare(serverID: serverID) }
            }
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            let row = NSStackView(views: [spinner, secondary(ServerMoveCopy.checking(server: serverName))])
            row.orientation = .horizontal
            add(row)
            add(buttons([cancelButton(ServerMoveCopy.notNow)]))
        case .offer(let offer) where offer.songs == 0:
            add(line(ServerMoveCopy.nothing(server: offer.serverName), id: "serverMove.message"))
            add(buttons([defaultButton(ServerMoveCopy.done, id: "serverMove.done") { [weak self] in self?.close() }]))
        case .offer(let offer):
            renderOffer(offer)
        case .unavailable(let reason):
            add(line(reason, id: "serverMove.message"))
            add(buttons([defaultButton(ServerMoveCopy.done, id: "serverMove.done") { [weak self] in self?.close() }]))
        case .moving(let done, let total):
            add(heading(ServerMoveCopy.moving(server: serverName)))
            let bar = NSProgressIndicator()
            bar.style = .bar
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = 1
            bar.setAccessibilityIdentifier("serverMove.progress")
            progressBar = bar
            add(bar)
            let text = secondary("")
            progressText = text
            add(text)
            add(secondary(ServerMoveCopy.closeHint))
            add(buttons([defaultButton(ServerMoveCopy.done, id: "serverMove.close") { [weak self] in self?.dismiss(nil) }]))
            updateProgress(done: done, total: total)
        case .finished(let summary):
            add(heading(ServerMoveCopy.finished(songs: summary.moved, server: summary.serverName)))
            if summary.freedBytes > 0 { add(line(ServerMoveCopy.freed(bytes: summary.freedBytes), id: "serverMove.summary")) }
            if summary.kept > 0 { add(line(ServerMoveCopy.kept(songs: summary.kept), id: "serverMove.summary")) }
            if summary.notKept > 0 { add(line(ServerMoveCopy.notKept(songs: summary.notKept, server: summary.serverName), id: "serverMove.summary")) }
            if summary.staying > 0 { add(line(ServerMoveCopy.staying(songs: summary.staying, server: summary.serverName), id: "serverMove.summary")) }
            add(buttons([defaultButton(ServerMoveCopy.done, id: "serverMove.done") { [weak self] in self?.close() }]))
        case .failed(let message):
            add(heading(ServerMoveCopy.failedTitle))
            add(line(message, id: "serverMove.failure"))
            add(buttons([
                cancelButton(ServerMoveCopy.notNow),
                defaultButton(ServerMoveCopy.tryAgain, id: "serverMove.tryAgain") { [weak self] in
                    guard let self else { return }
                    Task { await ServerMoveService.shared.prepare(serverID: self.serverID) }
                },
            ]))
        }
    }

    private func renderOffer(_ offer: ServerMoveOffer) {
        add(heading(ServerMoveCopy.title(server: offer.serverName)))
        add(line(ServerMoveCopy.lead(songs: offer.songs, server: offer.serverName), id: "serverMove.lead"))
        add(secondary(ServerMoveCopy.promise(server: offer.serverName)))
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
        let freeUp = radio(
            ServerMoveCopy.freeUpTitle(bytes: offer.bytesFreed(by: .stream(keepLoved: streams ? keepsLoved : true))),
            detail: ServerMoveCopy.freeUpDetail(server: offer.serverName), isOn: streams, id: "serverMove.freeUp"
        ) { [weak self] in self?.choose(.stream(keepLoved: streams ? keepsLoved : true)) }
        add(freeUp)
        if streams, offer.lovedSongs > 0 {
            let check = NSButton(checkboxWithTitle: ServerMoveCopy.keepLovedTitle, target: self, action: #selector(keepLovedToggled(_:)))
            check.state = keepsLoved ? .on : .off
            check.setAccessibilityIdentifier("serverMove.keepLoved")
            let detail = secondary(ServerMoveCopy.keepLovedDetail(songs: offer.lovedSongs, bytes: offer.lovedBytes))
            let stack = NSStackView(views: [check, detail])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 0)
            add(stack)
        }
        add(radio(
            ServerMoveCopy.keepTitle, detail: ServerMoveCopy.keepDetail(server: offer.serverName), isOn: !streams, id: "serverMove.keep"
        ) { [weak self] in self?.choose(.keepDownloaded) })
        if offer.staying > 0 { add(secondary(ServerMoveCopy.staying(songs: offer.staying, server: offer.serverName))) }
        add(secondary(ServerMoveCopy.trashNote))
        let move = defaultButton(ServerMoveCopy.moveButton(songs: offer.songs, server: offer.serverName), id: "serverMove.move") { [weak self] in
            guard let self else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            let choice = self.choice
            Task { await ServerMoveService.shared.start(offer, choice: choice) }
        }
        move.isEnabled = !ServerMoveService.shared.isMoving
        add(buttons([cancelButton(ServerMoveCopy.notNow), move]))
    }

    @objc private func keepLovedToggled(_ sender: NSButton) {
        choose(.stream(keepLoved: sender.state == .on))
    }

    private func choose(_ newChoice: ServerMoveChoice) {
        guard newChoice != choice else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        choice = newChoice
        shownPhase = nil
        render()
    }

    private func updateProgress(done: Int, total: Int) {
        progressBar?.doubleValue = total > 0 ? Double(min(done, total)) / Double(total) : 0
        progressText?.stringValue = total > 0 ? ServerMoveCopy.progress(done: done, total: total) : ""
    }

    private func feedback(for phase: ServerMoveService.Phase) {
        switch phase {
        case .finished, .failed: NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        default: break
        }
    }

    private func close() {
        isClosing = true
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        dismiss(nil)
    }

    private func add(_ view: NSView) {
        content.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -48).isActive = true
    }

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.setAccessibilityIdentifier("serverMove.heading")
        return label
    }

    private func line(_ text: String, id: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.setAccessibilityIdentifier(id)
        return label
    }

    private func secondary(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func radio(_ title: String, detail: String, isOn: Bool, id: String, action: @escaping () -> Void) -> NSView {
        let button = PanelButton(title: title, action: action)
        button.setButtonType(.radio)
        button.state = isOn ? .on : .off
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        button.setAccessibilityIdentifier(id)
        button.setAccessibilityHelp(detail)
        let text = secondary(detail)
        let stack = NSStackView(views: [button, text])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        text.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 20).isActive = true
        text.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        return stack
    }

    private func buttons(_ items: [NSButton]) -> NSView {
        let row = NSStackView(views: [NSView()] + items)
        row.orientation = .horizontal
        return row
    }

    private func defaultButton(_ title: String, id: String, action: @escaping () -> Void) -> NSButton {
        let button = PanelButton(title: title, action: action)
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.setAccessibilityIdentifier(id)
        return button
    }

    private func cancelButton(_ title: String) -> NSButton {
        let button = PanelButton(title: title) { [weak self] in self?.close() }
        button.bezelStyle = .rounded
        button.keyEquivalent = "\u{1b}"
        button.setAccessibilityIdentifier("serverMove.notNow")
        return button
    }
}

/// Offers the move once per server on the Mac, right after the server's songs first reach the library and only when it
/// holds songs in this Mac's library, and says what a move did when it finishes while its sheet is closed.
@MainActor
final class MacServerMovePresenter {

    private var observers: [NSObjectProtocol] = []
    private var announced: Set<String> = []

    init() {
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

    private func present(serverID: String, attempt: Int = 0) {
        if NSApp.windows.contains(where: { $0.contentViewController is ServerMovePanelViewController }) {
            ServerMoveOfferLedger.markOffered(serverID)
            return
        }
        let summaryShown = NSApp.windows.contains { $0.isVisible && $0.contentViewController is ServerMergeSummaryPanelViewController }
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow, let host = window.contentViewController, window.attachedSheet == nil,
              !summaryShown, !ServerMergeReporter.shared.isAhead
        else {
            guard attempt < 400 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.present(serverID: serverID, attempt: attempt + 1) }
            return
        }
        guard !ServerMoveOfferLedger.wasOffered(serverID) else { return }
        ServerMoveOfferLedger.markOffered(serverID)
        MidgarLog.info("Offering to play the songs on this Mac from the server", category: .content)
        host.presentAsSheet(ServerMovePanelViewController(serverID: serverID))
    }

    private func announceFinishedMoves() {
        for (serverID, phase) in ServerMoveService.shared.phases {
            guard case .finished(let summary) = phase, !announced.contains(serverID) else { continue }
            announced.insert(serverID)
            let window = NSApp.keyWindow ?? NSApp.mainWindow
            guard !(window?.attachedSheet?.contentViewController is ServerMovePanelViewController) else { continue }
            MacToast.show(ServerMoveCopy.finished(songs: summary.moved, server: summary.serverName), style: .success, in: window)
            ServerMoveService.shared.reset(serverID: serverID)
        }
        announced = announced.filter { serverID in
            if case .finished = ServerMoveService.shared.phase(for: serverID) { true } else { false }
        }
    }
}
