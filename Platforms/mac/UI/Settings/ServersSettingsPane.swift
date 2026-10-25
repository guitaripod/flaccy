import AppKit
import FlaccyCore
import MidgarCore

/// Servers: the music servers whose libraries join this one, how to add one, and the size of the
/// cache that lets their songs replay without the server.
final class ServersSettingsPane: SettingsPane {

    private let model = RemoteServersViewModel()
    private let listStack = NSStackView()
    private let cacheLimitLabel = NSTextField(labelWithString: "")
    private let cacheLimitStepper = NSStepper()
    private let cacheUsageLabel = NSTextField(labelWithString: "")
    private var rowsOnScreen: [RemoteServerRow] = []

    override func buildForm() {
        formStack.addArrangedSubview(sectionLabel(String(localized: "Servers")))
        addFullWidth(explanation(RemoteCopy.explainer))

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 10
        addFullWidth(listStack)

        let add = NSButton(title: String(localized: "Add Server\u{2026}"), target: self, action: #selector(addTapped))
        add.bezelStyle = .rounded
        add.setAccessibilityIdentifier("settings.addServer")
        addRow([add])
        formStack.addArrangedSubview(separator())

        formStack.addArrangedSubview(sectionLabel(String(localized: "Server Cache")))
        let limitTitle = NSTextField(labelWithString: String(localized: "Cache Limit"))
        limitTitle.font = .systemFont(ofSize: 13)
        cacheLimitLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        cacheLimitStepper.minValue = Double(RemoteServersViewModel.cacheLimitRange.lowerBound)
        cacheLimitStepper.maxValue = Double(RemoteServersViewModel.cacheLimitRange.upperBound)
        cacheLimitStepper.increment = 1
        cacheLimitStepper.target = self
        cacheLimitStepper.action = #selector(limitStepped)
        cacheLimitStepper.setAccessibilityLabel(String(localized: "Cache Limit"))
        addRow([limitTitle, cacheLimitLabel, cacheLimitStepper], spacing: 8)
        cacheUsageLabel.font = .systemFont(ofSize: 12)
        cacheUsageLabel.textColor = .secondaryLabelColor
        let clear = NSButton(title: String(localized: "Clear Cache\u{2026}"), target: self, action: #selector(clearTapped))
        clear.bezelStyle = .rounded
        addRow([cacheUsageLabel, clear], spacing: 12)
        addFullWidth(explanation(RemoteCopy.cacheFooter))
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        model.onChange = { [weak self] in self?.render() }
        model.start()
        render()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        model.stop()
    }

    private func render() {
        cacheLimitStepper.integerValue = model.cacheLimitGigabytes
        cacheLimitLabel.stringValue = RemoteCopy.cacheLimit(gigabytes: model.cacheLimitGigabytes)
        cacheUsageLabel.stringValue = model.cacheCaption.isEmpty ? "\u{2026}" : model.cacheCaption
        guard model.rows != rowsOnScreen else { return }
        rowsOnScreen = model.rows
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if model.rows.isEmpty {
            let empty = NSTextField(labelWithString: String(localized: "No servers yet. Add one to play its library here."))
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .tertiaryLabelColor
            listStack.addArrangedSubview(empty)
        }
        for server in model.rows {
            let row = makeRow(for: server)
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
    }

    private func makeRow(for server: RemoteServerRow) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let name = NSTextField(labelWithString: server.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: RemoteCopy.detail(for: server))
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = server.lastFailure == nil ? .secondaryLabelColor : .systemRed
        detail.setAccessibilityIdentifier("settings.server.detail")
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let refresh = button(String(localized: "Refresh"), symbol: "arrow.clockwise") { [weak self] in self?.model.refresh(serverID: server.id) }
        let rename = button(String(localized: "Rename\u{2026}"), symbol: "pencil") { [weak self] in self?.promptRename(server) }
        let remove = button(String(localized: "Remove\u{2026}"), symbol: "trash") { [weak self] in self?.confirmRemove(server) }
        refresh.isEnabled = !server.isSyncing

        let row = NSStackView(views: [icon, text, NSView(), refresh, rename, remove])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        row.setAccessibilityIdentifier("settings.server")
        return row
    }

    private func button(_ title: String, symbol: String, action: @escaping () -> Void) -> NSButton {
        let item = ClosureButton(title: title, action: action)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.imagePosition = .imageLeading
        item.bezelStyle = .rounded
        item.controlSize = .small
        return item
    }

    @objc private func addTapped() {
        presentAddServer(link: nil)
    }

    func presentAddServer(link: ServerLink?) {
        presentAsSheet(AddServerPanelViewController(servers: model, link: link))
    }

    @objc private func limitStepped() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        model.cacheLimitGigabytes = cacheLimitStepper.integerValue
        render()
    }

    private func promptRename(_ server: RemoteServerRow) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename Server")
        alert.informativeText = String(localized: "The name shows in the library\u{2019}s source filter and in messages. Its songs stay where they are.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = server.name
        field.placeholderString = String(localized: "Name")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Rename"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.rename(server, to: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        alert.window.initialFirstResponder = field
    }

    private func rename(_ server: RemoteServerRow, to name: String) {
        guard !name.isEmpty else {
            MacToast.show(String(localized: "A server needs a name. Type one and try again."), style: .error, in: view.window)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.model.rename(serverID: server.id, to: name)
            } catch {
                MacToast.show(RemoteFailure.from(error, host: server.address).errorDescription ?? "", style: .error, in: self.view.window)
            }
        }
    }

    private func confirmRemove(_ server: RemoteServerRow) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Remove \u{201C}\(server.name)\u{201D}?")
        alert.informativeText = RemoteCopy.removalMessage(songCount: server.songCount)
        alert.addButton(withTitle: String(localized: "Remove Server"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.remove(server)
        }
    }

    private func remove(_ server: RemoteServerRow) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let sentence = try await self.model.remove(serverID: server.id)
                MacToast.show(sentence, style: .info, in: self.view.window)
            } catch {
                MacToast.show(RemoteFailure.from(error, host: server.address).errorDescription ?? "", style: .error, in: self.view.window)
            }
        }
    }

    @objc private func clearTapped() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Clear Cache?")
        alert.informativeText = String(localized: "Songs you streamed are fetched from the server again the next time you play them. Songs you downloaded are not touched.")
        alert.addButton(withTitle: String(localized: "Clear Cache"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { [weak self] in
                guard let self else { return }
                let freed = await self.model.clearCache()
                MacToast.show(RemoteCopy.cacheCleared(bytes: freed), style: .success, in: self.view.window)
            }
        }
    }

}

/// A push button that runs a closure when it is pressed.
private final class ClosureButton: NSButton {

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
