import FlaccyCore
import UIKit

final class WatchSyncViewController: UITableViewController {

    nonisolated private enum Section: Int, CaseIterable { case status, quality, albums }

    nonisolated private enum Item: Hashable {
        case status
        case run
        case quality(WatchAudioProfile)
        case album(String)
    }

    private struct QualityEstimate {
        let albumCount: Int
        let bytes: [WatchAudioProfile: Int64]
    }

    private final class DataSource: UITableViewDiffableDataSource<Section, Item> {
        var headerTitle: ((Section) -> String?)?
        var footerTitle: ((Section) -> String?)?

        override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
            Section(rawValue: section).flatMap { headerTitle?($0) }
        }

        override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
            Section(rawValue: section).flatMap { footerTitle?($0) }
        }
    }

    private var allAlbums: [Album] = []
    private var albums: [Album] = []
    private var albumsByID: [String: Album] = [:]
    private var searchQuery = ""
    private var qualityEstimate: QualityEstimate?
    private var estimateTask: Task<Void, Never>?
    private let service = WatchSyncService.shared
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let selection = UISelectionFeedbackGenerator()
    private let notify = UINotificationFeedbackGenerator()
    private let searchController = UISearchController(searchResultsController: nil)
    private var dataSource: DataSource!
    private var wasSyncing = false
    private var pendingProgressUpdate: DispatchWorkItem?
    private var isChecking = false
    private var checkTask: Task<Void, Never>?
    private var lastReadiness: WatchSyncService.Readiness?
    private var renderedFooterKey: [Bool]?
    private var songsInRun = 0

    init() { super.init(style: .insetGrouped) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        estimateTask?.cancel()
        checkTask?.cancel()
    }

    private var link: WatchSyncLink { WatchSyncLink.current(for: service) }

    private var readiness: WatchSyncService.Readiness { service.readiness }

    private var canSync: Bool { readiness.canQueue }

    private var toastHost: UIView { navigationController?.view ?? view }

    private var isSearching: Bool { !searchQuery.isEmpty }

    override func viewDidLoad() {
        super.viewDidLoad()
        installDemoStateIfRequested()
        title = String(localized: "Apple Watch")
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemGroupedBackground
        tableView.register(WatchSyncStatusCell.self, forCellReuseIdentifier: WatchSyncStatusCell.reuseID)
        tableView.register(WatchSyncRunCell.self, forCellReuseIdentifier: WatchSyncRunCell.reuseID)
        tableView.register(WatchSyncQualityCell.self, forCellReuseIdentifier: WatchSyncQualityCell.reuseID)
        tableView.register(WatchSyncAlbumCell.self, forCellReuseIdentifier: WatchSyncAlbumCell.reuseID)
        tableView.estimatedRowHeight = 72
        tableView.cellLayoutMarginsFollowReadableWidth = true

        configureSearch()
        configureMenu()
        loadAlbums()
        configureDataSource()
        applySnapshot(animated: false)
        refreshQualityEstimate()
        scrollForDemoIfRequested()
        lastReadiness = readiness

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(stateChanged), name: WatchSyncService.stateDidChange, object: nil)
        center.addObserver(self, selector: #selector(libraryChanged), name: Library.didUpdateNotification, object: nil)
        center.addObserver(self, selector: #selector(progressChanged), name: WatchSyncService.progressDidChange, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !WatchSyncLink.isSimulated else { return }
        service.requestWatchState()
        service.reconcile()
    }

    private func restoreDemoStateIfRequested() {
        #if DEBUG && os(iOS) && targetEnvironment(simulator)
        service.restoreDemoStateIfDisturbed()
        #endif
    }

    private func installDemoStateIfRequested() {
        #if DEBUG && os(iOS) && targetEnvironment(simulator)
        service.installDemoState()
        #endif
    }

    /// Lets a screenshot run start further down the screen, since the album list
    /// sits below the status card and the quality section.
    private func scrollForDemoIfRequested() {
        #if DEBUG && os(iOS) && targetEnvironment(simulator)
        guard WatchSyncLink.isSimulated, let target = ProcessInfo.processInfo.environment["FLACCY_WATCH_SCROLL"],
              !target.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tableView.layoutIfNeeded()
            let section = target == "albums" ? Section.albums : Section.quality
            guard let sectionIndex = self.dataSource.snapshot().indexOfSection(section) else { return }
            let indexPath = IndexPath(row: 0, section: sectionIndex)
            self.tableView.scrollToRow(at: indexPath, at: .top, animated: false)
        }
        #endif
    }

    private func configureSearch() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = String(localized: "Search Albums")
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = true
        definesPresentationContext = true
    }

    private func configureMenu() {
        let menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.menuElements() ?? [])
            },
        ])
        let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: menu)
        item.accessibilityLabel = String(localized: "More")
        navigationItem.rightBarButtonItem = item
    }

    /// Built each time the menu opens, so Remove All is only live while there
    /// is something on the watch to remove and Retry only while something failed.
    private func menuElements() -> [UIMenuElement] {
        var elements: [UIMenuElement] = []
        let readiness = self.readiness
        if let topic = helpTopic(for: readiness) {
            elements.append(UIAction(title: String(localized: "Show Me How"), image: UIImage(systemName: "list.number")) { [weak self] _ in
                self?.presentHelp(topic)
            })
        }
        if readiness != .ready && readiness != .notSupported {
            elements.append(UIAction(title: String(localized: "Check Again"), image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                self?.checkAgain()
            })
        }
        if service.stuckCount > 0 {
            elements.append(UIAction(title: String(localized: "Retry"), image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                self?.retryStuck()
            })
        }
        let hasMusic = service.syncedCount > 0 || service.requestedCount > 0
        let removeAll = UIAction(
            title: String(localized: "Remove All from Watch"),
            image: UIImage(systemName: "trash"),
            attributes: hasMusic && readiness.canQueue ? .destructive : [.destructive, .disabled]
        ) { [weak self] _ in
            self?.confirmRemoveAll()
        }
        if !readiness.canQueue {
            removeAll.subtitle = readiness.unavailableReason
        } else if !hasMusic {
            removeAll.subtitle = String(localized: "Nothing on your Watch")
        }
        elements.append(removeAll)
        return elements
    }

    private func helpTopic(for readiness: WatchSyncService.Readiness) -> WatchSyncHelpViewController.Topic? {
        switch readiness {
        case .notInstalled: .install
        case .notPaired: .pair
        case .notSupported, .waitingForWatch, .ready: nil
        }
    }

    private func loadAlbums() {
        var seen = Set<String>()
        allAlbums = Library.shared.albums.filter { seen.insert($0.id).inserted }
        albumsByID = Dictionary(uniqueKeysWithValues: allAlbums.map { ($0.id, $0) })
        applyFilter()
    }

    private func applyFilter() {
        guard isSearching else {
            albums = allAlbums
            return
        }
        albums = allAlbums.filter {
            $0.title.localizedStandardContains(searchQuery) || $0.artist.localizedStandardContains(searchQuery)
        }
    }

    private func refreshQualityEstimate() {
        estimateTask?.cancel()
        let tracks = allAlbums.flatMap(\.tracks)
        let count = allAlbums.count
        estimateTask = Task { [weak self] in
            let totals = await Task.detached(priority: .utility) { WatchSyncSizing.libraryBytes(tracks: tracks) }.value
            guard !Task.isCancelled, let self else { return }
            self.qualityEstimate = QualityEstimate(albumCount: count, bytes: totals)
            self.reconfigureQualityRows()
        }
    }

    private func qualityHint(for profile: WatchAudioProfile) -> String? {
        guard let estimate = qualityEstimate else {
            return allAlbums.isEmpty ? nil : String(localized: "Calculating…")
        }
        guard estimate.albumCount > 0, let bytes = estimate.bytes[profile] else { return nil }
        return profile.libraryHint(albumCount: estimate.albumCount, bytes: bytes)
    }

    private func configureDataSource() {
        dataSource = DataSource(tableView: tableView) { [weak self] tableView, indexPath, item in
            guard let self else { return UITableViewCell() }
            switch item {
            case .status: return self.statusCell(in: tableView, at: indexPath)
            case .run:
                let cell = tableView.dequeueReusableCell(withIdentifier: WatchSyncRunCell.reuseID, for: indexPath) as! WatchSyncRunCell
                cell.configure(service: self.service)
                return cell
            case let .quality(profile):
                let cell = tableView.dequeueReusableCell(withIdentifier: WatchSyncQualityCell.reuseID, for: indexPath) as! WatchSyncQualityCell
                cell.configure(profile: profile, isSelected: profile == self.service.profile, hint: self.qualityHint(for: profile))
                return cell
            case let .album(id):
                let cell = tableView.dequeueReusableCell(withIdentifier: WatchSyncAlbumCell.reuseID, for: indexPath) as! WatchSyncAlbumCell
                if let album = self.albumsByID[id] {
                    cell.configure(album: album, presentation: WatchAlbumPresentation.make(album: album, service: self.service))
                }
                return cell
            }
        }
        dataSource.defaultRowAnimation = .fade
        dataSource.headerTitle = { [weak self] section in
            guard let self else { return nil }
            switch section {
            case .status: return nil
            case .quality: return String(localized: "Quality")
            case .albums: return self.albums.isEmpty ? nil : String(localized: "Albums")
            }
        }
        dataSource.footerTitle = { [weak self] section in
            guard let self else { return nil }
            switch section {
            case .status: return WatchConnectionState(service: self.service, link: self.link).footer
            case .quality: return self.canSync ? String(localized: "Your Apple Watch plays over Bluetooth, which already compresses audio, so lossless files take several times the space for no audible gain. A new quality applies only to music sent from now on — songs already on your watch stay as they are.") : String(localized: "Your choice is saved and applies when music is sent. Your Apple Watch plays over Bluetooth, which already compresses audio, so lossless files take several times the space for no audible gain.")
            case .albums: return nil
            }
        }
    }

    private func statusCell(in tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: WatchSyncStatusCell.reuseID, for: indexPath) as! WatchSyncStatusCell
        let state = WatchConnectionState(service: service, link: link)
        let storage = readiness.isReady ? WatchStorageBreakdown.current(service: service) : nil
        cell.configure(.init(
            state: state,
            subtitle: state.subtitle(service: service, showsFreeSpace: storage == nil),
            storage: storage,
            stuckCount: readiness.isReady ? service.stuckCount : 0,
            isChecking: isChecking
        ))
        cell.onRetry = { [weak self] in self?.retryStuck() }
        cell.onShowHow = { [weak self] in
            guard let self, let topic = self.helpTopic(for: self.readiness) else { return }
            self.presentHelp(topic)
        }
        cell.onCheckAgain = { [weak self] in self?.checkAgain() }
        return cell
    }

    private func makeSnapshot() -> NSDiffableDataSourceSnapshot<Section, Item> {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if !isSearching {
            snapshot.appendSections([.status, .quality])
            let showsRun = readiness.isReady && (service.isSyncing || service.preparingCount > 0)
            snapshot.appendItems(showsRun ? [.status, .run] : [.status], toSection: .status)
            snapshot.appendItems(WatchAudioProfile.allCases.map { .quality($0) }, toSection: .quality)
        }
        snapshot.appendSections([.albums])
        snapshot.appendItems(albums.map { .album($0.id) }, toSection: .albums)
        return snapshot
    }

    /// Footers are asked for only when their section loads, so a change in what
    /// they say reloads the two sections that carry one.
    private func reloadFootersIfNeeded(in snapshot: inout NSDiffableDataSourceSnapshot<Section, Item>) {
        let key = [readiness.canQueue, readiness.needsSetup]
        guard key != renderedFooterKey else { return }
        renderedFooterKey = key
        snapshot.reloadSections([Section.status, .quality].filter { snapshot.sectionIdentifiers.contains($0) })
    }

    private func applySnapshot(animated: Bool) {
        var snapshot = makeSnapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        reloadFootersIfNeeded(in: &snapshot)
        let shouldAnimate = animated && view.window != nil && !UIAccessibility.isReduceMotionEnabled
        dataSource.apply(snapshot, animatingDifferences: shouldAnimate)
        updateEmptyState()
    }

    private func reconfigureQualityRows() {
        guard isViewLoaded, dataSource != nil else { return }
        var snapshot = dataSource.snapshot()
        let rows = snapshot.itemIdentifiers.filter { if case .quality = $0 { true } else { false } }
        guard !rows.isEmpty else { return }
        snapshot.reconfigureItems(rows)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func updateEmptyState() {
        guard isSearching, albums.isEmpty else {
            contentUnavailableConfiguration = nil
            return
        }
        contentUnavailableConfiguration = UIContentUnavailableConfiguration.search()
    }

    @objc private func libraryChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isViewLoaded else { return }
            WatchSyncSizing.invalidate()
            self.loadAlbums()
            self.refreshQualityEstimate()
            self.applySnapshot(animated: false)
        }
    }

    @objc private func stateChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isViewLoaded, self.view.window != nil else { return }
            self.pendingProgressUpdate?.cancel()
            self.pendingProgressUpdate = nil
            let isSyncing = self.service.isSyncing
            if self.wasSyncing, !isSyncing, self.service.unconfirmedCount == 0, self.service.diskFullCount == 0 {
                self.notify.notificationOccurred(.success)
                self.reportRunFinished()
            }
            self.wasSyncing = isSyncing
            self.restoreDemoStateIfRequested()
            self.applySnapshot(animated: true)
            self.noteReadinessChange()
        }
    }

    /// Progress ticks arrive dozens of times per second across concurrent
    /// transfers; coalesce them and refresh only the visible cells in place so
    /// scrolling stays smooth and artwork loads never re-fire.
    @objc private func progressChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isViewLoaded, self.view.window != nil else { return }
            guard self.pendingProgressUpdate == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingProgressUpdate = nil
                self.applyProgressToVisibleCells()
            }
            self.pendingProgressUpdate = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    private func applyProgressToVisibleCells() {
        guard isViewLoaded, view.window != nil else { return }
        restoreDemoStateIfRequested()
        if service.isSyncing != wasSyncing {
            stateChanged()
            return
        }
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            switch dataSource.itemIdentifier(for: indexPath) {
            case .run:
                (tableView.cellForRow(at: indexPath) as? WatchSyncRunCell)?.configure(service: service)
            case let .album(id):
                guard
                    let cell = tableView.cellForRow(at: indexPath) as? WatchSyncAlbumCell,
                    let album = albumsByID[id]
                else { continue }
                cell.configure(album: album, presentation: WatchAlbumPresentation.make(album: album, service: service))
            default:
                continue
            }
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case let .quality(profile): choose(profile)
        case let .album(id): albumsByID[id].map(toggle)
        default: break
        }
    }

    override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .quality, .album: true
        default: false
        }
    }

    private func choose(_ profile: WatchAudioProfile) {
        guard profile != service.profile else { return }
        selection.selectionChanged()
        service.setProfile(profile)
    }

    private func toggle(_ album: Album) {
        guard canSync else {
            explainUnavailable()
            return
        }
        switch service.state(of: album) {
        case .synced:
            confirmRemove(album: album)
        case .failed:
            retryStuck()
        case .waiting, .preparing, .sending:
            explainAlreadyOnItsWay()
        default:
            send(album)
        }
    }

    private func send(_ album: Album) {
        guard canSync else {
            explainUnavailable()
            return
        }
        if case let .tooLarge(needed, free) = service.fitResult(for: album) {
            showWontFit(album: album, needed: needed, free: free)
        } else {
            start(album)
        }
    }

    /// Hands the album to the service and answers in the same turn: a haptic, the
    /// row and card repainted at once, a toast and a VoiceOver announcement.
    private func start(_ album: Album) {
        switch service.sync(tracks: album.tracks) {
        case let .started(count):
            impact.impactOccurred()
            songsInRun += count
            applySnapshot(animated: true)
            report(startedMessage(count: count))
        case .nothingToSend:
            selection.selectionChanged()
            applySnapshot(animated: true)
            report(String(localized: "Already on your Watch"), style: .success)
        case .notReady:
            explainUnavailable()
        }
    }

    private func startedMessage(count: Int) -> String {
        if case .waitingForWatch = readiness {
            return count == 1
                ? String(localized: "1 song queued. It sends when your Watch is nearby")
                : String(localized: "\(count) songs queued. They send when your Watch is nearby")
        }
        return count == 1
            ? String(localized: "Sending 1 song to your Watch")
            : String(localized: "Sending \(count) songs to your Watch")
    }

    private func reportRunFinished() {
        let count = songsInRun
        songsInRun = 0
        let message: String
        switch count {
        case 0: message = String(localized: "Your music is on your Watch")
        case 1: message = String(localized: "1 song is on your Watch")
        default: message = String(localized: "\(count) songs are on your Watch")
        }
        showToast(message, style: .success)
        announce(message)
    }

    /// A tap on something that cannot happen yet is never silent: a warning
    /// haptic and the explanation, as the setup sheet where there is one.
    private func explainUnavailable() {
        notify.notificationOccurred(.warning)
        let current = readiness
        if let topic = helpTopic(for: current) {
            presentHelp(topic)
            return
        }
        switch current {
        case .waitingForWatch(.activating):
            report(String(localized: "Still connecting to your Watch. Try again in a moment"))
        case .notSupported:
            report(current.unavailableReason)
        case .waitingForWatch, .ready, .notInstalled, .notPaired:
            report(current.stillNotReadyMessage)
        }
    }

    private func explainAlreadyOnItsWay() {
        selection.selectionChanged()
        if case .waitingForWatch = readiness {
            report(String(localized: "Queued. It sends when your Watch is nearby"))
        } else {
            report(String(localized: "Already on its way to your Watch"))
        }
    }

    private func presentHelp(_ topic: WatchSyncHelpViewController.Topic) {
        guard presentedViewController == nil else { return }
        let sheet = WatchSyncHelpViewController(topic: topic)
        sheet.performCheck = { [weak self] completion in
            guard let self else { return }
            self.checkAgain(reportsWithToast: false, completion: completion)
        }
        sheet.modalPresentationStyle = .pageSheet
        if let presentation = sheet.sheetPresentationController {
            presentation.detents = [.medium(), .large()]
            presentation.prefersGrabberVisible = true
            presentation.prefersScrollingExpandsWhenScrolledToEdge = false
            if traitCollection.preferredContentSizeCategory.isAccessibilityCategory {
                presentation.selectedDetentIdentifier = .large
            }
        }
        present(sheet, animated: true)
    }

    private func checkAgain(
        reportsWithToast: Bool = true,
        completion: ((WatchSyncService.Readiness) -> Void)? = nil
    ) {
        guard !isChecking else { return }
        selection.selectionChanged()
        isChecking = true
        reconfigureStatusRow()
        announce(String(localized: "Checking your Apple Watch"))
        if !WatchSyncLink.isSimulated {
            service.requestWatchState()
            service.reconcile()
        }
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.finishCheck(reportsWithToast: reportsWithToast, completion: completion)
        }
    }

    private func finishCheck(reportsWithToast: Bool, completion: ((WatchSyncService.Readiness) -> Void)?) {
        isChecking = false
        let current = readiness
        let changed = lastReadiness != current
        noteReadinessChange()
        applySnapshot(animated: true)
        if reportsWithToast, !changed, !current.isReady {
            showToast(current.stillNotReadyMessage, style: .info)
            announce(current.stillNotReadyMessage)
        }
        completion?(current)
    }

    private func reconfigureStatusRow() {
        guard isViewLoaded, dataSource != nil else { return }
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(.status) else { return }
        snapshot.reconfigureItems([.status])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Celebrates the moment a watch that needed setting up becomes usable,
    /// whichever way it was noticed: Check Again, or the system telling us.
    private func noteReadinessChange() {
        let current = readiness
        defer { lastReadiness = current }
        guard let previous = lastReadiness, previous != current else { return }
        guard current.isReady, previous.needsSetup else { return }
        notify.notificationOccurred(.success)
        let message = String(localized: "Your Apple Watch is ready. Choose an album to send")
        showToast(message, style: .success)
        announce(message)
    }

    private func showToast(_ message: String, style: ToastView.Style = .info) {
        guard view.window != nil else { return }
        ToastView.show(message, in: toastHost, style: style)
    }

    private func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func report(_ message: String, style: ToastView.Style = .info) {
        showToast(message, style: style)
        announce(message)
    }

    private func retryStuck() {
        guard canSync else {
            explainUnavailable()
            return
        }
        let count = service.stuckCount
        guard count > 0 else {
            selection.selectionChanged()
            report(String(localized: "Nothing to retry"))
            return
        }
        impact.impactOccurred()
        service.retryStuck()
        applySnapshot(animated: true)
        report(count == 1 ? String(localized: "Retrying 1 song") : String(localized: "Retrying \(count) songs"))
    }

    private func showWontFit(album: Album, needed: Int64, free: Int64) {
        notify.notificationOccurred(.warning)
        let alert = UIAlertController(
            title: String(localized: "Not Enough Space"),
            message: String(localized: "“\(album.title)” needs \(SyncFormat.size(needed)), but your Apple Watch has \(SyncFormat.size(free)) free. Remove some music first."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Sync Anyway"), style: .default) { [weak self] _ in
            self?.start(album)
        })
        present(alert, animated: true)
    }

    private func confirmRemoveAll() {
        guard service.syncedCount > 0 || service.requestedCount > 0 else {
            notify.notificationOccurred(.warning)
            report(String(localized: "There’s no music on your Watch to remove"))
            return
        }
        let alert = UIAlertController(
            title: String(localized: "Remove All from Watch"),
            message: String(localized: "Delete all synced music from your Apple Watch and start fresh?"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Remove All"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.impact.impactOccurred()
            self.service.removeAll()
            self.applySnapshot(animated: true)
            self.report(String(localized: "Removing all music from your Watch"))
        })
        present(alert, animated: true)
    }

    private func confirmRemove(album: Album) {
        let size = SyncFormat.size(WatchSyncSizing.totalBytes(in: album, profile: service.profile))
        let alert = UIAlertController(
            title: String(localized: "Remove from Watch"),
            message: String(localized: "Delete “\(album.title)” (\(size)) from your Apple Watch?"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Remove"), style: .destructive) { [weak self] _ in
            self?.removeFromWatch(album)
        })
        present(alert, animated: true)
    }

    private func removeFromWatch(_ album: Album) {
        guard service.remove(tracks: album.tracks) else {
            notify.notificationOccurred(.warning)
            report(String(localized: "Couldn’t reach your Watch. Try again in a moment"), style: .error)
            return
        }
        impact.impactOccurred()
        applySnapshot(animated: true)
        report(String(localized: "Removing “\(album.title)” from your Watch"))
    }

    private func hasMusicOnWatch(_ album: Album) -> Bool {
        service.state(of: album) != .notSynced
    }

    override func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard case let .album(id) = dataSource.itemIdentifier(for: indexPath), let album = albumsByID[id] else { return nil }
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: self.canSync ? self.albumActions(for: album) : self.unavailableActions())
        }
    }

    /// What the menu offers while nothing can be sent: the disabled action says
    /// why, and the setup help is one tap away.
    private func unavailableActions() -> [UIMenuElement] {
        let current = readiness
        let send = UIAction(
            title: String(localized: "Send to Watch"),
            image: UIImage(systemName: "applewatch.radiowaves.left.and.right"),
            attributes: .disabled
        ) { _ in }
        send.subtitle = current.unavailableReason
        var actions: [UIMenuElement] = [send]
        if let topic = helpTopic(for: current) {
            actions.append(UIAction(title: String(localized: "Show Me How"), image: UIImage(systemName: "list.number")) { [weak self] _ in
                self?.presentHelp(topic)
            })
        }
        return actions
    }

    private func albumActions(for album: Album) -> [UIMenuElement] {
        let state = service.state(of: album)
        var actions: [UIMenuElement] = []
        if state == .failed {
            actions.append(UIAction(title: String(localized: "Retry"), image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                self?.retryStuck()
            })
        }
        if state != .synced {
            actions.append(UIAction(title: String(localized: "Send to Watch"), image: UIImage(systemName: "applewatch.radiowaves.left.and.right")) { [weak self] _ in
                self?.send(album)
            })
        }
        if hasMusicOnWatch(album) {
            actions.append(UIAction(title: String(localized: "Remove from Watch"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.confirmRemove(album: album)
            })
        }
        return actions
    }

    override func tableView(
        _ tableView: UITableView,
        leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard case let .album(id) = dataSource.itemIdentifier(for: indexPath), let album = albumsByID[id],
              service.state(of: album) != .synced else { return nil }
        guard canSync else {
            guard let topic = helpTopic(for: readiness) else { return nil }
            let help = UIContextualAction(style: .normal, title: String(localized: "Show Me How")) { [weak self] _, _, completion in
                self?.presentHelp(topic)
                completion(true)
            }
            help.image = UIImage(systemName: "list.number")
            help.backgroundColor = .systemOrange
            return UISwipeActionsConfiguration(actions: [help])
        }
        let action = UIContextualAction(style: .normal, title: String(localized: "Send to Watch")) { [weak self] _, _, completion in
            self?.send(album)
            completion(true)
        }
        action.image = UIImage(systemName: "applewatch.radiowaves.left.and.right")
        action.backgroundColor = .systemBlue
        return UISwipeActionsConfiguration(actions: [action])
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard case let .album(id) = dataSource.itemIdentifier(for: indexPath), let album = albumsByID[id],
              hasMusicOnWatch(album) else { return nil }
        let action = UIContextualAction(style: .destructive, title: String(localized: "Remove")) { [weak self] _, _, completion in
            self?.confirmRemove(album: album)
            completion(false)
        }
        action.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [action])
    }
}

extension WatchSyncViewController: UISearchResultsUpdating {

    func updateSearchResults(for searchController: UISearchController) {
        let query = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != searchQuery else { return }
        searchQuery = query
        applyFilter()
        applySnapshot(animated: false)
    }
}
