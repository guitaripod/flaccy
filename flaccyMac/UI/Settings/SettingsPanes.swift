import AppKit
import MidgarCore
import AuthenticationServices
import Combine
import FlaccyCore
import MidgarPortal
import ServiceManagement
import UserNotifications

extension Notification.Name {
    static let flaccyMenuBarExtraSettingChanged = Notification.Name("flaccy.mac.menuBarExtraChanged")
}

/// The one deep link into System Settings the app ever needs: Flaccy's own
/// notification switch, for the recap and the trial reminders alike.
enum MacSystemSettings {
    static func openNotifications() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

enum MenuBarExtraSetting {
    static let key = "flaccy.mac.menuBarExtra"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    static func set(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key)
        NotificationCenter.default.post(name: .flaccyMenuBarExtraSettingChanged, object: nil)
    }
}

/// General: entitlement status, playback behavior, launch and menu-bar
/// preferences.
final class GeneralSettingsPane: SettingsPane {

    let entitlementLabel = NSTextField(wrappingLabelWithString: "")
    let unlockButton = NSButton(title: String(localized: "Get Lifetime…"), target: nil, action: nil)
    let restoreButton = NSButton(title: String(localized: "Restore Purchases"), target: nil, action: nil)
    let manageButton = NSButton(title: String(localized: "Manage Subscription…"), target: nil, action: nil)
    let restoreSpinner = NSProgressIndicator()
    let remindersCheckbox = NSButton(checkboxWithTitle: String(localized: "Trial reminders"), target: nil, action: nil)
    let remindersExplanation = NSTextField(wrappingLabelWithString: "")
    let autoplayCheckbox = NSButton(checkboxWithTitle: String(localized: "Keep the music going when the queue ends"), target: nil, action: nil)
    let loginCheckbox = NSButton(checkboxWithTitle: String(localized: "Open Flaccy at login"), target: nil, action: nil)
    let menuBarCheckbox = NSButton(checkboxWithTitle: String(localized: "Show Flaccy in the menu bar"), target: nil, action: nil)
    let scaleStepper = NSStepper()
    let scaleLabel = NSTextField(labelWithString: "")
    var isRestoring = false

    override func buildForm() {
        addMidgarEntry()
        formStack.addArrangedSubview(sectionLabel(String(localized: "Appearance")))
        scaleLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        scaleStepper.minValue = Double(MacInterfaceScale.minimum * 100)
        scaleStepper.maxValue = Double(MacInterfaceScale.maximum * 100)
        scaleStepper.increment = Double(MacInterfaceScale.step * 100)
        scaleStepper.target = self
        scaleStepper.action = #selector(scaleStepped)
        let scaleTitle = NSTextField(labelWithString: String(localized: "Interface scale"))
        scaleTitle.font = .systemFont(ofSize: 13)
        addRow([scaleTitle, scaleLabel, scaleStepper], spacing: 8)
        addFullWidth(explanation(String(localized: "Zoom the whole window. ⌘= and ⌘- work anywhere; ⌘0 returns to actual size.")))
        renderScale()
        formStack.addArrangedSubview(separator())

        formStack.addArrangedSubview(sectionLabel(String(localized: "Flaccy Lifetime")))
        entitlementLabel.font = .systemFont(ofSize: 13)
        addFullWidth(entitlementLabel)
        unlockButton.bezelStyle = .rounded
        unlockButton.target = self
        unlockButton.action = #selector(unlockTapped)
        restoreButton.bezelStyle = .rounded
        restoreButton.target = self
        restoreButton.action = #selector(restoreTapped)
        manageButton.bezelStyle = .rounded
        manageButton.target = self
        manageButton.action = #selector(manageTapped)
        restoreSpinner.style = .spinning
        restoreSpinner.controlSize = .small
        restoreSpinner.isDisplayedWhenStopped = false
        addRow([unlockButton, restoreButton, manageButton, restoreSpinner], spacing: 10)
        remindersCheckbox.target = self
        remindersCheckbox.action = #selector(remindersToggled)
        formStack.addArrangedSubview(remindersCheckbox)
        remindersExplanation.stringValue = String(localized: "Three reminders at most: two days before your trial ends, on the last day, and once if a welcome-back price becomes available.")
        remindersExplanation.font = .systemFont(ofSize: 11)
        remindersExplanation.textColor = .tertiaryLabelColor
        addFullWidth(remindersExplanation)
        formStack.addArrangedSubview(separator())

        formStack.addArrangedSubview(sectionLabel(String(localized: "Playback")))
        autoplayCheckbox.target = self
        autoplayCheckbox.action = #selector(autoplayToggled)
        formStack.addArrangedSubview(autoplayCheckbox)
        addFullWidth(explanation(String(localized: "When your queue runs out, Flaccy builds a station of similar music from your library instead of stopping.")))
        addFullWidth(explanation(String(localized: "Gapless playback is always on — lossless albums flow track to track with zero silence.")))
        addFullWidth(explanation(String(localized: "MP3 and AAC store a fraction of a second of encoder padding inside every file, which macOS does not strip, so those albums can still click between tracks. Re-rip to FLAC and the seam disappears.")))
        formStack.addArrangedSubview(separator())

        formStack.addArrangedSubview(sectionLabel(String(localized: "System")))
        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginToggled)
        formStack.addArrangedSubview(loginCheckbox)
        menuBarCheckbox.target = self
        menuBarCheckbox.action = #selector(menuBarToggled)
        formStack.addArrangedSubview(menuBarCheckbox)
        addFullWidth(explanation(String(localized: "The menu bar player shows the current track with transport and love controls.")))
    }

    /// The Midgar portal doorway sits above everything else in Settings, at the
    /// card's own fixed height, followed by the same rule that divides every
    /// other section.
    func addMidgarEntry() {
        let entry = MidgarEntryView(config: FlaccyMidgar.shared.portalConfig)
        addFullWidth(entry)
        entry.heightAnchor.constraint(equalToConstant: MidgarEntryView.preferredHeight).isActive = true
        formStack.addArrangedSubview(separator())
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        renderScale()
        NotificationCenter.default.addObserver(
            self, selector: #selector(scaleChanged), name: .flaccyInterfaceScaleChanged, object: nil
        )
        refreshEntitlement()
        autoplayCheckbox.state = AudioPlayer.shared.autoplaySimilarWhenQueueEnds ? .on : .off
        loginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menuBarCheckbox.state = MenuBarExtraSetting.isEnabled ? .on : .off
        NotificationCenter.default.addObserver(
            self, selector: #selector(entitlementChanged), name: PurchaseManager.stateDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(entitlementChanged), name: PurchaseManager.entitlementsDidLoad, object: nil
        )
        Task { [weak self] in
            await PurchaseManager.shared.loadOffersIfNeeded()
            await PurchaseManager.shared.loadLapsedOfferIfNeeded()
            self?.refreshEntitlement()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        NotificationCenter.default.removeObserver(self)
    }

    @objc func entitlementChanged() {
        refreshEntitlement()
    }

    func refreshEntitlement() {
        let manager = PurchaseManager.shared
        let state = manager.state
        entitlementLabel.stringValue = PaywallCopy.settingsSentence(state: state, lifetime: manager.lifetimeOfferToPresent)
            ?? Self.purchasedSentence(state: state)
        unlockButton.isHidden = state.isPurchased
        restoreButton.isHidden = state.isPurchased
        manageButton.isHidden = state != .purchased(.yearly)
        refreshRemindersRow(state: state)
    }

    static func purchasedSentence(state: EntitlementState) -> String {
        switch state {
        case .purchased(.yearly):
            return String(localized: "Flaccy Pro — yearly. Thank you.")
        case .purchased(.lifetime), .trialNotStarted, .trial, .expired:
            return String(localized: "Lifetime unlocked. Thank you.")
        }
    }

    /// The reminders switch stays while a trial can still use it, and lingers
    /// after a purchase only as long as a `trial.*` request is still pending,
    /// so nothing can fire that the reader cannot see and turn off.
    func refreshRemindersRow(state: EntitlementState) {
        let scheduler = TrialReminderScheduler.shared
        remindersCheckbox.state = scheduler.isEnabled ? .on : .off
        guard state.isPurchased else {
            setRemindersRow(visible: true)
            return
        }
        Task { [weak self] in
            let pending = await scheduler.hasPendingRequests()
            self?.setRemindersRow(visible: pending)
        }
    }

    func setRemindersRow(visible: Bool) {
        remindersCheckbox.isHidden = !visible
        remindersExplanation.isHidden = !visible
    }

    @objc func unlockTapped() {
        PurchaseManager.shared.requestPaywall()
    }

    @objc func restoreTapped() {
        guard !isRestoring else { return }
        isRestoring = true
        restoreButton.isEnabled = false
        restoreSpinner.startAnimation(nil)
        Task { [weak self] in
            let outcome = await PurchaseManager.shared.restore()
            guard let self else { return }
            self.isRestoring = false
            self.restoreButton.isEnabled = true
            self.restoreSpinner.stopAnimation(nil)
            self.showRestoreOutcome(outcome)
        }
    }

    func showRestoreOutcome(_ outcome: PurchaseManager.RestoreOutcome) {
        switch outcome {
        case .restored:
            let lifetime = PurchaseManager.shared.state == .purchased(.lifetime)
            MacToast.show(
                lifetime ? String(localized: "You own Flaccy. Thank you.") : String(localized: "Purchase restored"),
                style: .success, in: view.window
            )
        case .nothingToRestore:
            MacToast.show(String(localized: "No previous purchase was found for this Apple Account."), style: .info, in: view.window)
        case .cancelled:
            break
        case .failed:
            MacToast.show(String(localized: "Couldn't reach the App Store. Check your connection and try again."), style: .error, in: view.window)
        }
    }

    @objc func manageTapped() {
        guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else { return }
        NSWorkspace.shared.open(url)
    }

    /// A decision made here counts as the consent question answered, so the
    /// completed-play alert never asks someone who already chose in Settings.
    @objc func remindersToggled() {
        let scheduler = TrialReminderScheduler.shared
        scheduler.markAsked()
        guard remindersCheckbox.state == .on else {
            scheduler.disable()
            return
        }
        remindersCheckbox.isEnabled = false
        Task { [weak self] in
            let enabled = await scheduler.enable()
            guard let self else { return }
            self.remindersCheckbox.isEnabled = true
            guard !enabled else { return }
            self.remindersCheckbox.state = .off
            MacToast.show(PaywallCopy.notificationsOffHint, style: .info, in: self.view.window)
            MacSystemSettings.openNotifications()
        }
    }

    func renderScale() {
        scaleLabel.stringValue = "\(MacInterfaceScale.percent)%"
        scaleStepper.doubleValue = Double(MacInterfaceScale.percent)
    }

    @objc func scaleChanged() {
        renderScale()
    }

    @objc func scaleStepped() {
        MacInterfaceScale.set(CGFloat(scaleStepper.doubleValue) / 100)
    }

    @objc func autoplayToggled() {
        AudioPlayer.shared.autoplaySimilarWhenQueueEnds = autoplayCheckbox.state == .on
    }

    @objc func loginToggled() {
        do {
            if loginCheckbox.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            MidgarLog.error("Login item change failed: \(error.localizedDescription)", category: .general)
            loginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }

    @objc func menuBarToggled() {
        MenuBarExtraSetting.set(menuBarCheckbox.state == .on)
    }
}
