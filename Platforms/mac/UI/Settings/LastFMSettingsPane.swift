import AppKit
import MidgarCore
import AuthenticationServices
import Combine
import FlaccyCore
import MidgarPortal
import ServiceManagement
import UserNotifications

/// Last.fm: connect/disconnect, profile, pending scrobbles, history sync.
final class LastFMSettingsPane: SettingsPane {

    let statusLabel = NSTextField(labelWithString: "")
    let connectButton = NSButton(title: String(localized: "Connect Last.fm…"), target: nil, action: nil)
    let profileButton = NSButton(title: String(localized: "View Profile"), target: nil, action: nil)
    let disconnectButton = NSButton(title: String(localized: "Disconnect"), target: nil, action: nil)
    let pendingLabel = NSTextField(labelWithString: "")
    let retryButton = NSButton(title: String(localized: "Retry Now"), target: nil, action: nil)
    let syncButton = NSButton(title: String(localized: "Sync Now"), target: nil, action: nil)
    let syncStatusLabel = NSTextField(labelWithString: "")
    let syncSpinner = NSProgressIndicator()
    var syncObserver: AnyCancellable?

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
        syncButton.bezelStyle = .rounded
        syncButton.target = self
        syncButton.action = #selector(syncTapped)
        syncSpinner.style = .spinning
        syncSpinner.controlSize = .small
        syncSpinner.isDisplayedWhenStopped = false
        syncStatusLabel.font = .systemFont(ofSize: 12)
        syncStatusLabel.textColor = .secondaryLabelColor
        addRow([syncButton, syncSpinner, syncStatusLabel], spacing: 10)
        addFullWidth(explanation(String(localized: "Flaccy and Last.fm share one listening history. Every scrobble on your account, from Flaccy or any other app or device, flows into Stats, play counts and Most Played, and keeps flowing on its own.")))
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
        NotificationCenter.default.addObserver(
            self, selector: #selector(authChanged), name: LastFMService.authDidChange, object: nil
        )
        syncObserver = ListenHistorySync.shared.statusPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.renderSyncStatus(status)
            }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        NotificationCenter.default.removeObserver(self)
        syncObserver = nil
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

        let pending = (try? DatabaseManager.shared.fetchPendingScrobbles().count) ?? 0
        pendingLabel.stringValue = pending == 0
            ? String(localized: "No pending scrobbles")
            : String(localized: "\(pending) scrobbles waiting to submit")
        retryButton.isHidden = pending == 0
    }

    func renderSyncStatus(_ status: ListenHistoryStatus) {
        if status.isBusy {
            syncSpinner.startAnimation(nil)
        } else {
            syncSpinner.stopAnimation(nil)
        }
        syncButton.isEnabled = status != .notConnected && !status.isBusy
        syncStatusLabel.stringValue = status.summary
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

    @objc func syncTapped() {
        ListenHistorySync.shared.syncNow()
    }
}
