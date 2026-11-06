import AppKit
import MidgarCore
import AuthenticationServices
import Combine
import FlaccyCore
import MidgarPortal
import ServiceManagement
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
        header.widthAnchor.constraint(equalTo: formStack.widthAnchor, constant: -56).isActive = true

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

        let copyright = explanation("© 2026 Midgar Oy")
        formStack.addArrangedSubview(copyright)
    }

    @objc func openPrivacy() {
        NSWorkspace.shared.open(LegalLinks.privacyURL)
    }

    @objc func openTerms() {
        NSWorkspace.shared.open(LegalLinks.termsURL)
    }

    /// Starts an email to support, or copies the address where no mail app can take it.
    @objc func openSupport() {
        guard let url = URL(string: "mailto:\(MidgarSupport.address)?subject=Flaccy") else { return }
        guard !NSWorkspace.shared.open(url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MidgarSupport.address, forType: .string)
        MacToast.show(String(localized: "Copied to the clipboard"), style: .info, in: view.window)
    }
}
