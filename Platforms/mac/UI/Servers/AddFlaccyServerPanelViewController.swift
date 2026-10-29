import AppKit
import FlaccyCore
import MidgarCore

/// The Add Flaccy Server sheet of docs/server/UX.md section 3 on the Mac: paste or drop the link the server printed, or type the
/// address and the code, then Connect. A link only fills the fields in; nothing connects without a click.
final class AddFlaccyServerPanelViewController: NSViewController, NSTextFieldDelegate {

    var onAddAsRegularServer: ((String) -> Void)?
    var onOpenSubsonicLink: ((ServerLink) -> Void)?

    private let model: AddFlaccyServerViewModel
    private let addressField = NSTextField()
    private let codeField = NSTextField()
    private let statusIcon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let statusTitle = NSTextField(wrappingLabelWithString: "")
    private let statusBody = NSTextField(wrappingLabelWithString: "")
    private let pasteButton = NSButton(title: String(localized: "Paste Link"), target: nil, action: nil)
    private let statusRow = NSStackView()
    private let buttonRow = NSStackView()
    private var formViews: [NSView] = []
    private var announcedState: AddFlaccyServerViewModel.State = .idle

    init(model: AddFlaccyServerViewModel = AddFlaccyServerViewModel(), link: FlaccyServerLink? = nil) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        if let link { model.apply(link: link) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let drop = LinkDropView()
        drop.onLink = { [weak self] link in self?.take(link) }
        view = drop
        view.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: String(localized: "Add Flaccy Server"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.setAccessibilityRole(.staticText)
        let hint = NSTextField(wrappingLabelWithString: String(localized: "Paste or drop the flaccy://server link your server printed, or type its address and code."))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        pasteButton.target = self
        pasteButton.action = #selector(pasteLink)
        pasteButton.bezelStyle = .rounded
        pasteButton.setAccessibilityIdentifier("addFlaccyServer.paste")

        let typeLabel = NSTextField(labelWithString: String(localized: "Type it instead").uppercased())
        typeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        typeLabel.textColor = .secondaryLabelColor
        configure(addressField, placeholder: String(localized: "arch or 100.91.211.44"), id: "addFlaccyServer.address", label: String(localized: "Address"))
        configure(codeField, placeholder: String(localized: "ABCD-EFGH-\u{2026}"), id: "addFlaccyServer.code", label: String(localized: "Code"))
        let grid = NSGridView(views: [
            [label(String(localized: "Address")), addressField],
            [label(String(localized: "Code")), codeField],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 320

        statusIcon.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        statusIcon.setContentHuggingPriority(.required, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        statusTitle.setAccessibilityIdentifier("addFlaccyServer.status")
        statusBody.font = .systemFont(ofSize: 12)
        statusBody.textColor = .secondaryLabelColor
        let text = NSStackView(views: [statusTitle, statusBody])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        statusRow.setViews([statusIcon, spinner, text], in: .leading)
        statusRow.orientation = .horizontal
        statusRow.alignment = .top
        statusRow.spacing = 8

        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.setHuggingPriority(.required, for: .vertical)
        statusRow.setHuggingPriority(.required, for: .vertical)

        formViews = [hint, pasteButton, typeLabel, grid]
        let stack = NSStackView(views: [title, hint, pasteButton, typeLabel, grid, statusRow, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(equalToConstant: 480),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
        ])
        model.onChange = { [weak self] in self?.render() }
        addressField.stringValue = model.address
        codeField.stringValue = model.code
        render()
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func configure(_ field: NSTextField, placeholder: String, id: String, label: String) {
        field.placeholderString = placeholder
        field.delegate = self
        field.lineBreakMode = .byTruncatingTail
        field.setAccessibilityIdentifier(id)
        field.setAccessibilityLabel(label)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === addressField {
            model.address = field.stringValue
        } else if field === codeField {
            model.code = field.stringValue
            if codeField.stringValue != model.code { codeField.stringValue = model.code }
        }
    }

    private func take(_ link: ParsedServerLink) {
        switch link {
        case .flaccyServer(let flaccy):
            model.apply(link: flaccy)
            addressField.stringValue = model.address
            codeField.stringValue = model.code
            render()
        case .subsonic(let subsonic):
            dismiss(nil)
            onOpenSubsonicLink?(subsonic)
        }
    }

    @objc private func pasteLink() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        guard let link = ParsedServerLink(text: NSPasteboard.general.string(forType: .string) ?? "") else {
            NSSound.beep()
            showStatus(
                symbol: "exclamationmark.triangle.fill", tint: .systemRed,
                title: String(localized: "The clipboard doesn\u{2019}t hold a Flaccy Server link. Copy the flaccy://server link the server printed, then try again."),
                body: nil
            )
            return
        }
        take(link)
    }

    private func render() {
        let state = model.state
        let isConnected = model.isConnected
        formViews.forEach { $0.isHidden = isConnected }
        addressField.isEnabled = !model.isChecking
        codeField.isEnabled = !model.isChecking
        pasteButton.isEnabled = !model.isChecking
        renderStatus(state)
        renderButtons(state)
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
        DispatchQueue.main.async { [weak self] in self?.fitSheetToContent() }
        guard state != announcedState else { return }
        announcedState = state
        announce(state)
    }

    /// Shrinks or grows the sheet to its content, keeping its top edge where it is, since a sheet does not follow the content by itself.
    private func fitSheetToContent() {
        guard let window = view.window else { return }
        let content = view.fittingSize
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        guard abs(frame.height - window.frame.height) > 1 else { return }
        window.setFrame(frame, display: true, animate: false)
    }

    private func renderStatus(_ state: AddFlaccyServerViewModel.State) {
        spinner.stopAnimation(nil)
        switch state {
        case .idle:
            hideStatus()
        case .checking(let server):
            showStatus(symbol: nil, tint: .secondaryLabelColor, title: Self.checkingTitle(server), body: nil)
            spinner.startAnimation(nil)
        case .connected(let info):
            showStatus(
                symbol: "checkmark.circle.fill", tint: .systemGreen, title: Self.connectedTitle(info.serverName),
                body: info.libraryAdded ? Self.connectedBody : Self.connectedWithoutMusicBody
            )
        case .failed(let copy):
            showStatus(symbol: "exclamationmark.triangle.fill", tint: .systemRed, title: copy.title, body: copy.body)
        }
    }

    private func hideStatus() {
        statusIcon.isHidden = true
        spinner.isHidden = true
        statusTitle.stringValue = ""
        statusBody.stringValue = ""
        statusRow.isHidden = true
    }

    private func showStatus(symbol: String?, tint: NSColor, title: String, body: String?) {
        statusRow.isHidden = false
        statusIcon.isHidden = symbol == nil
        statusIcon.image = symbol.flatMap { MacSymbolImage.image($0) }
        statusIcon.contentTintColor = tint
        spinner.isHidden = symbol != nil
        statusTitle.stringValue = title
        statusBody.stringValue = body ?? ""
        statusBody.isHidden = body == nil
    }

    private func renderButtons(_ state: AddFlaccyServerViewModel.State) {
        buttonRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch state {
        case .idle, .checking:
            buttonRow.addArrangedSubview(NSView())
            buttonRow.addArrangedSubview(makeButton(String(localized: "Cancel"), id: "addFlaccyServer.cancel", key: "\u{1b}") { [weak self] in self?.dismiss(nil) })
            let connect = makeButton(String(localized: "Connect"), id: "addFlaccyServer.connect", key: "\r") { [weak self] in self?.connectTapped() }
            connect.isEnabled = model.canConnect
            buttonRow.addArrangedSubview(connect)
        case .connected:
            buttonRow.addArrangedSubview(NSView())
            buttonRow.addArrangedSubview(makeButton(String(localized: "Done"), id: "addFlaccyServer.done", key: "\r") { [weak self] in self?.dismiss(nil) })
        case .failed(let copy):
            buttonRow.addArrangedSubview(NSView())
            for (index, button) in copy.buttons.enumerated() {
                let key = index == copy.buttons.count - 1 ? "\r" : ""
                buttonRow.addArrangedSubview(makeButton(button.title, id: "addFlaccyServer.failure.\(index)", key: key) { [weak self] in
                    self?.failureTapped(copy, button.action)
                })
            }
        }
    }

    private func makeButton(_ title: String, id: String, key: String, action: @escaping () -> Void) -> NSButton {
        let button = PanelButton(title: title, action: action)
        button.bezelStyle = .rounded
        button.keyEquivalent = key
        button.setAccessibilityIdentifier(id)
        return button
    }

    private func announce(_ state: AddFlaccyServerViewModel.State) {
        switch state {
        case .connected(let info):
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            post(Self.connectedTitle(info.serverName))
        case .failed(let copy):
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            post("\(copy.title). \(copy.body)")
        case .checking(let server):
            post(Self.checkingTitle(server))
        case .idle:
            break
        }
    }

    private func post(_ text: String) {
        NSAccessibility.post(
            element: statusTitle, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    private func connectTapped() {
        guard model.canConnect else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        view.window?.makeFirstResponder(nil)
        Task { await model.connect() }
    }

    private func failureTapped(_ copy: FailureCopy, _ action: FailureCopy.Action) {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        switch action {
        case .tryAgain:
            retry(after: copy.failure)
        case .openTailscale:
            Tailscale.open()
        case .addAsRegularServer:
            let address = model.address
            dismiss(nil)
            onAddAsRegularServer?(address)
        case .openAppStore:
            if let url = URL(string: "macappstore://apps.apple.com/app/id6787493695") { NSWorkspace.shared.open(url) }
        case .dismiss:
            model.reset()
        case .cancel:
            dismiss(nil)
        }
    }

    private func retry(after failure: ServerSetupFailure) {
        if case .codeRefused = failure {
            model.code = ""
            codeField.stringValue = ""
            model.reset()
            view.window?.makeFirstResponder(codeField)
        } else {
            Task { await model.connect() }
        }
    }

    static func checkingTitle(_ server: String) -> String {
        String(localized: "Connecting to \(server)\u{2026}")
    }

    static func connectedTitle(_ server: String) -> String {
        String(localized: "Connected to \(server).")
    }

    static var connectedBody: String {
        String(localized: "Your playlists, loves and history now sync with this server. Its music is in your library under Servers.")
    }

    static var connectedWithoutMusicBody: String {
        String(localized: "Your playlists, loves and history now sync with this server. Its music will be added to your library the next time you open Flaccy.")
    }

    #if DEBUG
    func fill(address: String, code: String) {
        model.address = address
        model.code = code
        addressField.stringValue = model.address
        codeField.stringValue = model.code
        render()
    }

    func connectForCapture() async {
        await model.connect()
    }
    #endif
}

/// A push button that runs a closure when it is pressed.
final class PanelButton: NSButton {

    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(pressed)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func pressed() {
        handler()
    }
}
