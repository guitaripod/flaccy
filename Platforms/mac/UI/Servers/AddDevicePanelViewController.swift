import AppKit
import FlaccyEngine
import FlaccyServerEmbed
import MidgarCore

/// The "Add a device" sheet of Share this Mac's library: a QR code and a link for the code that enrolls one device, how long it
/// has left, a new code on request, and the devices that have joined, with Remove.
final class AddDevicePanelViewController: NSViewController {

    private let sharing: LibrarySharing
    private let content = NSStackView()
    private let qrCard = NSView()
    private let qrView = NSImageView()
    private let linkField = NSTextField(wrappingLabelWithString: "")
    private let countdown = NSTextField(wrappingLabelWithString: "")
    private let problem = NSTextField(wrappingLabelWithString: "")
    private let firewall = NSTextField(wrappingLabelWithString: SharingCopy.firewallHint)
    private let devicesStack = NSStackView()
    private var link: String?
    private var expiry: Date?
    private var ticker: Timer?
    private var observer: NSObjectProtocol?
    private var tick = 0
    private var knownDevices: Set<String> = []
    private var devicesLoaded = false

    init(sharing: LibrarySharing = MacLibrarySharing.shared) {
        self.sharing = sharing
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: String(localized: "Add a Device"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let explainer = secondary(String(localized: "Scan this with Flaccy on your iPhone, Mac or Linux, or open the link on a device that has Flaccy."))

        qrCard.wantsLayer = true
        qrCard.layer?.backgroundColor = NSColor.white.cgColor
        qrCard.layer?.cornerRadius = 12
        qrView.translatesAutoresizingMaskIntoConstraints = false
        qrView.setAccessibilityLabel(String(localized: "QR code that adds a device to this Mac's library"))
        qrView.setAccessibilityIdentifier("addDevice.qr")
        qrCard.addSubview(qrView)
        qrCard.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            qrView.topAnchor.constraint(equalTo: qrCard.topAnchor, constant: 14),
            qrView.bottomAnchor.constraint(equalTo: qrCard.bottomAnchor, constant: -14),
            qrView.leadingAnchor.constraint(equalTo: qrCard.leadingAnchor, constant: 14),
            qrView.trailingAnchor.constraint(equalTo: qrCard.trailingAnchor, constant: -14),
            qrView.widthAnchor.constraint(equalToConstant: 200),
            qrView.heightAnchor.constraint(equalToConstant: 200),
        ])

        linkField.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        linkField.isSelectable = true
        linkField.lineBreakMode = .byTruncatingMiddle
        linkField.maximumNumberOfLines = 2
        linkField.setAccessibilityLabel(String(localized: "Link that adds a device"))
        linkField.setAccessibilityIdentifier("addDevice.link")
        countdown.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        countdown.textColor = .secondaryLabelColor
        countdown.setAccessibilityIdentifier("addDevice.countdown")
        let copy = PanelButton(title: String(localized: "Copy Link")) { [weak self] in self?.copyLink() }
        copy.bezelStyle = .rounded
        copy.setAccessibilityIdentifier("addDevice.copy")
        let renew = PanelButton(title: String(localized: "New Code")) { [weak self] in
            self?.haptic()
            self?.makeCode()
        }
        renew.bezelStyle = .rounded
        renew.setAccessibilityIdentifier("addDevice.newCode")
        let actions = NSStackView(views: [copy, renew, NSView()])
        actions.orientation = .horizontal
        actions.spacing = 8

        problem.font = .systemFont(ofSize: 12)
        problem.textColor = .secondaryLabelColor
        problem.setAccessibilityIdentifier("addDevice.problem")
        firewall.font = .systemFont(ofSize: 12)
        firewall.textColor = .secondaryLabelColor
        firewall.isHidden = true
        firewall.setAccessibilityIdentifier("addDevice.firewall")

        devicesStack.orientation = .vertical
        devicesStack.alignment = .leading
        devicesStack.spacing = 8
        let done = PanelButton(title: String(localized: "Done")) { [weak self] in self?.dismiss(nil) }
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.setAccessibilityIdentifier("addDevice.done")
        let buttons = NSStackView(views: [NSView(), done])
        buttons.orientation = .horizontal

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        content.translatesAutoresizingMaskIntoConstraints = false
        let devicesLabel = NSTextField(labelWithString: String(localized: "Devices").uppercased())
        devicesLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        devicesLabel.textColor = .secondaryLabelColor
        for item in [title, explainer, qrCard, linkField, countdown, actions, problem, firewall, devicesLabel, devicesStack, buttons] {
            content.addArrangedSubview(item)
        }
        content.setCustomSpacing(8, after: linkField)
        content.setCustomSpacing(8, after: countdown)
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(equalToConstant: 460),
        ])
        for item in [explainer, linkField, countdown, actions, problem, firewall, devicesStack, buttons] {
            item.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -48).isActive = true
        }
        qrCard.centerXAnchor.constraint(equalTo: content.centerXAnchor).isActive = true
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        makeCode()
        reloadDevices()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.secondPassed() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        observer = NotificationCenter.default.addObserver(forName: LibrarySharing.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderReachability() }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        ticker?.invalidate()
        ticker = nil
        observer.map(NotificationCenter.default.removeObserver)
        observer = nil
    }

    private func secondary(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func haptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private var serverName: String {
        if case .sharing(let state) = sharing.state { return state.name }
        return String(localized: "This Mac")
    }

    private func makeCode() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let enrollment = try await self.sharing.makeEnrollment()
                self.link = enrollment.link
                self.expiry = ISO8601DateFormatter().date(from: enrollment.expiresAt)
                self.renderReachability()
                self.renderCountdown()
            } catch {
                MidgarLog.error("The library server could not make a code: \(error.localizedDescription)", category: .sync)
                self.link = nil
                self.problem.stringValue = error.localizedDescription
                self.problem.isHidden = false
            }
        }
    }

    private func renderReachability() {
        guard case .sharing(let state) = sharing.state else {
            showNotSharing()
            return
        }
        let reachable = state.reachesTailnet
        qrCard.isHidden = !reachable || link == nil
        linkField.isHidden = !reachable || link == nil
        countdown.isHidden = !reachable || link == nil
        problem.isHidden = reachable
        if !reachable {
            problem.stringValue = SharingCopy.tailscaleMissing
        } else if let link {
            qrView.image = QRCode.image(for: link, side: 200)
            linkField.stringValue = link
        }
        firewall.isHidden = !sharing.firewallHintIsDue()
    }

    private func showNotSharing() {
        qrCard.isHidden = true
        linkField.isHidden = true
        countdown.isHidden = true
        problem.isHidden = false
        problem.stringValue = SharingCopy.statusLine(for: sharing.state) ?? String(localized: "Sharing is off. Turn on Share this Mac's library to add a device.")
    }

    private func renderCountdown() {
        guard let expiry else { return }
        countdown.stringValue = SharingCopy.countdown(max(0, Int(expiry.timeIntervalSinceNow.rounded(.up))))
    }

    private func secondPassed() {
        renderCountdown()
        tick += 1
        guard tick % 3 == 0 else { return }
        sharing.refresh()
        reloadDevices()
        firewall.isHidden = !sharing.firewallHintIsDue()
    }

    private func copyLink() {
        guard let link else { return }
        haptic()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        MacToast.show(String(localized: "Link copied."), style: .success, in: view.window)
    }

    private func reloadDevices() {
        Task { [weak self] in
            guard let self else { return }
            guard let server = ServerSyncService.engine.connectedServer, FlaccyServerLibrary.isThisDevicesOwn(server.url),
                  let listed = try? await ServerSyncService.engine.devices()
            else {
                self.showDeviceCount()
                return
            }
            self.render(devices: listed)
        }
    }

    private func showDeviceCount() {
        let count: Int
        if case .sharing(let state) = sharing.state { count = state.deviceCount } else { count = 0 }
        devicesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        devicesStack.addArrangedSubview(secondary(SharingCopy.devices(count)))
    }

    private func render(devices: [ServerDevice]) {
        let ids = Set(devices.map(\.id))
        if devicesLoaded, !ids.subtracting(knownDevices).isEmpty {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            makeCode()
        }
        knownDevices = ids
        devicesLoaded = true
        devicesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for device in devices {
            let row = deviceRow(device)
            devicesStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: devicesStack.widthAnchor).isActive = true
        }
        if devices.isEmpty { devicesStack.addArrangedSubview(secondary(SharingCopy.devices(0))) }
    }

    private func deviceRow(_ device: ServerDevice) -> NSView {
        let name = NSTextField(labelWithString: device.name)
        name.font = .systemFont(ofSize: 13)
        let subtitle = secondary(device.current ? String(localized: "This Mac") : FlaccyServerDetailViewModel.lastSeen(device.lastSeenAt))
        let text = NSStackView(views: [name, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        var views: [NSView] = [text, NSView()]
        if !device.current {
            let remove = PanelButton(title: String(localized: "Remove\u{2026}")) { [weak self] in self?.confirmRemove(device) }
            remove.bezelStyle = .rounded
            remove.controlSize = .small
            remove.setAccessibilityLabel(String(localized: "Remove \(device.name)"))
            remove.setAccessibilityIdentifier("addDevice.remove")
            views.append(remove)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        return row
    }

    private func confirmRemove(_ device: ServerDevice) {
        haptic()
        let server = serverName
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Remove \(device.name)?")
        alert.informativeText = String(localized: "\(device.name) stops syncing with \(server). Its playlists and history stay on it, and \(server) keeps its copy.")
        alert.addButton(withTitle: String(localized: "Remove"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.remove(device)
        }
    }

    private func remove(_ device: ServerDevice) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await ServerSyncService.engine.removeDevice(id: device.id)
                self.reloadDevices()
            } catch {
                MacToast.show(FlaccyServerDetailViewModel.devicesFailure(error, server: self.serverName), style: .error, in: self.view.window)
            }
        }
    }
}
