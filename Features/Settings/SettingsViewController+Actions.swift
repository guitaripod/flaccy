import AuthenticationServices
import MidgarCore
import FlaccyCore
import StoreKit
import MidgarPortal
import UIKit

extension SettingsViewController {

    func handleMetadataTap() {
        selectionFeedback.selectionChanged()
        navigationController?.pushViewController(EnrichmentReportViewController(), animated: true)
    }

    /// Nudges the durable queue rather than starting a scan: everything still
    /// owed a lookup is already a row in the database, so this only asks the
    /// coordinator to get on with it.
    func handleFindMissingArtworkTap() {
        impactLight.impactOccurred()
        Task { [weak self] in
            await EnrichmentCoordinator.shared.resume()
            self?.metadataViewModel.refresh()
        }
        MidgarLog.info("Find Missing Artwork requested from Settings", category: .content)
    }

    func handleLastFMTap() {
        if LastFMService.shared.isAuthenticated {
            presentLastFMAccountSheet()
        } else {
            connectLastFM()
        }
    }

    func presentLastFMAccountSheet() {
        selectionFeedback.selectionChanged()
        let username = LastFMService.shared.username
        let sheet = UIAlertController(
            title: "Last.fm",
            message: username.map { String(localized: "Connected as \($0)") } ?? String(localized: "Connected"),
            preferredStyle: .actionSheet
        )
        if let username, let profileURL = URL(string: "https://www.last.fm/user/\(username)") {
            sheet.addAction(UIAlertAction(title: String(localized: "View Profile"), style: .default) { _ in
                UIApplication.shared.open(profileURL)
            })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Disconnect"), style: .destructive) { [weak self] _ in
            self?.confirmDisconnectLastFM()
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        present(sheet, animated: true)
    }

    func confirmDisconnectLastFM() {
        impactMedium.impactOccurred()
        let alert = UIAlertController(
            title: String(localized: "Disconnect Last.fm"),
            message: String(localized: "Your listens will no longer be scrobbled. Your library, play history, and loved tracks stay on this device."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Disconnect"), style: .destructive) { [weak self] _ in
            LastFMService.shared.logout()
            self?.notificationFeedback.notificationOccurred(.success)
            self?.applySnapshot(animated: true)
        })
        present(alert, animated: true)
    }

    func connectLastFM() {
        selectionFeedback.selectionChanged()
        let fallbackWindow = (view.window?.windowScene ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })?.keyWindow
        guard let window = view.window ?? fallbackWindow else {
            MidgarLog.error("Last.fm connect tapped with no window to anchor sign-in to", category: .auth)
            return
        }
        Task {
            do {
                try await LastFMService.shared.authenticate(from: window)
                notificationFeedback.notificationOccurred(.success)
                applySnapshot(animated: true)
            } catch {
                MidgarLog.error("Last.fm auth failed: \(error.localizedDescription)", category: .auth)
                guard !isAuthCancellation(error) else { return }
                notificationFeedback.notificationOccurred(.error)
                let message = (error as? LastFMError)?.errorDescription
                    ?? String(localized: "Last.fm sign-in didn't complete: \(error.localizedDescription)")
                let alert = UIAlertController(
                    title: String(localized: "Couldn't Connect to Last.fm"),
                    message: message,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
                present(alert, animated: true)
            }
        }
    }

    func isAuthCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == ASWebAuthenticationSessionError.errorDomain
            && nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
    }

    func handleRetryScrobbles() {
        impactLight.impactOccurred()
        Task {
            await AudioPlayer.shared.retryPendingScrobbles()
            notificationFeedback.notificationOccurred(.success)
            applySnapshot(animated: true)
        }
    }

    func handleLibraryRadio() {
        impactMedium.impactOccurred()
        AudioPlayer.shared.playLibraryRadio()
        dismiss(animated: true)
    }

    func handleCrateDig() {
        impactMedium.impactOccurred()
        AudioPlayer.shared.playCrateDig()
        dismiss(animated: true)
    }

    /// Runs the history backfill with the import row rendered as an in-progress
    /// spinner. `importHistory()` reports nothing itself, so live progress is
    /// derived by polling the local scrobble count against a pre-import baseline,
    /// mirroring `ChartsViewModel.importHistory`.
    func handleImportLastFM() {
        guard lastFMImportProgress == nil else { return }
        impactLight.impactOccurred()
        lastFMImportProgress = 0
        reconfigureRow(.importLastFM)
        let baseline = Self.scrobbleCount()

        let progressTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled, self != nil else { return }
                let delta = max(0, Self.scrobbleCount() - baseline)
                await MainActor.run { [weak self] in
                    guard let self, self.lastFMImportProgress != nil else { return }
                    self.lastFMImportProgress = delta
                    self.reconfigureRow(.importLastFM)
                }
            }
        }

        Task { [weak self] in
            await LastFMStatsService.shared.importHistory()
            progressTask.cancel()
            guard let self else { return }
            self.lastFMImportProgress = nil
            self.notificationFeedback.notificationOccurred(.success)
            self.applySnapshot(animated: true)
            self.refreshPlaysCount()
        }
    }

    func reconfigureRow(_ row: Row) {
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(row) else { return }
        snapshot.reconfigureItems([row])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    nonisolated static func scrobbleCount() -> Int {
        (try? DatabaseManager.shared.scrobbleCountInRange(from: .distantPast, to: .distantFuture)) ?? 0
    }

    func handleYearInMusicTap() {
        impactMedium.impactOccurred()
        present(YearInMusicViewController(), animated: true)
    }

    func handleRecapNotificationsTap() {
        selectionFeedback.selectionChanged()
        navigationController?.pushViewController(RecapNotificationsViewController(), animated: true)
    }

    func handleListeningGuideTap() {
        selectionFeedback.selectionChanged()
        navigationController?.pushViewController(ListeningGuideViewController(), animated: true)
    }

    func handleWatchTap() {
        selectionFeedback.selectionChanged()
        navigationController?.pushViewController(WatchSyncViewController(), animated: true)
    }

    func handleImportTap() {
        impactLight.impactOccurred()
        dismiss(animated: true) { [weak self] in
            self?.onImportFiles?()
        }
    }

    func handleRescanTap() {
        guard !isRescanning, !Library.shared.isLoading else { return }
        impactMedium.impactOccurred()
        let alert = UIAlertController(
            title: String(localized: "Rescan Library"),
            message: String(localized: "This will re-analyze all tracks with AI. May take a few minutes for large libraries."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Rescan"), style: .default) { [weak self] _ in
            self?.performRescan()
        })
        present(alert, animated: true)
    }

    /// Runs the rescan with only the rescan row disabled and spinning, so the
    /// sheet stays dismissible; the singleton `Library` carries the work if this
    /// controller is deallocated mid-scan.
    func performRescan() {
        isRescanning = true
        reconfigureRow(.rescanLibrary)

        Task { [weak self] in
            await Library.shared.resetAndReload()
            guard let self else { return }
            self.isRescanning = false
            self.reconfigureRow(.rescanLibrary)
            self.notificationFeedback.notificationOccurred(.success)
            self.applySnapshot(animated: true)
            self.refreshHeader()
            self.refreshStorageUsed()
            self.refreshPlaysCount()
            self.refreshLibraryDebut()
            self.metadataViewModel.refresh()
        }
    }

    /// Recomputes the Documents-tree size off the main thread and re-renders the
    /// storage row when it lands; every other snapshot renders the cached value.
    func refreshStorageUsed() {
        Task.detached(priority: .utility) { [weak self] in
            let used = Self.calculateStorageUsed()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.storageUsed = used
                self.applySnapshot(animated: false)
            }
        }
    }

    /// Counts total plays off the main thread for the hero dashboard, filling the
    /// stat once it lands.
    func refreshPlaysCount() {
        Task.detached(priority: .utility) { [weak self] in
            let plays = Self.scrobbleCount()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.playsCount = plays
                self.refreshHeader()
            }
        }
    }

    /// The once-per-library setup summary, read off the main thread. It is
    /// absent until a first build has actually completed one, and the section's
    /// caveat footer says what "this library" means.
    func refreshLibraryDebut() {
        Task.detached(priority: .utility) { [weak self] in
            let summary = try? DatabaseManager.shared.libraryDebut()
            await MainActor.run { [weak self] in
                guard let self, self.libraryDebut != summary else { return }
                self.libraryDebut = summary
                self.applySnapshot(animated: false)
            }
        }
    }

    func loadPriceIfNeeded() {
        Task { [weak self] in
            await PurchaseManager.shared.loadOffersIfNeeded()
            await PurchaseManager.shared.loadLapsedOfferIfNeeded()
            self?.refreshHeader()
        }
    }

    nonisolated static func calculateStorageUsed() -> String {
        let fm = FileManager.default
        let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var totalSize: Int64 = 0

        guard let enumerator = fm.enumerator(
            at: docsURL, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return String(localized: "0 MB") }

        for case let fileURL as URL in enumerator {
            if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let fileSize = resourceValues.fileSize {
                totalSize += Int64(fileSize)
            }
        }

        let gigabytes = Double(totalSize) / 1_073_741_824
        if gigabytes >= 1.0 {
            return String(format: String(localized: "%.1f GB"), gigabytes)
        }
        let megabytes = Double(totalSize) / 1_048_576
        return String(format: String(localized: "%.0f MB"), megabytes)
    }
}
