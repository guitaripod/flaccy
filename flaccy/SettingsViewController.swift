import AuthenticationServices
import UIKit

final class SettingsViewController: UITableViewController {

    var onImportFiles: (() -> Void)?

    nonisolated private enum Section: Int, CaseIterable, Hashable {
        case lastFM
        case playback
        case watch
        case library

        var header: String? {
            switch self {
            case .lastFM: return "Last.fm"
            case .playback: return "Playback"
            case .watch: return "Apple Watch"
            case .library: return "Library"
            }
        }

        var footer: String? {
            switch self {
            case .lastFM: return nil
            case .playback: return "Gapless plays consecutive album tracks without silence. Autoplay keeps a similar-music station going when the queue ends."
            case .watch: return nil
            case .library: return nil
            }
        }
    }

    nonisolated private enum Row: Hashable {
        case lastFMAccount(username: String?)
        case pendingScrobbles(count: Int)
        case importLastFM
        case gaplessPlayback
        case autoplaySimilar
        case libraryRadio
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

    private static let cellReuseIdentifier = "SettingsCell"

    private let selectionFeedback = UISelectionFeedbackGenerator()
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let notificationFeedback = UINotificationFeedbackGenerator()

    private var dataSource: UITableViewDiffableDataSource<Section, Row>!

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellReuseIdentifier)
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = makeDoneButton()
        configureDataSource()
        tableView.tableFooterView = makeVersionFooter()
        applySnapshot(animated: false)
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

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource<Section, Row>(tableView: tableView) {
            [weak self] tableView, indexPath, row in
            self?.cell(for: row, at: indexPath, in: tableView) ?? UITableViewCell()
        }
        dataSource.defaultRowAnimation = .fade
    }

    private var pendingScrobbleCount: Int {
        (try? DatabaseManager.shared.fetchPendingScrobbles().count) ?? 0
    }

    private func applySnapshot(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections(Section.allCases)

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
        snapshot.appendItems([.gaplessPlayback, .autoplaySimilar, .libraryRadio], toSection: .playback)
        snapshot.appendItems([.watchSync(syncedCount: WatchSyncService.shared.syncedPaths.count)], toSection: .watch)
        snapshot.appendItems(
            [
                .importFiles,
                .rescanLibrary,
                .libraryStats(albums: Library.shared.albums.count, tracks: Library.shared.allTracks.count),
                .storage(used: calculateStorageUsed()),
            ],
            toSection: .library
        )
        snapshot.reloadSections([.lastFM])
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    private func cell(for row: Row, at indexPath: IndexPath, in tableView: UITableView) -> UITableViewCell {
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
            content.text = "Import Last.fm History"
            content.textProperties.color = .tintColor
            cell.accessibilityLabel = "Import Last.fm History"
            cell.accessibilityHint = "Backfills your listening stats from Last.fm"

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
            content.text = "Rescan Library"
            content.textProperties.color = .tintColor
            cell.accessibilityLabel = "Rescan Library"
            cell.accessibilityHint = "Re-analyzes all tracks"

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

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        dataSource.sectionIdentifier(for: section)?.header
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let section = dataSource.sectionIdentifier(for: section) else { return nil }
        if section == .lastFM { return lastFMFooter() }
        return section.footer
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
        case .gaplessPlayback, .autoplaySimilar, .libraryStats, .storage: return false
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
        case .libraryRadio: handleLibraryRadio()
        case .watchSync: handleWatchTap()
        case .importFiles: handleImportTap()
        case .rescanLibrary: handleRescanTap()
        case .gaplessPlayback, .autoplaySimilar, .libraryStats, .storage: break
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

    private func handleImportLastFM() {
        impactLight.impactOccurred()
        Task {
            await LastFMStatsService.shared.importHistory()
            notificationFeedback.notificationOccurred(.success)
            applySnapshot(animated: true)
        }
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

    private func performRescan() {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
        navigationItem.rightBarButtonItem?.isEnabled = false
        view.isUserInteractionEnabled = false

        Task {
            await Library.shared.resetAndReload()
            view.isUserInteractionEnabled = true
            navigationItem.rightBarButtonItem = makeDoneButton()
            notificationFeedback.notificationOccurred(.success)
            applySnapshot(animated: true)
        }
    }

    private func calculateStorageUsed() -> String {
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
