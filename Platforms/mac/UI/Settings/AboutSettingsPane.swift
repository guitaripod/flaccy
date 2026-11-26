import AppKit
import MidgarCore
import AuthenticationServices
import Combine
import FlaccyCore
import MidgarPortal
import MidgarUI
import ServiceManagement
import SwiftUI
import UserNotifications

/// About: version, licenses, legal links.
final class AboutSettingsPane: SettingsPane {

    override func buildForm() {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let name = NSTextField(labelWithString: "Flaccy")
        name.font = .systemFont(ofSize: 22, weight: .bold)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let versionLabel = NSTextField(labelWithString: String(localized: "Version \(version) (\(build))"))
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor

        let tagline = NSTextField(labelWithString: String(localized: "Own your music. Forever."))
        tagline.font = .systemFont(ofSize: 13)

        let header = NSStackView(views: [icon, name, versionLabel, tagline])
        header.orientation = .vertical
        header.alignment = .centerX
        header.spacing = 6
        formStack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: formStack.widthAnchor, constant: -Self.fullWidthInset).isActive = true

        formStack.addArrangedSubview(separator())
        addFullWidth(explanation(String(localized: "Built with GRDB (SQLite), lyrics from lrclib.net, universal links by Songlink/Odesli, and scrobbling via the Last.fm API.")))

        let privacy = NSButton(title: String(localized: "Privacy Policy"), target: self, action: #selector(openPrivacy))
        privacy.bezelStyle = .rounded
        let terms = NSButton(title: String(localized: "Terms of Use"), target: self, action: #selector(openTerms))
        terms.bezelStyle = .rounded
        let support = NSButton(title: String(localized: "Contact Support"), target: self, action: #selector(openSupport))
        support.bezelStyle = .rounded
        support.toolTip = MidgarSupport.address
        addRow([privacy, terms, support], spacing: 10)

        let usage = NSButton(title: "\(MidgarUsageCounts.title)…", target: self, action: #selector(openUsageCounts))
        usage.bezelStyle = .rounded
        usage.setAccessibilityIdentifier("settings.usageCounts")
        addRow([usage], spacing: 10)

        let copyright = explanation("© 2026 Midgar Oy")
        formStack.addArrangedSubview(copyright)
    }

    @objc func openPrivacy() {
        NSWorkspace.shared.open(LegalLinks.privacyURL)
    }

    @objc func openTerms() {
        NSWorkspace.shared.open(LegalLinks.termsURL)
    }

    /// Opens the Usage Counts screen as a sheet: what Flaccy counts and reports, and the one switch that turns it off.
    @objc func openUsageCounts() {
        presentAsSheet(MacUsageCountsPanelViewController())
    }

    /// Starts an email to support with the log attached, through the mail app's link when the
    /// share service has no mail account, or copies the address where no mail app can take it.
    @objc func openSupport() {
        let items: [Any] = [SupportReport.body] + SupportReport.attachments()
        if let mail = NSSharingService(named: .composeEmail), mail.canPerform(withItems: items) {
            mail.recipients = [MidgarSupport.address]
            mail.subject = SupportReport.subject
            mail.perform(withItems: items)
            return
        }
        guard let url = URL(string: "mailto:\(MidgarSupport.address)?subject=Flaccy") else { return }
        guard !NSWorkspace.shared.open(url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MidgarSupport.address, forType: .string)
        MacToast.show(String(localized: "Copied to the clipboard"), style: .info, in: view.window)
    }
}

/// The Usage Counts sheet: the shared screen under its name over a Done button. A Mac sheet has no title bar, so the
/// SwiftUI toolbar the screen's own Done sat in had nowhere to appear and the sheet could not be closed.
final class MacUsageCountsPanelViewController: NSViewController {

    private var escapeMonitor: Any?

    override func loadView() {
        let title = NSTextField(labelWithString: MidgarUsageCounts.title)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        let screen = NSHostingView(rootView: NavigationStack { MidgarUsageCounts() })
        screen.translatesAutoresizingMaskIntoConstraints = false
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        let done = PanelButton(title: String(localized: "Done")) { [weak self] in self?.close() }
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.setAccessibilityIdentifier("usageCounts.done")
        let footer = NSStackView(views: [NSView(), done])
        footer.orientation = .horizontal
        footer.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        for item in [title, screen, separator, footer] {
            root.addSubview(item)
        }
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 460),
            root.heightAnchor.constraint(equalToConstant: 560),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            screen.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            screen.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            screen.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            screen.bottomAnchor.constraint(equalTo: separator.topAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 12),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, self?.view.window === event.window else { return event }
            self?.close()
            return nil
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        guard let escapeMonitor else { return }
        NSEvent.removeMonitor(escapeMonitor)
        self.escapeMonitor = nil
    }

    private func close() {
        dismiss(nil)
    }
}
