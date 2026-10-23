import AppKit
import MidgarCore
import AuthenticationServices
import Combine
import FlaccyCore
import MidgarPortal
import ServiceManagement
import UserNotifications

/// Last.fm: connect/disconnect, profile, pending scrobbles, history import.
final class LastFMSettingsPane: SettingsPane {

    let statusLabel = NSTextField(labelWithString: "")
    let connectButton = NSButton(title: String(localized: "Connect Last.fm…"), target: nil, action: nil)
    let profileButton = NSButton(title: String(localized: "View Profile"), target: nil, action: nil)
    let disconnectButton = NSButton(title: String(localized: "Disconnect"), target: nil, action: nil)
    let pendingLabel = NSTextField(labelWithString: "")
    let retryButton = NSButton(title: String(localized: "Retry Now"), target: nil, action: nil)
    let importButton = NSButton(title: String(localized: "Import History"), target: nil, action: nil)
    let importStatusLabel = NSTextField(labelWithString: "")
    let importSpinner = NSProgressIndicator()
    let viewModel = ChartsViewModel()
    var importObserver: AnyCancellable?

    override func buildForm() {
        formStack.addArrangedSubview(sectionLabel(String(localized: "Account")))
        statusLabel.font = .systemFont(ofSize: 13)
        connectButton.bezelStyle = .rounded
        connectButton.target = self
        connectButton.action = #selector(connectTapped)
        profileButton.bezelStyle = .rounded
        profileButton.target = self
        profileButton.action = #selector(profileTapped)
        disconnectButton.bezelStyle = .rounded
        disconnectButton.target = self
        disconnectButton.action = #selector(disconnectTapped)
        addRow([statusLabel, connectButton, profileButton, disconnectButton], spacing: 10)
        addFullWidth(explanation(String(localized: "Scrobbles every play, keeps an offline queue, and powers the Recap, Wantlist, and loved tracks.")))
        formStack.addArrangedSubview(separator())

        formStack.addArrangedSubview(sectionLabel(String(localized: "Scrobbles")))
        pendingLabel.font = .systemFont(ofSize: 13)
        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .small
        retryButton.target = self
        retryButton.action = #selector(retryTapped)
        addRow([pendingLabel, retryButton], spacing: 10)
        formStack.addArrangedSubview(separator())

        formStack.addArrangedSubview(sectionLabel(String(localized: "History")))
        importButton.bezelStyle = .rounded
        importButton.target = self
        importButton.action = #selector(importTapped)
        importSpinner.style = .spinning
        importSpinner.controlSize = .small
        importSpinner.isDisplayedWhenStopped = false
        importStatusLabel.font = .systemFont(ofSize: 12)
        importStatusLabel.textColor = .secondaryLabelColor
        addRow([importButton, importSpinner, importStatusLabel], spacing: 10)
        addFullWidth(explanation(String(localized: "Imports your full Last.fm scrobble history into the local database so the Recap and Year in Music cover everything you've ever played.")))
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
        NotificationCenter.default.addObserver(
            self, selector: #selector(authChanged), name: LastFMService.authDidChange, object: nil
        )
        importObserver = viewModel.importStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.renderImportState(state)
            }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        NotificationCenter.default.removeObserver(self)
        importObserver = nil
    }

    @objc func authChanged() {
        refresh()
    }

    func refresh() {
        let service = LastFMService.shared
        let authenticated = service.isAuthenticated
        statusLabel.stringValue = authenticated
            ? String(localized: "Connected as \(service.username ?? String(localized: "unknown"))")
            : String(localized: "Not connected")
        connectButton.isHidden = authenticated
        profileButton.isHidden = !authenticated
        disconnectButton.isHidden = !authenticated
        importButton.isEnabled = authenticated

        let pending = (try? DatabaseManager.shared.fetchPendingScrobbles().count) ?? 0
        pendingLabel.stringValue = pending == 0
            ? String(localized: "No pending scrobbles")
            : String(localized: "\(pending) scrobbles waiting to submit")
        retryButton.isHidden = pending == 0
    }

    func renderImportState(_ state: RecapImportState) {
        switch state {
        case .importing(let imported):
            importSpinner.startAnimation(nil)
            importButton.isEnabled = false
            importStatusLabel.stringValue = imported > 0
                ? String(localized: "Importing… \(RecapFormat.count(imported)) scrobbles")
                : String(localized: "Importing…")
        case .done(let imported):
            importSpinner.stopAnimation(nil)
            importButton.isEnabled = LastFMService.shared.isAuthenticated
            importStatusLabel.stringValue = imported > 0
                ? String(localized: "Imported \(RecapFormat.count(imported)) scrobbles")
                : String(localized: "History already imported")
        case .available:
            importSpinner.stopAnimation(nil)
            importButton.isEnabled = LastFMService.shared.isAuthenticated
            importStatusLabel.stringValue = ""
        case .unavailable:
            importSpinner.stopAnimation(nil)
            importButton.isEnabled = false
            importStatusLabel.stringValue = String(localized: "Connect Last.fm first")
        }
    }

    @objc func connectTapped() {
        guard let window = view.window ?? NSApp.keyWindow ?? NSApp.windows.first else {
            MidgarLog.error("Last.fm connect tapped with no window to anchor sign-in to", category: .auth)
            return
        }
        Task { [weak self] in
            do {
                try await LastFMService.shared.authenticate(from: window)
                MacToast.show(String(localized: "Connected to Last.fm"), style: .success, in: self?.view.window)
            } catch {
                if let authError = error as? ASWebAuthenticationSessionError,
                   authError.code == .canceledLogin {
                    return
                }
                MidgarLog.error("Last.fm authentication failed: \(error.localizedDescription)", category: .auth)
                let message = (error as? LastFMError)?.errorDescription
                    ?? String(localized: "Couldn't connect to Last.fm: \(error.localizedDescription)")
                MacToast.show(message, style: .error, in: self?.view.window)
            }
        }
    }

    @objc func profileTapped() {
        guard let username = LastFMService.shared.username,
              let url = URL(string: "https://www.last.fm/user/\(username)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func disconnectTapped() {
        LastFMService.shared.logout()
    }

    @objc func retryTapped() {
        Task { [weak self] in
            await AudioPlayer.shared.retryPendingScrobbles()
            self?.refresh()
        }
    }

    @objc func importTapped() {
        viewModel.importHistory()
    }
}
