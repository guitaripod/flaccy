import AppKit
import MidgarCore
import AuthenticationServices
import Combine
import FlaccyCore
import MidgarPortal
import ServiceManagement
import UserNotifications

/// Library: root folder, storage usage, rescan and AI re-analysis, the live
/// metadata job, and reveals.
final class LibrarySettingsPane: SettingsPane {

    let rootLabel = NSTextField(labelWithString: "")
    let statsLabel = NSTextField(labelWithString: "")
    let storageLabel = NSTextField(labelWithString: String(localized: "Storage: …"))
    let rescanButton = NSButton(title: String(localized: "Rescan Library"), target: nil, action: nil)
    let analyzeButton = NSButton(title: String(localized: "Re-analyze with AI…"), target: nil, action: nil)
    let hideDuplicatesCheckbox = NSButton(checkboxWithTitle: String(localized: "Hide duplicate songs"), target: nil, action: nil)
    let groupEditionsCheckbox = NSButton(checkboxWithTitle: String(localized: "Group album editions (Deluxe, Remaster…) as one album"), target: nil, action: nil)
    let cleanUpButton = NSButton(title: String(localized: "Clean Up Library…"), target: nil, action: nil)
    let activitySpinner = NSProgressIndicator()
    let activityLabel = NSTextField(labelWithString: "")
    let activityDetail = NSTextField(labelWithString: "")
    let activityBar = NSProgressIndicator()
    let metadataCountsLabel = NSTextField(labelWithString: "")
    let metadataStatusLabel = NSTextField(labelWithString: "")
    let tryAgainButton = NSButton(title: EnrichmentJobCopy.tryAgain, target: nil, action: nil)
    let appleMusicCheckbox = NSButton(checkboxWithTitle: String(localized: "Use Apple Music artwork"), target: nil, action: nil)
    let debutLabel = NSTextField(labelWithString: "")
    lazy var debutCaveat = explanation(LibraryDebutCopy.settingsCaveat)
    var isWorking = false
    var restingActivity = ""
    var wasJobActive = false
    var knownAlbumCount = 0

    override func buildForm() {
        formStack.addArrangedSubview(sectionLabel(String(localized: "Music Folder")))
        rootLabel.font = .systemFont(ofSize: 12)
        rootLabel.lineBreakMode = .byTruncatingMiddle
        let changeButton = NSButton(title: String(localized: "Change…"), target: self, action: #selector(changeFolder))
        changeButton.bezelStyle = .rounded
        changeButton.controlSize = .small
        let resetButton = NSButton(title: String(localized: "Use Default"), target: self, action: #selector(resetFolder))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        addRow([rootLabel, changeButton, resetButton], spacing: 10)
        rootLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        addFullWidth(explanation(String(localized: "Flaccy indexes the folder in place — nothing is copied or moved. Files added to the folder appear automatically.")))
        formStack.addArrangedSubview(separator())

        formStack.addArrangedSubview(sectionLabel(String(localized: "Library")))
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
        buildActivityRow()
        addFullWidth(explanation(String(localized: "Re-analyze sends track filenames through Flaccy's AI to clean up titles, artists, and album grouping. It can take a few minutes for large libraries.")))
        formStack.addArrangedSubview(separator())

        buildMetadataGroup()

        formStack.addArrangedSubview(sectionLabel(String(localized: "Tidy Up")))
        groupEditionsCheckbox.target = self
        groupEditionsCheckbox.action = #selector(groupEditionsToggled)
        formStack.addArrangedSubview(groupEditionsCheckbox)
        addFullWidth(explanation(String(localized: "Collapses \u{201C}Album\u{201D}, \u{201C}Album (Deluxe)\u{201D} and \u{201C}Album (Remastered)\u{201D} into one card and keeps a single best-quality copy of each shared song so Albums and Songs stay free of near-duplicates.")))
        hideDuplicatesCheckbox.target = self
        hideDuplicatesCheckbox.action = #selector(hideDuplicatesToggled)
        formStack.addArrangedSubview(hideDuplicatesCheckbox)
        addFullWidth(explanation(String(localized: "Lists a song once when it sits on several albums, such as a single and the album it came from. Your files stay untouched.")))
        cleanUpButton.bezelStyle = .rounded
        cleanUpButton.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        cleanUpButton.imagePosition = .imageLeading
        cleanUpButton.target = self
        cleanUpButton.action = #selector(cleanUpTapped)
        addRow([cleanUpButton], spacing: 12)
        addFullWidth(explanation(String(localized: "Finds duplicate tracks and merges album editions. You\u{2019}ll see exactly what changes before anything happens; removed duplicates go to the Trash.")))
        formStack.addArrangedSubview(separator())

        formStack.addArrangedSubview(sectionLabel(String(localized: "Reveal")))
        let revealLibrary = NSButton(title: String(localized: "Show Library in Finder"), target: self, action: #selector(revealLibrary))
        revealLibrary.bezelStyle = .rounded
        let revealLogs = NSButton(title: String(localized: "Show Logs in Finder"), target: self, action: #selector(revealLogs))
        revealLogs.bezelStyle = .rounded
        addRow([revealLibrary, revealLogs], spacing: 10)
    }

    /// One row for whatever the library is doing right now: a determinate bar
    /// for the bounded disk work of a scan, and a spinner beside a countdown for
    /// the unbounded metadata job, which has no fraction to draw.
    func buildActivityRow() {
        activitySpinner.style = .spinning
        activitySpinner.controlSize = .small
        activitySpinner.isDisplayedWhenStopped = true
        activityLabel.font = .systemFont(ofSize: 12)
        activityLabel.textColor = .secondaryLabelColor
        activityDetail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        activityDetail.textColor = .tertiaryLabelColor
        activityBar.isIndeterminate = false
        activityBar.minValue = 0
        activityBar.maxValue = 1
        activityBar.controlSize = .small
        activityBar.setAccessibilityRole(.progressIndicator)
        activitySpinner.setAccessibilityRole(.progressIndicator)
        addRow([rescanButton, analyzeButton, activitySpinner, activityLabel, activityDetail], spacing: 10)
        addFullWidth(activityBar)
    }

    func buildMetadataGroup() {
        formStack.addArrangedSubview(sectionLabel(String(localized: "Metadata")))
        metadataCountsLabel.font = .systemFont(ofSize: 13)
        metadataStatusLabel.font = .systemFont(ofSize: 12)
        metadataStatusLabel.textColor = .secondaryLabelColor
        tryAgainButton.bezelStyle = .rounded
        tryAgainButton.controlSize = .small
        tryAgainButton.target = self
        tryAgainButton.action = #selector(tryAgainTapped)
        tryAgainButton.isEnabled = false
        addRow([metadataCountsLabel, tryAgainButton], spacing: 12)
        formStack.addArrangedSubview(metadataStatusLabel)
        addFullWidth(explanation(String(localized: "Re-fetch artwork and release dates for albums Flaccy gave up on.")))

        appleMusicCheckbox.target = self
        appleMusicCheckbox.action = #selector(appleMusicArtworkToggled)
        formStack.addArrangedSubview(appleMusicCheckbox)
        addFullWidth(explanation(String(localized: "Flaccy asks Apple Music for covers it can't find anywhere else. Turning this on asks for permission once.")))

        debutLabel.font = .systemFont(ofSize: 12)
        debutLabel.textColor = .secondaryLabelColor
        debutLabel.isHidden = true
        debutCaveat.isHidden = true
        formStack.addArrangedSubview(debutLabel)
        addFullWidth(debutCaveat)
        formStack.addArrangedSubview(separator())
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
        refreshMetadata()
        renderActivity()
        groupEditionsCheckbox.state = GroupAlbumEditionsSetting.isEnabled ? .on : .off
        hideDuplicatesCheckbox.state = HideDuplicateSongsSetting.isEnabled ? .on : .off
        appleMusicCheckbox.state = AppleMusicArtworkSetting.isEnabled ? .on : .off
        NotificationCenter.default.addObserver(
            self, selector: #selector(libraryChanged), name: Library.didUpdateNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(libraryChanged), name: LibraryRoot.didChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(activityChanged), name: Library.progressDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(activityChanged), name: EnrichmentCoordinator.progressDidChange, object: nil
        )
    }

    @objc func hideDuplicatesToggled() {
        HideDuplicateSongsSetting.set(hideDuplicatesCheckbox.state == .on)
    }

    @objc func groupEditionsToggled() {
        GroupAlbumEditionsSetting.set(groupEditionsCheckbox.state == .on)
    }

    @objc func cleanUpTapped() {
        LibraryCleanup.run(in: view.window)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        NotificationCenter.default.removeObserver(self)
    }

    @objc func libraryChanged() {
        refresh()
        refreshMetadata()
    }

    /// Both streams are re-read from their live sources rather than from the
    /// notification, so a delivery that arrives out of order can only ever
    /// repaint newer state.
    @objc func activityChanged() {
        renderActivity()
        let job = EnrichmentCoordinator.shared.progress
        if job.scope == .album, job.isActive {
            applyMetadataCounts(inProgress: job.remaining, gaveUp: job.exhausted)
        }
        if wasJobActive, !job.isActive {
            refreshMetadata()
        }
        wasJobActive = job.isActive
    }

    func refresh() {
        rootLabel.stringValue = LibraryRoot.current.path
        rootLabel.toolTip = LibraryRoot.current.path
        let albums = Library.shared.albums.count
        let tracks = Library.shared.allTracks.count
        statsLabel.stringValue = String(localized: "\(albums) albums · \(tracks) tracks")
        refreshStorage()
    }

    func renderActivity() {
        let load = Library.shared.loadProgress
        guard !load.isActive else {
            renderLoadActivity(load, fraction: Library.shared.loadFraction)
            return
        }
        let job = EnrichmentCoordinator.shared.progress
        guard job.isActive else {
            renderRestingActivity()
            return
        }
        renderJobActivity(job)
    }

    func renderLoadActivity(_ load: LibraryLoadProgress, fraction: Double) {
        activitySpinner.stopAnimation(nil)
        activitySpinner.isHidden = true
        activityLabel.stringValue = LibraryLoadPhaseCopy.headline(for: load.phase)
        activityDetail.stringValue = LibraryLoadPhaseCopy.detail(for: load)
        activityBar.isHidden = false
        activityBar.isIndeterminate = !load.isDeterminate
        if load.isDeterminate {
            activityBar.stopAnimation(nil)
            activityBar.doubleValue = min(1, max(0, fraction))
        } else {
            activityBar.startAnimation(nil)
        }
        activityBar.setAccessibilityValueDescription(
            LibraryLoadPhaseCopy.accessibilityValue(for: load, fraction: fraction)
        )
    }

    /// The job is counted, never measured: a spinner and a countdown, because
    /// the work behind it is unbounded and any bar drawn for it would be a lie.
    func renderJobActivity(_ job: EnrichmentJobProgress) {
        activityBar.stopAnimation(nil)
        activityBar.isHidden = true
        activitySpinner.isHidden = false
        switch job.activity {
        case .running:
            activitySpinner.startAnimation(nil)
            activityLabel.stringValue = EnrichmentJobCopy.headline(for: job.scope)
            activityDetail.stringValue = EnrichmentJobCopy.detail(remaining: job.remaining)
        case .waitingForNetwork, .dailyLimit, .serviceUnavailable:
            activitySpinner.stopAnimation(nil)
            let pause = EnrichmentJobCopy.pause(for: job)
            activityLabel.stringValue = pause.headline
            activityDetail.stringValue = pause.detail
        case .needsEntitlement:
            activitySpinner.stopAnimation(nil)
            activityLabel.stringValue = EnrichmentJobCopy.needsEntitlement
            activityDetail.stringValue = ""
        case .idle:
            renderRestingActivity()
            return
        }
        activitySpinner.setAccessibilityValueDescription(EnrichmentJobCopy.accessibilityValue(for: job))
    }

    func renderRestingActivity() {
        activitySpinner.stopAnimation(nil)
        activitySpinner.isHidden = true
        activityBar.stopAnimation(nil)
        activityBar.isHidden = true
        activityLabel.stringValue = restingActivity
        activityDetail.stringValue = ""
    }

    /// Reads the counts the job publishes from the database, for the launches
    /// where the job never runs at all — the tenth-launch case, where nothing is
    /// due and the pane still owes the reader an answer.
    func refreshMetadata() {
        let albumCount = Library.shared.albums.count
        Task.detached(priority: .utility) { [weak self] in
            let db = DatabaseManager.shared
            let scope = EnrichmentScope.album
            let inProgress = (try? db.countDue(scope: scope, version: scope.currentVersion, now: Date())) ?? 0
            let gaveUp = (try? db.countExhausted(scope: scope)) ?? 0
            let debut = try? db.libraryDebut()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.knownAlbumCount = albumCount
                self.applyMetadataCounts(inProgress: inProgress, gaveUp: gaveUp)
                self.applyDebutSummary(debut)
            }
        }
    }

    func applyMetadataCounts(inProgress: Int, gaveUp: Int) {
        let complete = max(0, knownAlbumCount - inProgress - gaveUp)
        metadataCountsLabel.stringValue = EnrichmentJobCopy.reportCounts(
            complete: complete, inProgress: inProgress, gaveUp: gaveUp
        )
        metadataStatusLabel.stringValue = EnrichmentJobCopy.settled(remaining: inProgress, gaveUp: gaveUp)
        tryAgainButton.isEnabled = gaveUp > 0
    }

    func applyDebutSummary(_ summary: LibraryDebutSummary?) {
        guard let summary else {
            debutLabel.isHidden = true
            debutCaveat.isHidden = true
            return
        }
        debutLabel.stringValue = LibraryDebutCopy.settingsSummary(
            builtOn: summary.completedAt,
            trackCount: summary.trackCount,
            aiCleanedTracks: summary.aiCleanedTracks
        )
        debutLabel.isHidden = false
        debutCaveat.isHidden = false
    }

    @objc func tryAgainTapped() {
        tryAgainButton.isEnabled = false
        Task { [weak self] in
            await EnrichmentCoordinator.shared.retryExhausted(scope: .album)
            self?.refreshMetadata()
        }
    }

    /// Turning the source on asks for permission the one time it is flipped;
    /// the checkbox reflects what was actually granted, not what was clicked.
    @objc func appleMusicArtworkToggled() {
        guard appleMusicCheckbox.state == .on else {
            AppleMusicArtworkSetting.set(false)
            return
        }
        appleMusicCheckbox.isEnabled = false
        Task { [weak self] in
            let granted = await MusicKitService.shared.enableArtworkSource()
            guard let self else { return }
            self.appleMusicCheckbox.isEnabled = true
            self.appleMusicCheckbox.state = granted ? .on : .off
            guard !granted else { return }
            MidgarLog.info("Apple Music artwork source declined", category: .content)
            MacToast.show(
                String(localized: "Flaccy needs Apple Music access to use its artwork."),
                style: .error, in: self.view.window
            )
        }
    }

    func refreshStorage() {
        let root = LibraryRoot.current
        Task.detached(priority: .utility) { [weak self] in
            let size = Self.folderSize(root)
            await MainActor.run { [weak self] in
                self?.storageLabel.stringValue = String(localized: "Storage: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
            }
        }
    }

    nonisolated static func folderSize(_ root: URL) -> Int64 {
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

    @objc func changeFolder() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Use This Folder")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try LibraryRoot.shared.chooseFolder(url)
                self?.refresh()
            } catch {
                MidgarLog.error("Bookmark creation failed: \(error.localizedDescription)", category: .content)
                MacToast.show(String(localized: "Couldn't use \u{201C}\(url.lastPathComponent)\u{201D} as your music folder — macOS wouldn't grant Flaccy lasting access: \(error.localizedDescription)"), style: .error, in: self?.view.window)
            }
        }
    }

    @objc func resetFolder() {
        LibraryRoot.shared.resetToDefault()
        refresh()
    }

    @objc func rescanTapped() {
        guard !isWorking else { return }
        runWork(label: String(localized: "Rescanning…")) {
            await Library.shared.reload()
        }
    }

    @objc func analyzeTapped() {
        guard !isWorking, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Re-analyze Library with AI")
        alert.informativeText = String(localized: "This re-analyzes every track's metadata with AI and rewrites titles, artists, and album grouping in the database. It may take a few minutes for large libraries.")
        alert.addButton(withTitle: String(localized: "Re-analyze"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.runWork(label: String(localized: "Re-analyzing with AI…")) {
                await Library.shared.resetAndReload()
            }
        }
    }

    /// Names the action until the first progress snapshot arrives; from then on
    /// the live row narrates the phases and counts instead of one fixed word.
    func runWork(label: String, _ work: @escaping () async -> Void) {
        isWorking = true
        rescanButton.isEnabled = false
        analyzeButton.isEnabled = false
        restingActivity = label
        renderActivity()
        Task { [weak self] in
            await work()
            guard let self else { return }
            self.isWorking = false
            self.rescanButton.isEnabled = true
            self.analyzeButton.isEnabled = true
            self.restingActivity = String(localized: "Done")
            self.renderActivity()
            self.refresh()
            self.refreshMetadata()
        }
    }

    @objc func revealLibrary() {
        NSWorkspace.shared.activateFileViewerSelecting([LibraryRoot.current])
    }

    @objc func revealLogs() {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([logs])
    }
}
