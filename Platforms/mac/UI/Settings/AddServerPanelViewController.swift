import AppKit
import FlaccyCore
import MidgarCore

/// The sheet that adds a music server on the Mac: address, how to sign in, a name, Test and Add.
/// A pasted `flaccy://server` link fills it in with API-key sign-in.
final class AddServerPanelViewController: NSViewController, NSTextFieldDelegate {

    var onAdded: ((RemoteServerRecord) -> Void)?

    private let form = AddServerViewModel()
    private let servers: RemoteServersViewModel
    private let addressField = NSTextField()
    private let kindControl = NSSegmentedControl(
        labels: AddServerViewModel.Kind.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil
    )
    private let usernameField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let apiKeyField = NSSecureTextField()
    private let nameField = NSTextField()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let statusIcon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let pasteButton = NSButton(title: String(localized: "Paste Link"), target: nil, action: nil)
    private let testButton = NSButton(title: String(localized: "Test"), target: nil, action: nil)
    private let cancelButton = NSButton(title: String(localized: "Cancel"), target: nil, action: nil)
    private let addButton = NSButton(title: String(localized: "Add"), target: nil, action: nil)
    private var grid: NSGridView!
    private var usernameRow: NSGridRow!
    private var passwordRow: NSGridRow!
    private var apiKeyRow: NSGridRow!

    init(servers: RemoteServersViewModel, link: ServerLink? = nil, address: String? = nil) {
        self.servers = servers
        super.init(nibName: nil, bundle: nil)
        if let link { form.apply(link: link) }
        if let address { form.address = address }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: String(localized: "Add Server"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let explainer = NSTextField(wrappingLabelWithString: RemoteCopy.explainer)
        explainer.font = .systemFont(ofSize: 11)
        explainer.textColor = .secondaryLabelColor

        configure(addressField, placeholder: String(localized: "music.example.com or http://192.168.1.20:4533"), id: "addServer.address")
        configure(usernameField, placeholder: String(localized: "Required"), id: "addServer.username")
        configure(passwordField, placeholder: String(localized: "Required"), id: "addServer.password")
        configure(apiKeyField, placeholder: String(localized: "Required"), id: "addServer.apiKey")
        configure(nameField, placeholder: String(localized: "Home Server"), id: "addServer.name")

        kindControl.target = self
        kindControl.action = #selector(kindChanged)
        kindControl.selectedSegment = form.kind.rawValue
        kindControl.setAccessibilityIdentifier("addServer.kind")

        grid = NSGridView(views: [
            [label(String(localized: "Address")), addressField],
            [label(String(localized: "Sign in with")), kindControl],
            [label(String(localized: "Username")), usernameField],
            [label(String(localized: "Password")), passwordField],
            [label(String(localized: "API Key")), apiKeyField],
            [label(String(localized: "Name")), nameField],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 300
        usernameRow = grid.row(at: 2)
        passwordRow = grid.row(at: 3)
        apiKeyRow = grid.row(at: 4)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.setAccessibilityIdentifier("addServer.status")
        statusIcon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let status = NSStackView(views: [statusIcon, spinner, statusLabel])
        status.orientation = .horizontal
        status.alignment = .top
        status.spacing = 6

        pasteButton.target = self
        pasteButton.action = #selector(pasteLink)
        pasteButton.bezelStyle = .rounded
        pasteButton.setAccessibilityIdentifier("addServer.paste")
        testButton.target = self
        testButton.action = #selector(testTapped)
        testButton.bezelStyle = .rounded
        testButton.setAccessibilityIdentifier("addServer.test")
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.bezelStyle = .rounded
        addButton.keyEquivalent = "\r"
        addButton.setAccessibilityIdentifier("addServer.add")

        let buttons = NSStackView(views: [pasteButton, NSView(), testButton, cancelButton, addButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [title, explainer, grid, status, buttons])
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
            view.widthAnchor.constraint(equalToConstant: 520),
            explainer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
        ])
        form.onChange = { [weak self] in self?.render() }
        syncFields()
        render()
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func configure(_ field: NSTextField, placeholder: String, id: String) {
        field.placeholderString = placeholder
        field.delegate = self
        field.lineBreakMode = .byTruncatingTail
        field.setAccessibilityIdentifier(id)
    }

    private func syncFields() {
        addressField.stringValue = form.address
        usernameField.stringValue = form.username
        passwordField.stringValue = form.password
        apiKeyField.stringValue = form.apiKey
        nameField.stringValue = form.name
        kindControl.selectedSegment = form.kind.rawValue
    }

    private func render() {
        usernameRow.isHidden = form.kind != .password
        passwordRow.isHidden = form.kind != .password
        apiKeyRow.isHidden = form.kind != .apiKey
        kindControl.selectedSegment = form.kind.rawValue
        let busy = form.testState == .testing
        testButton.isEnabled = !busy
        addButton.isEnabled = !busy
        statusIcon.isHidden = true
        spinner.isHidden = form.testState != .testing
        spinner.stopAnimation(nil)
        statusLabel.textColor = .labelColor
        switch form.testState {
        case .idle:
            statusLabel.stringValue = ""
        case .testing:
            statusLabel.stringValue = String(localized: "Testing the connection\u{2026}")
            statusLabel.textColor = .secondaryLabelColor
            spinner.startAnimation(nil)
        case .passed(let summary):
            statusLabel.stringValue = summary
            statusIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            statusIcon.contentTintColor = .systemGreen
            statusIcon.isHidden = false
        case .failed(let message):
            statusLabel.stringValue = message
            statusIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            statusIcon.contentTintColor = .systemRed
            statusIcon.isHidden = false
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        switch field {
        case addressField: form.address = field.stringValue
        case usernameField: form.username = field.stringValue
        case passwordField: form.password = field.stringValue
        case apiKeyField: form.apiKey = field.stringValue
        case nameField: form.name = field.stringValue
        default: break
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === addressField else { return }
        form.suggestName()
        nameField.stringValue = form.name
    }

    @objc private func kindChanged() {
        guard let kind = AddServerViewModel.Kind(rawValue: kindControl.selectedSegment) else { return }
        form.kind = kind
    }

    @objc private func pasteLink() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        guard let link = ServerLink(text: text) else {
            NSSound.beep()
            statusIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            statusIcon.contentTintColor = .systemRed
            statusIcon.isHidden = false
            statusLabel.stringValue = String(localized: "The clipboard doesn\u{2019}t hold a Flaccy Server link. Copy the flaccy://server link the server printed, then try again.")
            return
        }
        form.apply(link: link)
        syncFields()
    }

    #if DEBUG
    func fillForCapture(address: String, username: String, password: String) async {
        form.address = address
        form.suggestName()
        form.username = username
        form.password = password
        syncFields()
        await form.test(using: servers)
    }
    #endif

    @objc private func testTapped() {
        view.window?.makeFirstResponder(nil)
        Task { await form.test(using: servers) }
    }

    @objc private func cancelTapped() {
        dismiss(nil)
    }

    @objc private func addTapped() {
        view.window?.makeFirstResponder(nil)
        Task { [weak self] in
            guard let self else { return }
            if let record = await self.form.add(using: self.servers) {
                self.onAdded?(record)
                self.dismiss(nil)
            }
        }
    }
}
