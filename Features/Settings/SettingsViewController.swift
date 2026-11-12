import AuthenticationServices
import Combine
import MidgarCore
import FlaccyCore
import StoreKit
import MidgarPortal
import UIKit

final class SettingsViewController: UITableViewController {

    var onImportFiles: (() -> Void)?

    /// Settings in its own navigation stack as a sheet, its Import Files row
    /// opening the picker from the Library.
    static func makePresented(library: LibraryViewController) -> UINavigationController {
        let settings = SettingsViewController()
        settings.onImportFiles = { [weak library] in library?.performWhenVisible { library?.importTapped() } }
        let navigation = UINavigationController(rootViewController: settings)
        navigation.modalPresentationStyle = .pageSheet
        return navigation
    }

    static let cellReuseIdentifier = "SettingsCell"

    let selectionFeedback = UISelectionFeedbackGenerator()
    let impactLight = UIImpactFeedbackGenerator(style: .light)
    let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    let notificationFeedback = UINotificationFeedbackGenerator()

    let headerView = SettingsHeaderView()
    var dataSource: DataSource!
    var storageUsed: String?
    var playsCount: Int?
    var syncStatusObserver: AnyCancellable?
    var isRescanning = false
    let metadataViewModel = EnrichmentReportViewModel()
    var libraryDebut: LibraryDebutSummary?
    var isTrialSectionVisible = false
    var isRestoring = false
    let serversModel = RemoteServersViewModel()

    /// Every sub-page on screen, so a change refreshes the page someone is looking at as well
    /// as the root's summaries.
    let livePages = NSHashTable<SettingsPageViewController>.weakObjects()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Settings")
        navigationItem.largeTitleDisplayMode = .always
        navigationController?.navigationBar.prefersLargeTitles = true
        tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.accessibilityIdentifier = "settings.table"
        tableView.delegate = self
        Self.registerCells(in: tableView)
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = makeDoneButton()
        navigationItem.searchController = makeSearchController()
        dataSource = makeDataSource(for: tableView)
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
        observeHistorySync()

        NotificationCenter.default.addObserver(
            self, selector: #selector(purchaseStateChanged),
            name: PurchaseManager.stateDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(purchaseStateChanged),
            name: PurchaseManager.entitlementsDidLoad, object: nil
        )
    }

    static func registerCells(in tableView: UITableView) {
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: cellReuseIdentifier)
        tableView.register(AppearanceCell.self, forCellReuseIdentifier: AppearanceCell.reuseID)
        tableView.register(AccentCell.self, forCellReuseIdentifier: AccentCell.reuseID)
        tableView.register(MidgarEntryCell.self, forCellReuseIdentifier: MidgarEntryCell.reuseID)
        tableView.register(SettingsPlanCell.self, forCellReuseIdentifier: SettingsPlanCell.reuseID)
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
            PaywallViewController.presentSheet(from: self.presenter)
        }
        headerView.onRestoreTapped = { [weak self] in
            self?.handleRestorePurchases()
        }
        headerView.onManageSubscriptionTapped = { [weak self] in
            self?.handleManageSubscription()
        }
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
                ToastView.show(String(localized: "Purchase restored"), in: self.presenter.view, style: .success)
            case .nothingToRestore:
                self.notificationFeedback.notificationOccurred(.warning)
                ToastView.show(String(localized: "No previous purchase was found for this Apple Account."), in: self.presenter.view, style: .info)
            case .cancelled:
                break
            case .failed:
                self.notificationFeedback.notificationOccurred(.error)
                ToastView.show(String(localized: "Couldn't reach the App Store. Check your connection and try again."), in: self.presenter.view, style: .error)
            }
            self.refreshHeader()
        }
    }

    func handleManageSubscription() {
        guard let scene = presenter.view.window?.windowScene else { return }
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
        planPage.map(sizeHeaderToFit(in:))
        applySnapshot(animated: false)
    }

    /// The plan page while it is on screen; it carries the plan hero as its table header.
    var planPage: SettingsPageViewController? {
        livePages.allObjects.first { $0.page == .plan }
    }

    /// A `tableHeaderView` is frame-driven, so its Auto Layout height is measured
    /// and stamped whenever the width or content changes, re-assigning the header
    /// to force the table to adopt the new height.
    func sizeHeaderToFit(in page: SettingsPageViewController) {
        let tableView: UITableView = page.tableView
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

    func makeDataSource(for tableView: UITableView) -> DataSource {
        let source = DataSource(tableView: tableView) { [weak self] tableView, indexPath, row in
            self?.cell(for: row, at: indexPath, in: tableView) ?? UITableViewCell()
        }
        source.footerForSection = { [weak self] section in
            section == .lastFM ? self?.lastFMFooter() : nil
        }
        source.defaultRowAnimation = .fade
        return source
    }

    var pendingScrobbleCount: Int {
        (try? DatabaseManager.shared.fetchPendingScrobbles().count) ?? 0
    }

    /// The controller to present alerts, sheets and toasts from: the page on screen, which is
    /// the root itself until someone opens a page.
    var presenter: UIViewController {
        navigationController?.topViewController ?? self
    }

    /// Rebuilds the root and every page on screen from the current state.
    func applySnapshot(animated: Bool) {
        guard dataSource != nil else { return }
        dataSource.apply(snapshot(for: .root), animatingDifferences: animated && view.window != nil)
        for page in livePages.allObjects {
            page.apply(animated: animated)
        }
    }

    func snapshot(for page: Page) -> NSDiffableDataSourceSnapshot<Section, Row> {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        for (section, rows) in sections(for: page) where !rows.isEmpty {
            snapshot.appendSections([section])
            snapshot.appendItems(rows, toSection: section)
        }
        if snapshot.sectionIdentifiers.contains(.lastFM) {
            snapshot.reloadSections([.lastFM])
        }
        return snapshot
    }

    func sections(for page: Page) -> [(Section, [Row])] {
        switch page {
        case .root: rootSections()
        case .plan: []
        case .appearance: [(.appearance, [.appearance(AppAppearance.current), .accent(AppAccent.current)])]
        case .notifications: notificationSections()
        case .playback: [
            (.playback, [.gaplessPlayback, .autoplaySimilar]),
            (.stations, [.libraryRadio, .crateDig]),
        ]
        case .library: librarySections()
        case .servers: [
            (.servers, serverRows()),
            (.serverCache, serversModel.rows.isEmpty ? [] : [.cacheLimit, .cacheUsage(serversModel.cacheCaption), .clearCache]),
        ]
        case .lastFM: [(.lastFM, lastFMRows())]
        case .about: [
            (.aboutVersion, [.version(Self.versionLine)]),
            (.aboutLegal, [.privacyPolicy, .termsOfUse]),
        ]
        }
    }

    /// The root, laid out like the system Settings app: the plan first, then one row per page
    /// with what it is set to, so the common answers show without opening anything.
    func rootSections() -> [(Section, [Row])] {
        var library: [Row] = [
            .page(.library, value: String(localized: "\(Library.shared.albums.count) albums")),
            .page(.servers, value: serversModel.rows.isEmpty ? nil : "\(serversModel.rows.count)"),
        ]
        if WatchSyncService.shared.canPairWatch {
            library.append(.watchSync(syncedCount: WatchSyncService.shared.syncedCount, profile: WatchSyncService.shared.profile))
        }
        return [
            (.rootPlan, [.plan(planSummary)]),
            (.rootGeneral, [
                .page(.appearance, value: AppAppearance.current.displayName),
                .page(.notifications, value: nil),
            ]),
            (.rootListening, [
                .equalizer(summary: EqualizerCopy.settingsSummary),
                .page(.playback, value: nil),
                .yearInMusic,
            ]),
            (.rootLibrary, library),
            (.rootServices, [.page(.lastFM, value: LastFMService.shared.isAuthenticated ? LastFMService.shared.username : nil)]),
            (.rootSupport, [.support, .page(.about, value: nil)]),
            (.midgar, [.midgarEntry]),
        ]
    }

    func notificationSections() -> [(Section, [Row])] {
        [
            (.trial, isTrialSectionVisible ? [.trialReminders(enabled: TrialReminderScheduler.shared.isEnabled)] : []),
            (.recap, [.recapNotifications(frequency: RecapNotificationScheduler.shared.frequency.displayName)]),
        ]
    }

    func lastFMRows() -> [Row] {
        let authenticated = LastFMService.shared.isAuthenticated
        var rows: [Row] = [.lastFMAccount(username: authenticated ? LastFMService.shared.username : nil)]
        if authenticated {
            let pending = pendingScrobbleCount
            if pending > 0 {
                rows.append(.pendingScrobbles(count: pending))
            }
            rows.append(.historySync)
        }
        return rows
    }

    /// `Find Missing Artwork` appears only while there is something to find. A
    /// button that does nothing visible when tapped is worse than no button, and
    /// a settled library is supposed to be quiet everywhere.
    func librarySections() -> [(Section, [Row])] {
        let counts = metadataViewModel.counts
        var details: [Row] = [.metadataReport(complete: counts.complete, gaveUp: counts.gaveUp)]
        if counts.inProgress > 0 {
            details.append(.findMissingArtwork(count: counts.inProgress))
        }
        details.append(.appleMusicArtwork(AppleMusicArtworkSetting.isEnabled))
        var overview: [Row] = [
            .libraryStats(albums: Library.shared.albums.count, tracks: Library.shared.allTracks.count),
            .storage(used: storageUsed ?? "…"),
        ]
        if libraryDebut != nil {
            overview.append(.libraryDebutSummary)
        }
        return [
            (.libraryAdd, [.importFiles, .rescanLibrary]),
            (.libraryOrganize, [.groupAlbumEditions, .hideDuplicateSongs]),
            (.libraryDetails, details),
            (.libraryOverview, overview),
        ]
    }

    /// What the plan row says: the plan someone holds, or the trial with its price.
    var planSummary: PlanSummary {
        let state = PurchaseManager.shared.state
        switch state {
        case .purchased(.lifetime):
            return PlanSummary(title: String(localized: "Lifetime member"), subtitle: String(localized: "Thanks for supporting flaccy"))
        case .purchased(.yearly):
            return PlanSummary(title: String(localized: "Flaccy Pro"), subtitle: String(localized: "Yearly · thanks for supporting flaccy"))
        case .trialNotStarted, .trial, .expired:
            let sentence = PaywallCopy.settingsSentence(state: state, lifetime: PurchaseManager.shared.lifetimeOfferToPresent)
            return PlanSummary(title: String(localized: "Flaccy Lifetime"), subtitle: sentence ?? "")
        }
    }

    static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    func makeSearchController() -> UISearchController {
        let results = SettingsSearchResultsController(root: self)
        let search = UISearchController(searchResultsController: results)
        search.searchResultsUpdater = results
        search.searchBar.accessibilityIdentifier = "settings.search"
        return search
    }

    /// Every setting the search field finds, named the way its row names it.
    func searchEntries() -> [SettingsSearchResultsController.Entry] {
        typealias Entry = SettingsSearchResultsController.Entry
        var entries: [Entry] = [
            Entry(planSummary.title, in: .plan),
            Entry(String(localized: "Restore Purchases"), in: .plan),
            Entry(Page.appearance.title, in: .appearance),
            Entry(String(localized: "Accent"), in: .appearance),
            Entry(Page.notifications.title, in: .notifications),
            Entry(String(localized: "Trial reminders"), in: .notifications),
            Entry(String(localized: "Recap Notifications"), in: .notifications),
            Entry(EqualizerCopy.title, symbolName: "slider.vertical.3", tint: .systemPink, row: .equalizer(summary: EqualizerCopy.settingsSummary)),
            Entry(Page.playback.title, in: .playback),
            Entry(String(localized: "Gapless Playback"), in: .playback),
            Entry(String(localized: "Autoplay Similar"), in: .playback),
            Entry(String(localized: "Library Radio"), in: .playback),
            Entry(String(localized: "Crate Dig"), in: .playback),
            Entry(String(localized: "Year in Music"), symbolName: "sparkles", tint: .systemIndigo, row: .yearInMusic),
            Entry(Page.library.title, in: .library),
            Entry(String(localized: "Import Files"), in: .library),
            Entry(String(localized: "Rescan Library"), in: .library),
            Entry(String(localized: "Group Album Editions"), in: .library),
            Entry(String(localized: "Hide Duplicate Songs"), in: .library),
            Entry(String(localized: "Metadata"), in: .library),
            Entry(String(localized: "Use Apple Music artwork"), in: .library),
            Entry(String(localized: "Storage Used"), in: .library),
            Entry(Page.servers.title, in: .servers),
            Entry(String(localized: "Add Flaccy Server"), in: .servers),
            Entry(String(localized: "Add Other Server"), in: .servers),
            Entry(String(localized: "Server Cache"), in: .servers),
            Entry(Page.lastFM.title, in: .lastFM),
            Entry(String(localized: "History Sync"), in: .lastFM),
            Entry(String(localized: "Contact Support"), symbolName: "envelope.fill", tint: .systemGreen, row: .support),
            Entry(Page.about.title, in: .about),
            Entry(String(localized: "Version"), in: .about),
            Entry(String(localized: "Privacy Policy"), in: .about),
            Entry(String(localized: "Terms of Use"), in: .about),
        ]
        if WatchSyncService.shared.canPairWatch {
            let watch = Row.watchSync(syncedCount: WatchSyncService.shared.syncedCount, profile: WatchSyncService.shared.profile)
            entries.append(Entry(String(localized: "Apple Watch"), symbolName: "applewatch", tint: .systemGray, row: watch))
        }
        return entries
    }

    /// Closes the search, then opens what was picked once the results have gone: a push made
    /// while the search was still dismissing was dropped.
    func openSearchResult(_ entry: SettingsSearchResultsController.Entry) {
        let perform: () -> Void = { [weak self] in
            switch entry.target {
            case .page(let page): self?.open(page)
            case .row(let row): self?.select(row)
            }
        }
        guard let search = navigationItem.searchController, search.isActive else {
            perform()
            return
        }
        search.isActive = false
        if let coordinator = search.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { _ in perform() }
        } else {
            DispatchQueue.main.async(execute: perform)
        }
    }

    /// Pushes a page of Settings, built from this controller's state.
    func open(_ page: Page) {
        guard page != .root else { return }
        selectionFeedback.selectionChanged()
        let controller = SettingsPageViewController(page: page, root: self)
        livePages.add(controller)
        navigationController?.pushViewController(controller, animated: true)
    }

    func pageDidLoad(_ page: SettingsPageViewController) {
        guard page.page == .plan else { return }
        page.title = planSummary.title
        page.tableView.tableHeaderView = headerView
        refreshHeader()
    }

    func pageDidLayout(_ page: SettingsPageViewController) {
        guard page.page == .plan else { return }
        sizeHeaderToFit(in: page)
    }

    /// Where a row sits on screen now, for anchoring a popover to it on iPad.
    func visibleCell(for row: Row) -> UITableViewCell? {
        let pages: [(UITableView, DataSource?)] = livePages.allObjects.map { ($0.tableView, $0.dataSource) } + [(tableView, dataSource)]
        for (table, source) in pages {
            if let indexPath = source?.indexPath(for: row), let cell = table.cellForRow(at: indexPath), cell.window != nil {
                return cell
            }
        }
        return nil
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if dataSource.itemIdentifier(for: indexPath) == .midgarEntry {
            return MidgarEntryView.preferredHeight + 16
        }
        return UITableView.automaticDimension
    }

    override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return false }
        return isSelectable(row)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        select(row)
    }

    override func tableView(
        _ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return swipeActions(for: row)
    }

    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        guard let section = dataSource.sectionIdentifier(for: section) else { return nil }
        return footerView(for: section)
    }

    func isSelectable(_ row: Row) -> Bool {
        switch row {
        case .appearance, .accent, .trialReminders, .gaplessPlayback, .autoplaySimilar, .groupAlbumEditions, .hideDuplicateSongs,
             .libraryStats, .storage, .appleMusicArtwork, .libraryDebutSummary, .midgarEntry,
             .cacheLimit, .cacheUsage, .version:
            return false
        case .server(let server): return server.flaccy != nil
        case .historySync: return !ListenHistorySync.shared.status.isBusy
        case .rescanLibrary: return !isRescanning
        default: return true
        }
    }

    func select(_ row: Row) {
        switch row {
        case .plan: open(.plan)
        case .page(let page, _): open(page)
        case .lastFMAccount: handleLastFMTap()
        case .pendingScrobbles: handleRetryScrobbles()
        case .historySync: handleHistorySync()
        case .yearInMusic: handleYearInMusicTap()
        case .recapNotifications: handleRecapNotificationsTap()
        case .libraryRadio: handleLibraryRadio()
        case .crateDig: handleCrateDig()
        case .equalizer:
            impactLight.impactOccurred()
            presenter.present(EqualizerViewController.makePresented(), animated: true)
        case .watchSync: handleWatchTap()
        case .privacyPolicy: UIApplication.shared.open(LegalLinks.privacyURL)
        case .termsOfUse: UIApplication.shared.open(LegalLinks.termsURL)
        case .support: handleSupportTap()
        case .importFiles: handleImportTap()
        case .rescanLibrary: handleRescanTap()
        case .metadataReport: handleMetadataTap()
        case .findMissingArtwork: handleFindMissingArtworkTap()
        case .addFlaccyServer: handleAddFlaccyServerTap()
        case .addServer: handleAddServerTap()
        case .server(let server): handleServerTap(server)
        case .clearCache: handleClearCacheTap()
        case .appearance, .accent, .trialReminders, .gaplessPlayback, .autoplaySimilar, .groupAlbumEditions, .hideDuplicateSongs,
             .libraryStats, .storage, .appleMusicArtwork, .libraryDebutSummary, .midgarEntry,
             .cacheLimit, .cacheUsage, .version:
            break
        }
    }
}
