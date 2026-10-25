import AuthenticationServices
import MidgarCore
import FlaccyCore
import StoreKit
import MidgarPortal
import UIKit

final class SettingsViewController: UITableViewController {

    var onImportFiles: (() -> Void)?

    static let cellReuseIdentifier = "SettingsCell"

    let selectionFeedback = UISelectionFeedbackGenerator()
    let impactLight = UIImpactFeedbackGenerator(style: .light)
    let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    let notificationFeedback = UINotificationFeedbackGenerator()

    let headerView = SettingsHeaderView()
    var dataSource: DataSource!
    var storageUsed: String?
    var playsCount: Int?
    var lastFMImportProgress: Int?
    var isRescanning = false
    let metadataViewModel = EnrichmentReportViewModel()
    var libraryDebut: LibraryDebutSummary?
    var isTrialSectionVisible = false
    var isRestoring = false
    let serversModel = RemoteServersViewModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Settings")
        tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.accessibilityIdentifier = "settings.table"
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellReuseIdentifier)
        tableView.register(AppearanceCell.self, forCellReuseIdentifier: AppearanceCell.reuseID)
        tableView.register(MidgarEntryCell.self, forCellReuseIdentifier: MidgarEntryCell.reuseID)
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = makeDoneButton()
        configureDataSource()
        configureHeader()
        tableView.tableFooterView = makeVersionFooter()
        applySnapshot(animated: false)
        refreshHeader()
        refreshStorageUsed()
        refreshPlaysCount()
        refreshLibraryDebut()
        refreshTrialSectionVisibility()
        loadPriceIfNeeded()
        observeMetadata()
        observeServers()

        NotificationCenter.default.addObserver(
            self, selector: #selector(purchaseStateChanged),
            name: PurchaseManager.stateDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(purchaseStateChanged),
            name: PurchaseManager.entitlementsDidLoad, object: nil
        )
    }

    /// The Metadata row and the report it pushes read the same view model, so a
    /// count can never be stale in one place and live in the other.
    func observeMetadata() {
        metadataViewModel.onChange = { [weak self] in
            self?.applySnapshot(animated: true)
        }
        metadataViewModel.start()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applySnapshot(animated: false)
        refreshHeader()
        metadataViewModel.refresh()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sizeHeaderToFit()
    }

    @objc func purchaseStateChanged() {
        refreshHeader()
        applySnapshot(animated: true)
        refreshTrialSectionVisibility()
    }

    /// The reminders row stays while the trial runs or has lapsed, and for as
    /// long as any reminder is still pending — so a switch is never taken away
    /// from someone who still has a notification queued.
    func refreshTrialSectionVisibility() {
        Task { [weak self] in
            var visible = !PurchaseManager.shared.state.isPurchased
            if !visible {
                visible = await TrialReminderScheduler.shared.hasPendingRequests()
            }
            guard let self, self.isTrialSectionVisible != visible else { return }
            self.isTrialSectionVisible = visible
            self.applySnapshot(animated: true)
        }
    }

    func makeDoneButton() -> UIBarButtonItem {
        UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in
                self?.impactLight.impactOccurred()
                self?.dismiss(animated: true)
            }
        )
    }

    func configureHeader() {
        headerView.onUnlockTapped = { [weak self] in
            guard let self else { return }
            self.impactMedium.impactOccurred()
            PaywallViewController.presentSheet(from: self)
        }
        headerView.onRestoreTapped = { [weak self] in
            self?.handleRestorePurchases()
        }
        headerView.onManageSubscriptionTapped = { [weak self] in
            self?.handleManageSubscription()
        }
        tableView.tableHeaderView = headerView
    }

    func handleRestorePurchases() {
        guard !isRestoring else { return }
        impactLight.impactOccurred()
        isRestoring = true
        Task { [weak self] in
            let outcome = await PurchaseManager.shared.restore()
            guard let self else { return }
            self.isRestoring = false
            switch outcome {
            case .restored:
                self.notificationFeedback.notificationOccurred(.success)
                ToastView.show(String(localized: "Purchase restored"), in: self.view, style: .success)
            case .nothingToRestore:
                self.notificationFeedback.notificationOccurred(.warning)
                ToastView.show(String(localized: "No previous purchase was found for this Apple Account."), in: self.view, style: .info)
            case .cancelled:
                break
            case .failed:
                self.notificationFeedback.notificationOccurred(.error)
                ToastView.show(String(localized: "Couldn't reach the App Store. Check your connection and try again."), in: self.view, style: .error)
            }
            self.refreshHeader()
        }
    }

    func handleManageSubscription() {
        guard let scene = view.window?.windowScene else { return }
        selectionFeedback.selectionChanged()
        Task {
            do {
                try await AppStore.showManageSubscriptions(in: scene)
            } catch {
                MidgarLog.error("Manage subscriptions sheet failed: \(error.localizedDescription)", category: .purchases)
            }
        }
    }

    func refreshHeader() {
        headerView.configure(
            state: PurchaseManager.shared.state,
            lifetimeOffer: PurchaseManager.shared.lifetimeOfferToPresent,
            albums: Library.shared.albums.count,
            tracks: Library.shared.allTracks.count,
            plays: playsCount
        )
        sizeHeaderToFit()
    }

    /// A `tableHeaderView` is frame-driven, so its Auto Layout height is measured
    /// and stamped whenever the width or content changes, re-assigning the header
    /// to force the table to adopt the new height.
    func sizeHeaderToFit() {
        let width = tableView.bounds.width
        guard width > 0 else { return }
        let height = headerView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        if abs(headerView.frame.height - height) > 0.5 || abs(headerView.frame.width - width) > 0.5 {
            headerView.frame = CGRect(x: 0, y: 0, width: width, height: height)
            tableView.tableHeaderView = headerView
        }
    }

    func configureDataSource() {
        dataSource = DataSource(tableView: tableView) {
            [weak self] tableView, indexPath, row in
            self?.cell(for: row, at: indexPath, in: tableView) ?? UITableViewCell()
        }
        dataSource.footerForSection = { [weak self] section in
            section == .lastFM ? self?.lastFMFooter() : nil
        }
        dataSource.defaultRowAnimation = .fade
    }

    var pendingScrobbleCount: Int {
        (try? DatabaseManager.shared.fetchPendingScrobbles().count) ?? 0
    }

    func applySnapshot(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections(Section.allCases.filter { $0 != .trial || isTrialSectionVisible })
        snapshot.appendItems([.midgarEntry], toSection: .midgar)
        snapshot.appendItems([.appearance(AppAppearance.current)], toSection: .appearance)
        if isTrialSectionVisible {
            snapshot.appendItems([.trialReminders(enabled: TrialReminderScheduler.shared.isEnabled)], toSection: .trial)
        }

        let authenticated = LastFMService.shared.isAuthenticated
        var lastFMRows: [Row] = [.lastFMAccount(username: authenticated ? LastFMService.shared.username : nil)]
        if authenticated {
            let pending = pendingScrobbleCount
            if pending > 0 {
                lastFMRows.append(.pendingScrobbles(count: pending))
            }
            lastFMRows.append(.importLastFM)
        }
        snapshot.appendItems(lastFMRows, toSection: .lastFM)
        snapshot.appendItems(
            [
                .yearInMusic,
                .recapNotifications(frequency: RecapNotificationScheduler.shared.frequency.displayName),
            ],
            toSection: .recap
        )
        snapshot.appendItems([.equalizer(summary: EqualizerCopy.settingsSummary), .gaplessPlayback, .autoplaySimilar, .libraryRadio, .crateDig], toSection: .playback)
        snapshot.appendItems([.listeningGuide], toSection: .guide)
        snapshot.appendItems([.watchSync(syncedCount: WatchSyncService.shared.syncedCount, profile: WatchSyncService.shared.profile)], toSection: .watch)
        snapshot.appendItems(serverRows(), toSection: .servers)
        snapshot.appendItems(
            [.cacheLimit, .cacheUsage(serversModel.cacheCaption), .clearCache],
            toSection: .serverCache
        )
        snapshot.appendItems(libraryRows(), toSection: .library)
        if libraryDebut != nil {
            snapshot.appendItems([.libraryDebutSummary], toSection: .setup)
        }
        snapshot.appendItems([.privacyPolicy, .termsOfUse], toSection: .about)
        snapshot.reloadSections([.lastFM])
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    /// `Find Missing Artwork` appears only while there is something to find. A
    /// button that does nothing visible when tapped is worse than no button, and
    /// a settled library is supposed to be quiet everywhere.
    func libraryRows() -> [Row] {
        let counts = metadataViewModel.counts
        var rows: [Row] = [
            .importFiles,
            .rescanLibrary,
            .groupAlbumEditions,
            .hideDuplicateSongs,
            .metadataReport(complete: counts.complete, gaveUp: counts.gaveUp),
        ]
        if counts.inProgress > 0 {
            rows.append(.findMissingArtwork(count: counts.inProgress))
        }
        rows.append(.appleMusicArtwork(AppleMusicArtworkSetting.isEnabled))
        rows.append(.libraryStats(albums: Library.shared.albums.count, tracks: Library.shared.allTracks.count))
        rows.append(.storage(used: storageUsed ?? "…"))
        return rows
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if dataSource.itemIdentifier(for: indexPath) == .midgarEntry {
            return MidgarEntryView.preferredHeight + 16
        }
        return UITableView.automaticDimension
    }

    override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return false }
        switch row {
        case .appearance, .trialReminders, .gaplessPlayback, .autoplaySimilar, .groupAlbumEditions, .hideDuplicateSongs,
             .libraryStats, .storage, .appleMusicArtwork, .libraryDebutSummary, .midgarEntry,
             .serversExplainer, .server, .cacheLimit, .cacheUsage:
            return false
        case .importLastFM: return lastFMImportProgress == nil
        case .rescanLibrary: return !isRescanning
        default: return true
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        switch row {
        case .lastFMAccount: handleLastFMTap()
        case .pendingScrobbles: handleRetryScrobbles()
        case .importLastFM: handleImportLastFM()
        case .yearInMusic: handleYearInMusicTap()
        case .recapNotifications: handleRecapNotificationsTap()
        case .libraryRadio: handleLibraryRadio()
        case .crateDig: handleCrateDig()
        case .listeningGuide: handleListeningGuideTap()
        case .equalizer: present(EqualizerViewController.makePresented(), animated: true)
        case .watchSync: handleWatchTap()
        case .privacyPolicy: UIApplication.shared.open(LegalLinks.privacyURL)
        case .termsOfUse: UIApplication.shared.open(LegalLinks.termsURL)
        case .importFiles: handleImportTap()
        case .rescanLibrary: handleRescanTap()
        case .metadataReport: handleMetadataTap()
        case .findMissingArtwork: handleFindMissingArtworkTap()
        case .addServer: handleAddServerTap()
        case .clearCache: handleClearCacheTap()
        case .appearance, .trialReminders, .gaplessPlayback, .autoplaySimilar, .groupAlbumEditions, .hideDuplicateSongs,
             .libraryStats, .storage, .appleMusicArtwork, .libraryDebutSummary, .midgarEntry,
             .serversExplainer, .server, .cacheLimit, .cacheUsage:
            break
        }
    }

}
