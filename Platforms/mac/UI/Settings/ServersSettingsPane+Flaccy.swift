import AppKit
import FlaccyCore
import FlaccyEngine
import MidgarCore

extension ServersSettingsPane {

    func present(link: ParsedServerLink) {
        switch link {
        case .flaccyServer(let flaccy):
            presentAddFlaccyServer(link: flaccy)
        case .subsonic(let subsonic):
            presentAddServer(link: subsonic)
        }
    }

    func presentAddFlaccyServer(link: FlaccyServerLink?) {
        let panel = AddFlaccyServerPanelViewController(link: link)
        panel.onAddAsRegularServer = { [weak self] address in self?.presentAddServer(link: nil, address: address) }
        panel.onOpenSubsonicLink = { [weak self] subsonic in self?.presentAddServer(link: subsonic) }
        presentAsSheet(panel)
    }

    func addFlaccyTapped() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        presentAddFlaccyServer(link: nil)
    }

    func pasteTapped() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        guard let link = ParsedServerLink(text: NSPasteboard.general.string(forType: .string) ?? "") else {
            NSSound.beep()
            MacToast.show(
                String(localized: "The clipboard doesn\u{2019}t hold a Flaccy Server link. Copy the flaccy://server link the server printed, then try again."),
                style: .error, in: view.window
            )
            return
        }
        present(link: link)
    }

    func buildNudge() {
        nudge.orientation = .horizontal
        nudge.alignment = .top
        nudge.spacing = 8
        let text = NSTextField(wrappingLabelWithString: FlaccyServerNudge.text)
        text.font = .systemFont(ofSize: 11)
        text.textColor = .secondaryLabelColor
        text.setAccessibilityIdentifier("settings.serversNudge")
        let close = PanelButton(title: "") { [weak self] in
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            FlaccyServerNudge.dismiss()
            self?.nudge.isHidden = true
        }
        close.image = MacSymbolImage.image("xmark.circle.fill")
        close.isBordered = false
        close.contentTintColor = .tertiaryLabelColor
        close.setAccessibilityLabel(String(localized: "Close"))
        close.setAccessibilityHelp(String(localized: "Hides this suggestion for good"))
        close.setAccessibilityIdentifier("settings.serversNudge.close")
        close.setContentHuggingPriority(.required, for: .horizontal)
        nudge.addArrangedSubview(text)
        nudge.addArrangedSubview(close)
    }

    func makeFlaccyRow(for server: RemoteServerRow, flaccy: FlaccyServerRowModel) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let name = NSTextField(labelWithString: server.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        let title = NSStackView(views: [name, syncBadge(flaccy.syncBadge)])
        title.orientation = .horizontal
        title.spacing = 8
        let status = NSTextField(wrappingLabelWithString: flaccy.statusLine)
        status.font = .systemFont(ofSize: 11)
        status.textColor = flaccy.needsPro ? .controlAccentColor : .secondaryLabelColor
        status.setAccessibilityIdentifier("settings.flaccyServer.status")
        let counts = [flaccy.songs, flaccy.deviceCount.map(FlaccyServerRowModel.devices)].compactMap { $0 }.joined(separator: " \u{00B7} ")
        let detail = NSTextField(wrappingLabelWithString: counts)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .tertiaryLabelColor
        let text = NSStackView(views: [title, status, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let details = button(String(localized: "Details\u{2026}"), symbol: "info.circle") { [weak self] in self?.showDetails(of: server) }
        details.setAccessibilityLabel(String(localized: "Details of \(server.name)"))
        details.setAccessibilityIdentifier("settings.flaccyServer.details")

        let row = NSStackView(views: [icon, text, NSView(), details])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        row.setAccessibilityIdentifier("settings.row.flaccyServer")
        row.setAccessibilityLabel(server.name)
        row.setAccessibilityValue(flaccy.accessibilityValue)
        return row
    }

    private func syncBadge(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .controlAccentColor
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
        badge.layer?.cornerRadius = 7
        label.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: badge.topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: -1),
            label.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -7),
        ])
        badge.setAccessibilityElement(false)
        badge.setAccessibilityIdentifier("settings.row.flaccyServer.badge")
        return badge
    }

    func showDetails(of server: RemoteServerRow) {
        guard let record = try? DatabaseManager.shared.fetchRemoteServer(id: server.id) else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        presentAsSheet(FlaccyServerDetailPanelViewController(record: record))
    }

    func announceFlaccyStatusChange(from old: [RemoteServerRow], to new: [RemoteServerRow]) {
        let before = Dictionary(old.compactMap { row in row.flaccy.map { (row.id, $0.statusLine) } }, uniquingKeysWith: { first, _ in first })
        for row in new {
            guard let line = row.flaccy?.statusLine, let previous = before[row.id], previous != line else { continue }
            NSAccessibility.post(
                element: listStack, notification: .announcementRequested,
                userInfo: [.announcement: line, .priority: NSAccessibilityPriorityLevel.medium.rawValue]
            )
        }
    }
}
