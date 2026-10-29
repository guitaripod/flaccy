import AppKit
import FlaccyEngine
import FlaccyServerEmbed
import MidgarCore

/// "Share this Mac's library" in Settings > Servers: the switch, the status line, and while sharing the buttons to add a device or
/// to get Tailscale. It follows the sharing controller, the sync status and the purchase state while it is on screen.
final class ShareLibrarySection {

    let view = NSStackView()

    private weak var host: NSViewController?
    private let sharing: LibrarySharing
    private let toggle = NSSwitch()
    private let toggleLabel = NSTextField(labelWithString: SharingCopy.title)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let syncLine = NSTextField(wrappingLabelWithString: "")
    private let firewall = NSTextField(wrappingLabelWithString: SharingCopy.firewallHint)
    private let buttons = NSStackView()
    private lazy var addDevice = PanelButton(title: SharingCopy.addDevice) { [weak self] in self?.addDeviceTapped() }
    private lazy var tailscale = PanelButton(title: SharingCopy.getTailscale) { [weak self] in self?.tailscaleTapped() }
    private lazy var proSync = PanelButton(title: String(localized: "Sync playlists, loves and history \u{00B7} Pro")) { [weak self] in
        self?.proTapped()
    }
    private var observers: [NSObjectProtocol] = []
    private var refresher: Timer?
    private var lastAnnounced = ""

    init(host: NSViewController, sharing: LibrarySharing = MacLibrarySharing.shared) {
        self.host = host
        self.sharing = sharing
        build()
    }

    func start() {
        let center = NotificationCenter.default
        let names = [
            LibrarySharing.didChange, FlaccyServerStatusStore.didChange, PurchaseManager.stateDidChange,
            PurchaseManager.entitlementsDidLoad,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.render() }
            }
        }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refresher = timer
        sharing.refresh()
        render()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        refresher?.invalidate()
        refresher = nil
    }

    private func build() {
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 10
        toggleLabel.font = .systemFont(ofSize: 13)
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.setAccessibilityLabel(SharingCopy.title)
        toggle.setAccessibilityIdentifier("settings.shareLibrary")
        let header = NSStackView(views: [toggleLabel, NSView(), toggle])
        header.orientation = .horizontal
        header.alignment = .centerY
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.setAccessibilityIdentifier("settings.shareLibrary.status")
        syncLine.font = .systemFont(ofSize: 12)
        syncLine.textColor = .secondaryLabelColor
        syncLine.setAccessibilityIdentifier("settings.shareLibrary.sync")
        firewall.font = .systemFont(ofSize: 12)
        firewall.textColor = .secondaryLabelColor
        firewall.setAccessibilityIdentifier("settings.shareLibrary.firewall")
        addDevice.bezelStyle = .rounded
        addDevice.setAccessibilityIdentifier("settings.shareLibrary.addDevice")
        tailscale.bezelStyle = .rounded
        tailscale.setAccessibilityIdentifier("settings.shareLibrary.tailscale")
        proSync.isBordered = false
        proSync.contentTintColor = .controlAccentColor
        proSync.setAccessibilityHelp(String(localized: "Opens Flaccy Pro"))
        proSync.setAccessibilityIdentifier("settings.shareLibrary.pro")
        buttons.orientation = .horizontal
        buttons.spacing = 8
        for item in [header, status, syncLine, proSync, buttons, firewall] {
            view.addArrangedSubview(item)
        }
        for item in [header, status, syncLine, buttons, firewall] {
            item.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        }
    }

    #if DEBUG
    func clickSwitchForCapture() {
        toggle.performClick(nil)
    }
    #endif

    private func render() {
        let state = sharing.state
        toggle.state = sharing.isEnabled ? .on : .off
        let line = SharingCopy.statusLine(for: state) ?? SharingCopy.explanation
        status.stringValue = line
        status.textColor = isFailure(state) ? .systemRed : .secondaryLabelColor
        announceIfChanged(line)
        renderButtons(state)
        renderSync(state)
        firewall.isHidden = !sharing.firewallHintIsDue()
    }

    private func isFailure(_ state: LibrarySharing.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func renderButtons(_ state: LibrarySharing.State) {
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard case .sharing(let sharing) = state else { return }
        addDevice.isEnabled = sharing.reachesTailnet
        buttons.addArrangedSubview(addDevice)
        if !sharing.reachesTailnet {
            tailscale.title = Tailscale.isInstalled ? SharingCopy.openTailscale : SharingCopy.getTailscale
            buttons.addArrangedSubview(tailscale)
        }
    }

    private func renderSync(_ state: LibrarySharing.State) {
        let isOwn = ServerSyncService.engine.connectedServer.map { FlaccyServerLibrary.isThisDevicesOwn($0.url) } ?? false
        guard case .sharing = state, isOwn else {
            syncLine.isHidden = true
            proSync.isHidden = true
            return
        }
        let isPro = PurchaseManager.shared.includesServerSync
        proSync.isHidden = isPro
        syncLine.isHidden = !isPro
        syncLine.stringValue = String(localized: "This Mac's playlists, loves and history: \(FlaccyServerStatusStore.shared.status.statusLine)")
    }

    private func announceIfChanged(_ line: String) {
        guard line != lastAnnounced else { return }
        lastAnnounced = line
        NSAccessibility.post(
            element: status, notification: .announcementRequested,
            userInfo: [.announcement: line, .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )
    }

    @objc private func toggled() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        guard toggle.state == .on else {
            sharing.setEnabled(false)
            return
        }
        guard !sharing.hasBeenIntroduced else {
            sharing.setEnabled(true)
            return
        }
        introduce()
    }

    private func introduce() {
        let alert = NSAlert()
        alert.messageText = SharingCopy.introTitle
        alert.informativeText = SharingCopy.explanation
        alert.addButton(withTitle: SharingCopy.share)
        alert.addButton(withTitle: SharingCopy.notNow)
        guard let window = host?.view.window else {
            sharing.hasBeenIntroduced = true
            sharing.setEnabled(true)
            return
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else {
                self.toggle.state = .off
                return
            }
            self.sharing.hasBeenIntroduced = true
            self.sharing.setEnabled(true)
        }
    }

    private func addDeviceTapped() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        host?.presentAsSheet(AddDevicePanelViewController(sharing: sharing))
    }

    private func tailscaleTapped() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        if Tailscale.isInstalled { Tailscale.open() } else { Tailscale.openDownloadPage() }
    }

    private func proTapped() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        (NSApp.delegate as? MacAppDelegate)?.presentPaywall()
    }
}
