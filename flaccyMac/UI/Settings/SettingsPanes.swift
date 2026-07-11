import AppKit
import AuthenticationServices
import Combine
import ServiceManagement
import UserNotifications

extension Notification.Name {
    static let flaccyMenuBarExtraSettingChanged = Notification.Name("flaccy.mac.menuBarExtraChanged")
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

    private let entitlementLabel = NSTextField(labelWithString: "")
    private let unlockButton = NSButton(title: "Unlock Lifetime…", target: nil, action: nil)
    private let autoplayCheckbox = NSButton(checkboxWithTitle: "Keep the music going when the queue ends", target: nil, action: nil)
    private let loginCheckbox = NSButton(checkboxWithTitle: "Open Flaccy at login", target: nil, action: nil)
    private let menuBarCheckbox = NSButton(checkboxWithTitle: "Show Flaccy in the menu bar", target: nil, action: nil)

    override func buildForm() {
        formStack.addArrangedSubview(sectionLabel("Flaccy Lifetime"))
        entitlementLabel.font = .systemFont(ofSize: 13)
        unlockButton.bezelStyle = .rounded
        unlockButton.target = self
        unlockButton.action = #selector(unlockTapped)
        addRow([entitlementLabel, unlockButton], spacing: 12)
        formStack.addArrangedSubview(separator())

        formStack.addArrangedSubview(sectionLabel("Playback"))
        autoplayCheckbox.target = self
        autoplayCheckbox.action = #selector(autoplayToggled)
        formStack.addArrangedSubview(autoplayCheckbox)
        addFullWidth(explanation("When your queue runs out, Flaccy builds a station of similar music from your library instead of stopping."))
        addFullWidth(explanation("Gapless playback is always on — FLAC albums flow track to track with zero silence."))
        formStack.addArrangedSubview(separator())

        formStack.addArrangedSubview(sectionLabel("System"))
        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginToggled)
        formStack.addArrangedSubview(loginCheckbox)
        menuBarCheckbox.target = self
        menuBarCheckbox.action = #selector(menuBarToggled)
        formStack.addArrangedSubview(menuBarCheckbox)
        addFullWidth(explanation("The menu bar player shows the current track with transport and love controls."))
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshEntitlement()
        autoplayCheckbox.state = AudioPlayer.shared.autoplaySimilarWhenQueueEnds ? .on : .off
        loginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menuBarCheckbox.state = MenuBarExtraSetting.isEnabled ? .on : .off
        NotificationCenter.default.addObserver(
            self, selector: #selector(entitlementChanged), name: PurchaseManager.stateDidChange, object: nil
        )
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func entitlementChanged() {
        refreshEntitlement()
    }

    private func refreshEntitlement() {
        switch PurchaseManager.shared.state {
        case .purchased:
            entitlementLabel.stringValue = "Lifetime unlocked. Thank you."
            unlockButton.isHidden = true
        case .trial(let daysRemaining):
            entitlementLabel.stringValue = daysRemaining == 1
                ? "Trial — 1 day left"
                : "Trial — \(daysRemaining) days left"
            unlockButton.isHidden = false
        case .expired:
            entitlementLabel.stringValue = "Trial ended — playback is locked"
            unlockButton.isHidden = false
        }
    }

    @objc private func unlockTapped() {
        PurchaseManager.shared.requestPaywall()
    }

    @objc private func autoplayToggled() {
        AudioPlayer.shared.autoplaySimilarWhenQueueEnds = autoplayCheckbox.state == .on
    }

    @objc private func loginToggled() {
        do {
            if loginCheckbox.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            AppLogger.error("Login item change failed: \(error.localizedDescription)", category: .general)
            loginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }

    @objc private func menuBarToggled() {
        MenuBarExtraSetting.set(menuBarCheckbox.state == .on)
    }
}

/// Last.fm: connect/disconnect, profile, pending scrobbles, history import.
final class LastFMSettingsPane: SettingsPane {

    private let statusLabel = NSTextField(labelWithString: "")
    private let connectButton = NSButton(title: "Connect Last.fm…", target: nil, action: nil)
    private let profileButton = NSButton(title: "View Profile", target: nil, action: nil)
    private let disconnectButton = NSButton(title: "Disconnect", target: nil, action: nil)
    private let pendingLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Retry Now", target: nil, action: nil)
    private let importButton = NSButton(title: "Import History", target: nil, action: nil)
    private let importStatusLabel = NSTextField(labelWithString: "")
    private let importSpinner = NSProgressIndicator()
    private let viewModel = ChartsViewModel()
    private var importObserver: AnyCancellable?

    override func buildForm() {
        formStack.addArrangedSubview(sectionLabel("Account"))
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
        addFullWidth(explanation("Scrobbles every play, keeps an offline queue, and powers the Recap, Wantlist, and loved tracks."))
        formStack.addArrangedSubview(separator())

        formStack.addArrangedSubview(sectionLabel("Scrobbles"))
        pendingLabel.font = .systemFont(ofSize: 13)
        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .small
        retryButton.target = self
        retryButton.action = #selector(retryTapped)
        addRow([pendingLabel, retryButton], spacing: 10)
        formStack.addArrangedSubview(separator())

        formStack.addArrangedSubview(sectionLabel("History"))
        importButton.bezelStyle = .rounded
        importButton.target = self
        importButton.action = #selector(importTapped)
        importSpinner.style = .spinning
        importSpinner.controlSize = .small
        importSpinner.isDisplayedWhenStopped = false
        importStatusLabel.font = .systemFont(ofSize: 12)
        importStatusLabel.textColor = .secondaryLabelColor
        addRow([importButton, importSpinner, importStatusLabel], spacing: 10)
        addFullWidth(explanation("Imports your full Last.fm scrobble history into the local database so the Recap and Year in Music cover everything you've ever played."))
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

    @objc private func authChanged() {
        refresh()
    }

    private func refresh() {
        let service = LastFMService.shared
        let authenticated = service.isAuthenticated
        statusLabel.stringValue = authenticated
            ? "Connected as \(service.username ?? "unknown")"
            : "Not connected"
        connectButton.isHidden = authenticated
        profileButton.isHidden = !authenticated
        disconnectButton.isHidden = !authenticated
        importButton.isEnabled = authenticated

        let pending = (try? DatabaseManager.shared.fetchPendingScrobbles().count) ?? 0
        pendingLabel.stringValue = pending == 0
            ? "No pending scrobbles"
            : "\(pending) scrobble\(pending == 1 ? "" : "s") waiting to submit"
        retryButton.isHidden = pending == 0
    }

    private func renderImportState(_ state: RecapImportState) {
        switch state {
        case .importing(let imported):
            importSpinner.startAnimation(nil)
            importButton.isEnabled = false
            importStatusLabel.stringValue = imported > 0
                ? "Importing… \(RecapFormat.count(imported)) scrobbles"
                : "Importing…"
        case .done(let imported):
            importSpinner.stopAnimation(nil)
            importButton.isEnabled = LastFMService.shared.isAuthenticated
            importStatusLabel.stringValue = imported > 0
                ? "Imported \(RecapFormat.count(imported)) scrobbles"
                : "History already imported"
        case .available:
            importSpinner.stopAnimation(nil)
            importButton.isEnabled = LastFMService.shared.isAuthenticated
            importStatusLabel.stringValue = ""
        case .unavailable:
            importSpinner.stopAnimation(nil)
            importButton.isEnabled = false
            importStatusLabel.stringValue = "Connect Last.fm first"
        }
    }

    @objc private func connectTapped() {
        guard let window = view.window else { return }
        connectButton.isEnabled = false
        Task { [weak self] in
            defer { self?.connectButton.isEnabled = true }
            do {
                try await LastFMService.shared.authenticate(from: window)
                MacToast.show("Connected to Last.fm", style: .success, in: self?.view.window)
            } catch {
                if let authError = error as? ASWebAuthenticationSessionError,
                   authError.code == .canceledLogin {
                    return
                }
                AppLogger.error("Last.fm authentication failed: \(error.localizedDescription)", category: .auth)
                MacToast.show("Couldn't connect to Last.fm.", style: .error, in: self?.view.window)
            }
        }
    }

    @objc private func profileTapped() {
        guard let username = LastFMService.shared.username,
              let url = URL(string: "https://www.last.fm/user/\(username)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func disconnectTapped() {
        LastFMService.shared.logout()
    }

    @objc private func retryTapped() {
        Task { [weak self] in
            await AudioPlayer.shared.retryPendingScrobbles()
            self?.refresh()
        }
    }

    @objc private func importTapped() {
        viewModel.importHistory()
    }
}

/// Recap & Notifications: cadence, delivery time, and the permission banner.
final class NotificationsSettingsPane: SettingsPane {

    private let frequencyPopUp = NSPopUpButton()
    private let timePicker = NSDatePicker()
    private let weekdayPopUp = NSPopUpButton()
    private let monthDayPopUp = NSPopUpButton()
    private let weekdayRow = NSStackView()
    private let monthDayRow = NSStackView()
    private let nextDeliveryLabel = NSTextField(labelWithString: "")
    private let deniedBanner = NSStackView()
    private let scheduler = MacRecapNotificationScheduler.shared

    override func buildForm() {
        buildDeniedBanner()
        formStack.addArrangedSubview(deniedBanner)
        deniedBanner.isHidden = true

        formStack.addArrangedSubview(sectionLabel("Recap Notifications"))
        for frequency in RecapNotificationFrequency.allCases {
            frequencyPopUp.addItem(withTitle: frequency.displayName)
        }
        frequencyPopUp.target = self
        frequencyPopUp.action = #selector(frequencyChanged)
        addRow([label("Frequency"), frequencyPopUp])

        timePicker.datePickerStyle = .textFieldAndStepper
        timePicker.datePickerElements = .hourMinute
        timePicker.target = self
        timePicker.action = #selector(timeChanged)
        addRow([label("Deliver at"), timePicker])

        let weekdays = Calendar.current.standaloneWeekdaySymbols
        for name in weekdays {
            weekdayPopUp.addItem(withTitle: name)
        }
        weekdayPopUp.target = self
        weekdayPopUp.action = #selector(weekdayChanged)
        weekdayRow.orientation = .horizontal
        weekdayRow.spacing = 8
        weekdayRow.addArrangedSubview(label("On"))
        weekdayRow.addArrangedSubview(weekdayPopUp)
        formStack.addArrangedSubview(weekdayRow)

        for day in 1...28 {
            monthDayPopUp.addItem(withTitle: "Day \(day)")
        }
        monthDayPopUp.target = self
        monthDayPopUp.action = #selector(monthDayChanged)
        monthDayRow.orientation = .horizontal
        monthDayRow.spacing = 8
        monthDayRow.addArrangedSubview(label("On"))
        monthDayRow.addArrangedSubview(monthDayPopUp)
        formStack.addArrangedSubview(monthDayRow)

        nextDeliveryLabel.font = .systemFont(ofSize: 11)
        nextDeliveryLabel.textColor = .secondaryLabelColor
        formStack.addArrangedSubview(nextDeliveryLabel)
        formStack.addArrangedSubview(separator())
        addFullWidth(explanation("A yearly Year in Music drop is always scheduled for December 1st while notifications are on."))
    }

    private func buildDeniedBanner() {
        deniedBanner.orientation = .horizontal
        deniedBanner.alignment = .centerY
        deniedBanner.spacing = 10
        deniedBanner.wantsLayer = true
        deniedBanner.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.15).cgColor
        deniedBanner.layer?.cornerRadius = 10
        deniedBanner.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        let icon = NSImageView(image: NSImage(
            systemSymbolName: "bell.slash.fill", accessibilityDescription: nil
        ) ?? NSImage())
        icon.contentTintColor = .systemRed
        let text = NSTextField(wrappingLabelWithString: "Notifications are turned off for Flaccy in System Settings.")
        text.font = .systemFont(ofSize: 12)
        let openButton = NSButton(title: "Open System Settings", target: self, action: #selector(openSystemSettings))
        openButton.bezelStyle = .rounded
        openButton.controlSize = .small
        deniedBanner.addArrangedSubview(icon)
        deniedBanner.addArrangedSubview(text)
        deniedBanner.addArrangedSubview(openButton)
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        return label
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    private func refresh() {
        let frequency = scheduler.frequency
        frequencyPopUp.selectItem(at: RecapNotificationFrequency.allCases.firstIndex(of: frequency) ?? 0)
        var components = DateComponents()
        components.hour = scheduler.deliveryHour
        components.minute = scheduler.deliveryMinute
        timePicker.dateValue = Calendar.current.date(from: components) ?? Date()
        weekdayPopUp.selectItem(at: scheduler.weeklyWeekday - 1)
        monthDayPopUp.selectItem(at: scheduler.monthlyDay - 1)

        weekdayRow.isHidden = frequency != .weekly
        monthDayRow.isHidden = frequency != .monthly
        timePicker.isEnabled = frequency != .off
        renderNextDelivery()
        Task { [weak self] in
            let status = await MacRecapNotificationScheduler.shared.authorizationStatus()
            self?.deniedBanner.isHidden = status != .denied
        }
    }

    private func renderNextDelivery() {
        if let next = scheduler.nextDeliveryDate() {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            nextDeliveryLabel.stringValue = "Next recap: \(formatter.string(from: next))"
        } else {
            nextDeliveryLabel.stringValue = ""
        }
    }

    @objc private func frequencyChanged() {
        let index = frequencyPopUp.indexOfSelectedItem
        guard index >= 0, index < RecapNotificationFrequency.allCases.count else { return }
        let frequency = RecapNotificationFrequency.allCases[index]
        Task { [weak self] in
            let granted = await MacRecapNotificationScheduler.shared.setFrequency(frequency)
            if !granted {
                self?.deniedBanner.isHidden = false
            }
            self?.refresh()
        }
    }

    @objc private func timeChanged() {
        let components = Calendar.current.dateComponents([.hour, .minute], from: timePicker.dateValue)
        scheduler.deliveryHour = components.hour ?? 19
        scheduler.deliveryMinute = components.minute ?? 0
        reschedule()
    }

    @objc private func weekdayChanged() {
        scheduler.weeklyWeekday = weekdayPopUp.indexOfSelectedItem + 1
        reschedule()
    }

    @objc private func monthDayChanged() {
        scheduler.monthlyDay = monthDayPopUp.indexOfSelectedItem + 1
        reschedule()
    }

    private func reschedule() {
        Task { [weak self] in
            await MacRecapNotificationScheduler.shared.refreshSchedule(force: true)
            self?.renderNextDelivery()
        }
    }

    @objc private func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Library: root folder, storage usage, rescan and AI re-analysis, reveals.
final class LibrarySettingsPane: SettingsPane {

    private let rootLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private let storageLabel = NSTextField(labelWithString: "Storage: …")
    private let rescanButton = NSButton(title: "Rescan Library", target: nil, action: nil)
    private let analyzeButton = NSButton(title: "Re-analyze with AI…", target: nil, action: nil)
    private let groupEditionsCheckbox = NSButton(checkboxWithTitle: "Group album editions (Deluxe, Remaster…) as one album", target: nil, action: nil)
    private let cleanUpButton = NSButton(title: "Clean Up Library…", target: nil, action: nil)
    private let workSpinner = NSProgressIndicator()
    private let workLabel = NSTextField(labelWithString: "")
    private var isWorking = false

    override func buildForm() {
        formStack.addArrangedSubview(sectionLabel("Music Folder"))
        rootLabel.font = .systemFont(ofSize: 12)
        rootLabel.lineBreakMode = .byTruncatingMiddle
        let changeButton = NSButton(title: "Change…", target: self, action: #selector(changeFolder))
        changeButton.bezelStyle = .rounded
        changeButton.controlSize = .small
        let resetButton = NSButton(title: "Use Default", target: self, action: #selector(resetFolder))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        addRow([rootLabel, changeButton, resetButton], spacing: 10)
        rootLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        addFullWidth(explanation("Flaccy indexes the folder in place — nothing is copied or moved. Files added to the folder appear automatically."))
        formStack.addArrangedSubview(separator())

        formStack.addArrangedSubview(sectionLabel("Library"))
        statsLabel.font = .systemFont(ofSize: 13)
        storageLabel.font = .systemFont(ofSize: 13)
        formStack.addArrangedSubview(statsLabel)
        formStack.addArrangedSubview(storageLabel)

        rescanButton.bezelStyle = .rounded
        rescanButton.target = self
        rescanButton.action = #selector(rescanTapped)
        analyzeButton.bezelStyle = .rounded
        analyzeButton.target = self
        analyzeButton.action = #selector(analyzeTapped)
        workSpinner.style = .spinning
        workSpinner.controlSize = .small
        workSpinner.isDisplayedWhenStopped = false
        workLabel.font = .systemFont(ofSize: 12)
        workLabel.textColor = .secondaryLabelColor
        addRow([rescanButton, analyzeButton, workSpinner, workLabel], spacing: 10)
        addFullWidth(explanation("Re-analyze sends track filenames through Flaccy's AI to clean up titles, artists, and album grouping. It can take a few minutes for large libraries."))
        formStack.addArrangedSubview(separator())

        formStack.addArrangedSubview(sectionLabel("Tidy Up"))
        groupEditionsCheckbox.target = self
        groupEditionsCheckbox.action = #selector(groupEditionsToggled)
        formStack.addArrangedSubview(groupEditionsCheckbox)
        addFullWidth(explanation("Collapses \u{201C}Album\u{201D}, \u{201C}Album (Deluxe)\u{201D} and \u{201C}Album (Remastered)\u{201D} into one card so the wall isn\u{2019}t cluttered with near-duplicates."))
        cleanUpButton.bezelStyle = .rounded
        cleanUpButton.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        cleanUpButton.imagePosition = .imageLeading
        cleanUpButton.target = self
        cleanUpButton.action = #selector(cleanUpTapped)
        addRow([cleanUpButton], spacing: 12)
        addFullWidth(explanation("Finds duplicate tracks and merges album editions. You\u{2019}ll see exactly what changes before anything happens; removed duplicates go to the Trash."))
        formStack.addArrangedSubview(separator())

        formStack.addArrangedSubview(sectionLabel("Reveal"))
        let revealLibrary = NSButton(title: "Show Library in Finder", target: self, action: #selector(revealLibrary))
        revealLibrary.bezelStyle = .rounded
        let revealLogs = NSButton(title: "Show Logs in Finder", target: self, action: #selector(revealLogs))
        revealLogs.bezelStyle = .rounded
        addRow([revealLibrary, revealLogs], spacing: 10)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
        groupEditionsCheckbox.state = GroupAlbumEditionsSetting.isEnabled ? .on : .off
        NotificationCenter.default.addObserver(
            self, selector: #selector(libraryChanged), name: Library.didUpdateNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(libraryChanged), name: LibraryRoot.didChange, object: nil
        )
    }

    @objc private func groupEditionsToggled() {
        GroupAlbumEditionsSetting.set(groupEditionsCheckbox.state == .on)
    }

    @objc private func cleanUpTapped() {
        LibraryCleanup.run(in: view.window)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func libraryChanged() {
        refresh()
    }

    private func refresh() {
        rootLabel.stringValue = LibraryRoot.current.path
        rootLabel.toolTip = LibraryRoot.current.path
        let albums = Library.shared.albums.count
        let tracks = Library.shared.allTracks.count
        statsLabel.stringValue = "\(albums) album\(albums == 1 ? "" : "s") · \(tracks) track\(tracks == 1 ? "" : "s")"
        refreshStorage()
    }

    private func refreshStorage() {
        let root = LibraryRoot.current
        Task.detached(priority: .utility) { [weak self] in
            let size = Self.folderSize(root)
            await MainActor.run { [weak self] in
                self?.storageLabel.stringValue = "Storage: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
            }
        }
    }

    private nonisolated static func folderSize(_ root: URL) -> Int64 {
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        for case let fileURL as URL in enumerator {
            if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    @objc private func changeFolder() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try LibraryRoot.shared.chooseFolder(url)
                self?.refresh()
            } catch {
                AppLogger.error("Bookmark creation failed: \(error.localizedDescription)", category: .content)
                MacToast.show("Couldn't access that folder.", style: .error, in: self?.view.window)
            }
        }
    }

    @objc private func resetFolder() {
        LibraryRoot.shared.resetToDefault()
        refresh()
    }

    @objc private func rescanTapped() {
        guard !isWorking else { return }
        runWork(label: "Rescanning…") {
            await Library.shared.reload()
        }
    }

    @objc private func analyzeTapped() {
        guard !isWorking, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Re-analyze Library with AI"
        alert.informativeText = "This re-analyzes every track's metadata with AI and rewrites titles, artists, and album grouping in the database. It may take a few minutes for large libraries."
        alert.addButton(withTitle: "Re-analyze")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.runWork(label: "Re-analyzing with AI…") {
                await Library.shared.resetAndReload()
            }
        }
    }

    private func runWork(label: String, _ work: @escaping () async -> Void) {
        isWorking = true
        rescanButton.isEnabled = false
        analyzeButton.isEnabled = false
        workSpinner.startAnimation(nil)
        workLabel.stringValue = label
        Task { [weak self] in
            await work()
            guard let self else { return }
            self.isWorking = false
            self.rescanButton.isEnabled = true
            self.analyzeButton.isEnabled = true
            self.workSpinner.stopAnimation(nil)
            self.workLabel.stringValue = "Done"
            self.refresh()
        }
    }

    @objc private func revealLibrary() {
        NSWorkspace.shared.activateFileViewerSelecting([LibraryRoot.current])
    }

    @objc private func revealLogs() {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([logs])
    }
}

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
        let versionLabel = NSTextField(labelWithString: "Version \(version) (\(build))")
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor

        let tagline = NSTextField(labelWithString: "Own your music. Forever.")
        tagline.font = .systemFont(ofSize: 13)

        let header = NSStackView(views: [icon, name, versionLabel, tagline])
        header.orientation = .vertical
        header.alignment = .centerX
        header.spacing = 6
        formStack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: formStack.widthAnchor, constant: -56).isActive = true

        formStack.addArrangedSubview(separator())
        addFullWidth(explanation("Built with GRDB (SQLite), lyrics from lrclib.net, universal links by Songlink/Odesli, and scrobbling via the Last.fm API."))

        let privacy = NSButton(title: "Privacy Policy", target: self, action: #selector(openPrivacy))
        privacy.bezelStyle = .rounded
        let terms = NSButton(title: "Terms of Use", target: self, action: #selector(openTerms))
        terms.bezelStyle = .rounded
        addRow([privacy, terms], spacing: 10)

        let copyright = explanation("© 2026 Midgar Oy")
        formStack.addArrangedSubview(copyright)
    }

    @objc private func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "https://mako.midgarcorp.cc/privacy/flaccy")!)
    }

    @objc private func openTerms() {
        NSWorkspace.shared.open(URL(string: "https://mako.midgarcorp.cc/terms/flaccy")!)
    }
}
