import AppKit
import FlaccyCore
import MidgarCore

/// The screen of one Flaccy Server (docs/server/UX.md section 4) as a sheet on the Mac: Status, Library, Sync, Devices and
/// Disconnect.
final class FlaccyServerDetailPanelViewController: NSViewController {

    var onDisconnected: (() -> Void)?

    private let model: FlaccyServerDetailViewModel
    private let content = NSStackView()
    private var lastStatusLine = ""

    init(record: RemoteServerRecord) {
        model = FlaccyServerDetailViewModel(record: record)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(equalToConstant: 500),
        ])
        model.onChange = { [weak self] in self?.rebuild() }
        model.onProRequested = { [weak self] in self?.openPaywall() }
        rebuild()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        model.start()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        model.stop()
    }

    private func rebuild() {
        guard isViewLoaded else { return }
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let title = NSTextField(labelWithString: model.name)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        add(title)
        add(secondary(model.address))
        add(section(String(localized: "Status")))
        let status = NSTextField(wrappingLabelWithString: model.statusLine)
        status.font = .systemFont(ofSize: 13)
        status.setAccessibilityIdentifier("flaccyServer.status")
        add(status)
        if let last = model.lastSyncedLine { add(secondary(last)) }
        add(section(String(localized: "Library")))
        add(row(String(localized: "Songs"), trailing: secondary(model.songs)))
        add(toggleRow(model.libraryToggleTitle, isOn: model.isLibraryShown, id: "flaccyServer.library", action: #selector(libraryToggled(_:))))
        add(section(String(localized: "Sync")))
        if model.isPro {
            add(toggleRow(model.syncToggleTitle, isOn: model.isSyncOn, id: "flaccyServer.sync", action: #selector(syncToggled(_:))))
        } else {
            add(proRow())
        }
        add(section(String(localized: "Devices")))
        devices().forEach(add)
        let disconnect = PanelButton(title: model.disconnectTitle) { [weak self] in self?.confirmDisconnect() }
        disconnect.bezelStyle = .rounded
        disconnect.hasDestructiveAction = true
        disconnect.setAccessibilityIdentifier("flaccyServer.disconnect")
        let done = PanelButton(title: String(localized: "Done")) { [weak self] in self?.dismiss(nil) }
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.setAccessibilityIdentifier("flaccyServer.done")
        let buttons = NSStackView(views: [disconnect, NSView(), done])
        buttons.orientation = .horizontal
        add(buttons)
        announceStatusIfChanged()
    }

    private func add(_ view: NSView) {
        content.addArrangedSubview(view)
        if view is NSStackView || view is NSTextField {
            view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -48).isActive = true
        }
    }

    private func announceStatusIfChanged() {
        let line = model.statusLine
        guard line != lastStatusLine else { return }
        lastStatusLine = line
        NSAccessibility.post(
            element: content, notification: .announcementRequested,
            userInfo: [.announcement: line, .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )
    }

    private func section(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func secondary(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func row(_ title: String, trailing: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        let stack = NSStackView(views: [label, NSView(), trailing])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        return stack
    }

    private func toggleRow(_ title: String, isOn: Bool, id: String, action: Selector) -> NSStackView {
        let toggle = NSSwitch()
        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = action
        toggle.setAccessibilityLabel(title)
        toggle.setAccessibilityIdentifier(id)
        let label = NSTextField(wrappingLabelWithString: title)
        label.font = .systemFont(ofSize: 13)
        let stack = NSStackView(views: [label, NSView(), toggle])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        return stack
    }

    private func proRow() -> NSView {
        let button = PanelButton(title: model.proRowTitle) { [weak self] in self?.openPaywall() }
        button.isBordered = false
        button.contentTintColor = .controlAccentColor
        button.image = MacSymbolImage.image("chevron.right")
        button.imagePosition = .imageTrailing
        button.setAccessibilityHelp(String(localized: "Opens Flaccy Pro"))
        button.setAccessibilityIdentifier("flaccyServer.proSync")
        let stack = NSStackView(views: [button])
        stack.orientation = .horizontal
        return stack
    }

    private func devices() -> [NSView] {
        switch model.devices {
        case .loading:
            return [secondary(String(localized: "Loading devices\u{2026}"))]
        case .failed(let message):
            return [secondary(message)]
        case .loaded(let devices):
            return devices.map(deviceRow)
        }
    }

    private func deviceRow(_ device: FlaccyServerDetailViewModel.DeviceRow) -> NSView {
        let name = NSTextField(labelWithString: device.name)
        name.font = .systemFont(ofSize: 13)
        let subtitle = secondary(device.isCurrent ? model.thisDeviceLabel : device.lastSeen ?? "")
        let text = NSStackView(views: [name, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let button = PanelButton(title: device.isCurrent ? String(localized: "Rename\u{2026}") : String(localized: "Remove\u{2026}")) { [weak self] in
            if device.isCurrent { self?.promptRename(device) } else { self?.confirmRemove(device) }
        }
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setAccessibilityLabel(device.isCurrent ? String(localized: "Rename \(device.name)") : String(localized: "Remove \(device.name)"))
        button.setAccessibilityIdentifier("flaccyServer.device")
        let stack = NSStackView(views: [text, NSView(), button])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        return stack
    }

    @objc private func libraryToggled(_ sender: NSSwitch) {
        haptic()
        let shown = sender.state == .on
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.model.setLibraryShown(shown)
            } catch {
                MacToast.show(RemoteFailure.from(error, host: self.model.address).errorDescription ?? "", style: .error, in: self.view.window)
                self.rebuild()
            }
        }
    }

    @objc private func syncToggled(_ sender: NSSwitch) {
        haptic()
        let on = sender.state == .on
        Task { await model.setSyncOn(on) }
    }

    private func openPaywall() {
        haptic()
        dismiss(nil)
        (NSApp.delegate as? MacAppDelegate)?.presentPaywall()
    }

    private func promptRename(_ device: FlaccyServerDetailViewModel.DeviceRow) {
        haptic()
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename This Device")
        alert.informativeText = String(localized: "This is the name \(model.name) shows for this device.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = device.name
        field.placeholderString = String(localized: "Name")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Rename"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.rename(device, to: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        alert.window.initialFirstResponder = field
    }

    private func rename(_ device: FlaccyServerDetailViewModel.DeviceRow, to name: String) {
        guard !name.isEmpty else {
            MacToast.show(String(localized: "A device needs a name. Type one and try again."), style: .error, in: view.window)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.model.rename(device: device, to: name)
            } catch {
                MacToast.show(FlaccyServerDetailViewModel.devicesFailure(error, server: self.model.name), style: .error, in: self.view.window)
            }
        }
    }

    private func confirmRemove(_ device: FlaccyServerDetailViewModel.DeviceRow) {
        haptic()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Remove \(device.name)?")
        alert.informativeText = String(localized: "\(device.name) stops syncing with \(model.name). Its playlists and history stay on it, and \(model.name) keeps its copy.")
        alert.addButton(withTitle: String(localized: "Remove"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.remove(device)
        }
    }

    private func remove(_ device: FlaccyServerDetailViewModel.DeviceRow) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.model.remove(device: device)
            } catch {
                MacToast.show(FlaccyServerDetailViewModel.devicesFailure(error, server: self.model.name), style: .error, in: self.view.window)
            }
        }
    }

    private func confirmDisconnect() {
        haptic()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = model.disconnectTitle
        alert.informativeText = model.disconnectMessage
        alert.addButton(withTitle: String(localized: "Disconnect"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.disconnect()
        }
    }

    private func disconnect() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.model.disconnect()
                ServerSyncLifecycle.shared.disconnected()
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                self.onDisconnected?()
                self.dismiss(nil)
            } catch {
                MacToast.show(
                    String(localized: "Couldn't disconnect from \(self.model.name). Try again in a moment."),
                    style: .error, in: self.view.window
                )
            }
        }
    }

    private func haptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
