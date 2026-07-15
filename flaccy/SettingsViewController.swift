import AuthenticationServices
import StoreKit
import UIKit

final class SettingsViewController: UITableViewController {

    var onImportFiles: (() -> Void)?

    nonisolated private enum Section: Int, CaseIterable, Hashable {
        case appearance
        case lastFM
        case recap
        case playback
        case guide
        case watch
        case library

        var header: String? {
            switch self {
            case .appearance: return "Appearance"
            case .lastFM: return "Last.fm"
            case .recap: return "Year in Music"
            case .playback: return "Playback"
            case .guide: return nil
            case .watch: return "Apple Watch"
            case .library: return "Library"
            }
        }

        var footer: String? {
            switch self {
            case .appearance: return "System follows your device's light and dark setting."
            case .lastFM: return nil
            case .recap: return "Recap notifications are generated on this device from your local play history, with a shareable Year in Music story."
            case .playback: return "Gapless plays consecutive album tracks without silence. Autoplay keeps a similar-music station going when the queue ends."
            case .guide: return "How Bluetooth, AAC, and lossless files really affect what you hear."
            case .watch: return nil
            case .library: return nil
            }
        }
    }

    nonisolated private enum Row: Hashable {
        case appearance(AppAppearance)
        case lastFMAccount(username: String?)
        case pendingScrobbles(count: Int)
        case importLastFM
        case yearInMusic
        case recapNotifications(frequency: String)
        case gaplessPlayback
        case autoplaySimilar
        case libraryRadio
        case crateDig
        case listeningGuide
        case watchSync(syncedCount: Int)
        case importFiles
        case rescanLibrary
        case libraryStats(albums: Int, tracks: Int)
        case storage(used: String)
    }

    /// Renders an Apple-Settings-style icon: a white SF Symbol glyph centered
    /// on a tinted continuous-corner rounded square.
    private enum RowIcon {
        static let side: CGFloat = 29

        static func image(systemName: String, tint: UIColor) -> UIImage {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
            return renderer.image { _ in
                let rect = CGRect(x: 0, y: 0, width: side, height: side)
                let path = UIBezierPath(roundedRect: rect, cornerRadius: 6.5)
                tint.setFill()
                path.fill()
                let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
                guard let glyph = UIImage(systemName: systemName, withConfiguration: config)?
                    .withTintColor(.white, renderingMode: .alwaysOriginal) else { return }
                let glyphRect = CGRect(
                    x: (side - glyph.size.width) / 2,
                    y: (side - glyph.size.height) / 2,
                    width: glyph.size.width,
                    height: glyph.size.height
                )
                glyph.draw(in: glyphRect)
            }
        }
    }

    private final class DataSource: UITableViewDiffableDataSource<Section, Row> {
        var footerForSection: ((Section) -> String?)?

        override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
            sectionIdentifier(for: section)?.header
        }

        override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
            guard let section = sectionIdentifier(for: section) else { return nil }
            return footerForSection?(section) ?? section.footer
        }
    }

    private static let cellReuseIdentifier = "SettingsCell"

    private let selectionFeedback = UISelectionFeedbackGenerator()
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let notificationFeedback = UINotificationFeedbackGenerator()

    private let headerView = SettingsHeaderView()
    private var dataSource: DataSource!
    private var storageUsed: String?
    private var playsCount: Int?
    private var lastFMImportProgress: Int?
    private var isRescanning = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellReuseIdentifier)
        tableView.register(AppearanceCell.self, forCellReuseIdentifier: AppearanceCell.reuseID)
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = makeDoneButton()
        configureDataSource()
        configureHeader()
        tableView.tableFooterView = makeVersionFooter()
        applySnapshot(animated: false)
        refreshHeader()
        refreshStorageUsed()
        refreshPlaysCount()
        loadPriceIfNeeded()

        NotificationCenter.default.addObserver(
            self, selector: #selector(purchaseStateChanged),
            name: PurchaseManager.stateDidChange, object: nil
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applySnapshot(animated: false)
        refreshHeader()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sizeHeaderToFit()
    }

    @objc private func purchaseStateChanged() {
        refreshHeader()
        applySnapshot(animated: true)
    }

    private func makeDoneButton() -> UIBarButtonItem {
        UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in
                self?.impactLight.impactOccurred()
                self?.dismiss(animated: true)
            }
        )
    }

    private func configureHeader() {
        headerView.onUnlockTapped = { [weak self] in
            guard let self else { return }
            self.impactMedium.impactOccurred()
            PaywallViewController.presentSheet(from: self)
        }
        tableView.tableHeaderView = headerView
    }

    private func refreshHeader() {
        headerView.configure(
            state: PurchaseManager.shared.state,
            priceText: PurchaseManager.shared.product?.displayPrice,
            albums: Library.shared.albums.count,
            tracks: Library.shared.allTracks.count,
            plays: playsCount
        )
        sizeHeaderToFit()
    }

    /// A `tableHeaderView` is frame-driven, so its Auto Layout height is measured
    /// and stamped whenever the width or content changes, re-assigning the header
    /// to force the table to adopt the new height.
    private func sizeHeaderToFit() {
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

    private func configureDataSource() {
        dataSource = DataSource(tableView: tableView) {
            [weak self] tableView, indexPath, row in
            self?.cell(for: row, at: indexPath, in: tableView) ?? UITableViewCell()
        }
        dataSource.footerForSection = { [weak self] section in
            section == .lastFM ? self?.lastFMFooter() : nil
        }
        dataSource.defaultRowAnimation = .fade
    }

    private var pendingScrobbleCount: Int {
        (try? DatabaseManager.shared.fetchPendingScrobbles().count) ?? 0
    }

    private func applySnapshot(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems([.appearance(AppAppearance.current)], toSection: .appearance)

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
        snapshot.appendItems([.gaplessPlayback, .autoplaySimilar, .libraryRadio, .crateDig], toSection: .playback)
        snapshot.appendItems([.listeningGuide], toSection: .guide)
        snapshot.appendItems([.watchSync(syncedCount: WatchSyncService.shared.syncedPaths.count)], toSection: .watch)
        snapshot.appendItems(
            [
                .importFiles,
                .rescanLibrary,
                .libraryStats(albums: Library.shared.albums.count, tracks: Library.shared.allTracks.count),
                .storage(used: storageUsed ?? "…"),
            ],
            toSection: .library
        )
        snapshot.reloadSections([.lastFM])
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    private func cell(for row: Row, at indexPath: IndexPath, in tableView: UITableView) -> UITableViewCell {
        if case .appearance(let current) = row {
            return appearanceCell(current: current, in: tableView, at: indexPath)
        }

        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellReuseIdentifier, for: indexPath)
        cell.accessoryType = .none
        cell.accessoryView = nil
        cell.selectionStyle = .default
        cell.accessibilityTraits = .button
        cell.accessibilityValue = nil
        cell.accessibilityHint = nil

        var content = UIListContentConfiguration.valueCell()
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .body)
        content.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.color = .secondaryLabel
        content.imageProperties.maximumSize = CGSize(width: RowIcon.side, height: RowIcon.side)

        switch row {
        case .appearance:
            break

        case .lastFMAccount(let username):
            content.image = RowIcon.image(systemName: "dot.radiowaves.left.and.right", tint: .systemRed)
            if let username {
                content.text = "Last.fm Account"
                content.secondaryText = username
                cell.accessoryType = .disclosureIndicator
                cell.accessibilityHint = "Shows account options"
            } else {
                content.text = "Connect to Last.fm"
                cell.accessoryType = .disclosureIndicator
                cell.accessibilityHint = "Signs in to Last.fm to scrobble your listens"
            }
            cell.accessibilityLabel = content.text
            cell.accessibilityValue = content.secondaryText

        case .pendingScrobbles(let count):
            content.image = RowIcon.image(systemName: "clock.arrow.circlepath", tint: .systemOrange)
            content.text = "Retry Pending Scrobbles"
            content.secondaryText = "\(count)"
            content.textProperties.color = .tintColor
            cell.accessibilityLabel = "Retry pending scrobbles"
            cell.accessibilityValue = "\(count) pending scrobble\(count == 1 ? "" : "s")"

        case .importLastFM:
            content.image = RowIcon.image(systemName: "square.and.arrow.down.on.square", tint: .systemPink)
            if let imported = lastFMImportProgress {
                content.text = "Importing Last.fm History"
                if imported > 0 { content.secondaryText = "\(imported)" }
                cell.accessoryView = makeSpinnerAccessory()
                cell.selectionStyle = .none
                cell.accessibilityLabel = "Importing Last.fm History"
                if imported > 0 {
                    cell.accessibilityValue = "\(imported) scrobble\(imported == 1 ? "" : "s") imported"
                }
            } else {
                content.text = "Import Last.fm History"
                content.textProperties.color = .tintColor
                cell.accessibilityLabel = "Import Last.fm History"
                cell.accessibilityHint = "Backfills your listening stats from Last.fm"
            }

        case .yearInMusic:
            content.image = RowIcon.image(systemName: "sparkles", tint: .systemIndigo)
            content.text = "Your Year in Music"
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityLabel = "Your Year in Music"
            cell.accessibilityHint = "Shows your yearly listening recap with shareable story cards"

        case .recapNotifications(let frequency):
            content.image = RowIcon.image(systemName: "bell.badge.fill", tint: .systemRed)
            content.text = "Recap Notifications"
            content.secondaryText = frequency
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityLabel = "Recap Notifications"
            cell.accessibilityValue = frequency
            cell.accessibilityHint = "Chooses how often flaccy reminds you about your recap"

        case .gaplessPlayback:
            content.image = RowIcon.image(systemName: "infinity", tint: .systemPurple)
            content.text = "Gapless Playback"
            cell.selectionStyle = .none
            cell.accessoryView = makeGaplessSwitch()
            cell.accessibilityTraits = []

        case .autoplaySimilar:
            content.image = RowIcon.image(systemName: "infinity.circle", tint: .systemPink)
            content.text = "Autoplay Similar"
            cell.selectionStyle = .none
            cell.accessoryView = makeAutoplaySwitch()
            cell.accessibilityTraits = []

        case .libraryRadio:
            content.image = RowIcon.image(systemName: "dot.radiowaves.left.and.right", tint: .systemOrange)
            content.text = "Library Radio"
            content.textProperties.color = .tintColor
            cell.accessibilityLabel = "Library Radio"
            cell.accessibilityHint = "Plays a station from your most-played tracks"

        case .crateDig:
            content.image = RowIcon.image(systemName: "opticaldisc.fill", tint: .systemIndigo)
            content.text = "Crate Dig"
            content.textProperties.color = .tintColor
            cell.accessibilityLabel = "Crate Dig"
            cell.accessibilityHint = "Plays deep cuts from albums you already love"

        case .listeningGuide:
            content.image = RowIcon.image(systemName: "waveform", tint: .systemCyan)
            content.text = "Listening Guide"
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityLabel = "Listening Guide"
            cell.accessibilityHint = "Explains how Bluetooth, AAC, and lossless audio affect what you hear"

        case .watchSync(let syncedCount):
            content.image = RowIcon.image(systemName: "applewatch", tint: .systemBlue)
            content.text = "Sync Music to Watch"
            if syncedCount > 0 { content.secondaryText = "\(syncedCount)" }
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityLabel = "Sync Music to Watch"
            if syncedCount > 0 {
                cell.accessibilityValue = "\(syncedCount) track\(syncedCount == 1 ? "" : "s") synced"
            }

        case .importFiles:
            content.image = RowIcon.image(systemName: "square.and.arrow.down", tint: .systemGreen)
            content.text = "Import Files"
            content.textProperties.color = .tintColor
            cell.accessibilityLabel = "Import Files"
            cell.accessibilityHint = "Opens the file browser to add music"

        case .rescanLibrary:
            content.image = RowIcon.image(systemName: "arrow.clockwise", tint: .systemIndigo)
            if isRescanning {
                content.text = "Rescanning Library"
                content.textProperties.color = .secondaryLabel
                cell.accessoryView = makeSpinnerAccessory()
                cell.selectionStyle = .none
                cell.accessibilityLabel = "Rescanning Library"
            } else {
                content.text = "Rescan Library"
                content.textProperties.color = .tintColor
                cell.accessibilityLabel = "Rescan Library"
                cell.accessibilityHint = "Re-analyzes all tracks"
            }

        case .libraryStats(let albums, let tracks):
            content.image = RowIcon.image(systemName: "chart.bar.fill", tint: .systemTeal)
            content.text = "Library"
            content.secondaryText = "\(albums) album\(albums == 1 ? "" : "s"), \(tracks) track\(tracks == 1 ? "" : "s")"
            cell.selectionStyle = .none
            cell.accessibilityTraits = .staticText
            cell.accessibilityLabel = "Library"
            cell.accessibilityValue = content.secondaryText

        case .storage(let used):
            content.image = RowIcon.image(systemName: "internaldrive.fill", tint: .systemGray)
            content.text = "Storage Used"
            content.secondaryText = used
            cell.selectionStyle = .none
            cell.accessibilityTraits = .staticText
            cell.accessibilityLabel = "Storage Used"
            cell.accessibilityValue = used
        }

        cell.contentConfiguration = content
        return cell
    }

    private func appearanceCell(current: AppAppearance, in tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: AppearanceCell.reuseID, for: indexPath) as! AppearanceCell
        cell.configure(selected: current)
        cell.onChange = { [weak self] appearance in
            guard let self else { return }
            self.selectionFeedback.selectionChanged()
            AppAppearance.current = appearance
            AppearanceApplier.apply(appearance, animated: true)
            AppLogger.info("Appearance set to \(appearance.displayName)", category: .ui)
        }
        return cell
    }

    private func makeSpinnerAccessory() -> UIActivityIndicatorView {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        return spinner
    }

    private func makeGaplessSwitch() -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = UserDefaults.standard.object(forKey: "gaplessPlayback") as? Bool ?? true
        toggle.accessibilityLabel = "Gapless Playback"
        toggle.addAction(UIAction { [weak self] action in
            guard let toggle = action.sender as? UISwitch else { return }
            self?.selectionFeedback.selectionChanged()
            UserDefaults.standard.set(toggle.isOn, forKey: "gaplessPlayback")
        }, for: .valueChanged)
        return toggle
    }

    private func makeAutoplaySwitch() -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = AudioPlayer.shared.autoplaySimilarWhenQueueEnds
        toggle.accessibilityLabel = "Autoplay Similar"
        toggle.accessibilityHint = "Keeps a similar-music station going when the queue ends"
        toggle.addAction(UIAction { [weak self] action in
            guard let toggle = action.sender as? UISwitch else { return }
            self?.selectionFeedback.selectionChanged()
            AudioPlayer.shared.autoplaySimilarWhenQueueEnds = toggle.isOn
        }, for: .valueChanged)
        return toggle
    }

    private func makeVersionFooter() -> UIView {
        let info = Bundle.main.infoDictionary
        let name = info?["CFBundleDisplayName"] as? String
            ?? info?["CFBundleName"] as? String
            ?? "flaccy"
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"

        let nameLabel = UILabel()
        nameLabel.text = name
        nameLabel.font = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .systemFont(ofSize: 13, weight: .semibold))
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .secondaryLabel
        nameLabel.textAlignment = .center

        let versionLabel = UILabel()
        versionLabel.text = "Version \(version) (\(build))"
        versionLabel.font = .preferredFont(forTextStyle: .footnote)
        versionLabel.adjustsFontForContentSizeCategory = true
        versionLabel.textColor = .tertiaryLabel
        versionLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [nameLabel, versionLabel])
        stack.axis = .vertical
        stack.spacing = 2
        stack.alignment = .center
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 20, left: 16, bottom: 24, right: 16)
        stack.isAccessibilityElement = true
        stack.accessibilityLabel = "\(name), version \(version), build \(build)"

        let width = view.bounds.width
        let size = stack.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        stack.frame = CGRect(origin: .zero, size: CGSize(width: width, height: size.height))
        return stack
    }

    private func lastFMFooter() -> String {
        if LastFMService.shared.isAuthenticated {
            return "Your listens are scrobbled to Last.fm and your loved tracks stay in sync."
        }
        return "Optional. Connect a Last.fm account to scrobble your listens, sync loved tracks, and import your listening history. Everything else works without it."
    }

    override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return false }
        switch row {
        case .appearance, .gaplessPlayback, .autoplaySimilar, .libraryStats, .storage: return false
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
        case .watchSync: handleWatchTap()
        case .importFiles: handleImportTap()
        case .rescanLibrary: handleRescanTap()
        case .appearance, .gaplessPlayback, .autoplaySimilar, .libraryStats, .storage: break
        }
    }

    private func handleLastFMTap() {
        if LastFMService.shared.isAuthenticated {
            presentLastFMAccountSheet()
        } else {
            connectLastFM()
        }
    }

    private func presentLastFMAccountSheet() {
        selectionFeedback.selectionChanged()
        let username = LastFMService.shared.username
        let sheet = UIAlertController(
            title: "Last.fm",
            message: username.map { "Connected as \($0)" } ?? "Connected",
            preferredStyle: .actionSheet
        )
        if let username, let profileURL = URL(string: "https://www.last.fm/user/\(username)") {
            sheet.addAction(UIAlertAction(title: "View Profile", style: .default) { _ in
                UIApplication.shared.open(profileURL)
            })
        }
        sheet.addAction(UIAlertAction(title: "Disconnect", style: .destructive) { [weak self] _ in
            self?.confirmDisconnectLastFM()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    private func confirmDisconnectLastFM() {
        impactMedium.impactOccurred()
        let alert = UIAlertController(
            title: "Disconnect Last.fm",
            message: "Your listens will no longer be scrobbled. Your library, play history, and loved tracks stay on this device.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Disconnect", style: .destructive) { [weak self] _ in
            LastFMService.shared.logout()
            self?.notificationFeedback.notificationOccurred(.success)
            self?.applySnapshot(animated: true)
        })
        present(alert, animated: true)
    }

    private func connectLastFM() {
        selectionFeedback.selectionChanged()
        guard let window = view.window else { return }
        Task {
            do {
                try await LastFMService.shared.authenticate(from: window)
                notificationFeedback.notificationOccurred(.success)
                applySnapshot(animated: true)
            } catch {
                AppLogger.error("Last.fm auth failed: \(error.localizedDescription)", category: .auth)
                guard !isAuthCancellation(error) else { return }
                notificationFeedback.notificationOccurred(.error)
                let alert = UIAlertController(
                    title: "Couldn't Connect",
                    message: "Last.fm sign-in didn't complete. Check your connection and try again.",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }

    private func isAuthCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == ASWebAuthenticationSessionError.errorDomain
            && nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
    }

    private func handleRetryScrobbles() {
        impactLight.impactOccurred()
        Task {
            await AudioPlayer.shared.retryPendingScrobbles()
            notificationFeedback.notificationOccurred(.success)
            applySnapshot(animated: true)
        }
    }

    private func handleLibraryRadio() {
        impactMedium.impactOccurred()
        AudioPlayer.shared.playLibraryRadio()
        dismiss(animated: true)
    }

    private func handleCrateDig() {
        impactMedium.impactOccurred()
        AudioPlayer.shared.playCrateDig()
        dismiss(animated: true)
    }

    /// Runs the history backfill with the import row rendered as an in-progress
    /// spinner. `importHistory()` reports nothing itself, so live progress is
    /// derived by polling the local scrobble count against a pre-import baseline,
    /// mirroring `ChartsViewModel.importHistory`.
    private func handleImportLastFM() {
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

    private func reconfigureRow(_ row: Row) {
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(row) else { return }
        snapshot.reconfigureItems([row])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private nonisolated static func scrobbleCount() -> Int {
        (try? DatabaseManager.shared.scrobbleCountInRange(from: .distantPast, to: .distantFuture)) ?? 0
    }

    private func handleYearInMusicTap() {
        impactMedium.impactOccurred()
        present(YearInMusicViewController(), animated: true)
    }

    private func handleRecapNotificationsTap() {
        selectionFeedback.selectionChanged()
        navigationController?.pushViewController(RecapNotificationsViewController(), animated: true)
    }

    private func handleListeningGuideTap() {
        selectionFeedback.selectionChanged()
        navigationController?.pushViewController(ListeningGuideViewController(), animated: true)
    }

    private func handleWatchTap() {
        selectionFeedback.selectionChanged()
        navigationController?.pushViewController(WatchSyncViewController(), animated: true)
    }

    private func handleImportTap() {
        impactLight.impactOccurred()
        dismiss(animated: true) { [weak self] in
            self?.onImportFiles?()
        }
    }

    private func handleRescanTap() {
        guard !isRescanning, !Library.shared.isLoading else { return }
        impactMedium.impactOccurred()
        let alert = UIAlertController(
            title: "Rescan Library",
            message: "This will re-analyze all tracks with AI. May take a few minutes for large libraries.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rescan", style: .default) { [weak self] _ in
            self?.performRescan()
        })
        present(alert, animated: true)
    }

    /// Runs the rescan with only the rescan row disabled and spinning, so the
    /// sheet stays dismissible; the singleton `Library` carries the work if this
    /// controller is deallocated mid-scan.
    private func performRescan() {
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
        }
    }

    /// Recomputes the Documents-tree size off the main thread and re-renders the
    /// storage row when it lands; every other snapshot renders the cached value.
    private func refreshStorageUsed() {
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
    private func refreshPlaysCount() {
        Task.detached(priority: .utility) { [weak self] in
            let plays = Self.scrobbleCount()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.playsCount = plays
                self.refreshHeader()
            }
        }
    }

    private func loadPriceIfNeeded() {
        guard PurchaseManager.shared.product == nil else { return }
        Task { [weak self] in
            await PurchaseManager.shared.loadProductIfNeeded()
            self?.refreshHeader()
        }
    }

    private nonisolated static func calculateStorageUsed() -> String {
        let fm = FileManager.default
        let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var totalSize: Int64 = 0

        guard let enumerator = fm.enumerator(
            at: docsURL, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return "0 MB" }

        for case let fileURL as URL in enumerator {
            if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let fileSize = resourceValues.fileSize {
                totalSize += Int64(fileSize)
            }
        }

        let gigabytes = Double(totalSize) / 1_073_741_824
        if gigabytes >= 1.0 {
            return String(format: "%.1f GB", gigabytes)
        }
        let megabytes = Double(totalSize) / 1_048_576
        return String(format: "%.0f MB", megabytes)
    }
}

/// A settings row hosting a full-width segmented control for the light/dark
/// override, applied live as the user drags across it.
private final class AppearanceCell: UITableViewCell {

    static let reuseID = "AppearanceCell"

    var onChange: ((AppAppearance) -> Void)?

    private let segmented = UISegmentedControl(items: AppAppearance.allCases.map(\.displayName))

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        segmented.translatesAutoresizingMaskIntoConstraints = false
        segmented.addTarget(self, action: #selector(changed), for: .valueChanged)
        contentView.addSubview(segmented)
        NSLayoutConstraint.activate([
            segmented.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            segmented.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            segmented.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            segmented.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(selected: AppAppearance) {
        segmented.selectedSegmentIndex = selected.rawValue
    }

    @objc private func changed() {
        guard let appearance = AppAppearance(rawValue: segmented.selectedSegmentIndex) else { return }
        onChange?(appearance)
    }
}
