import UIKit

final class SettingsViewController: UITableViewController {

    var onImportFiles: (() -> Void)?

    private enum Section: Int, CaseIterable {
        case lastFM
        case playback
        case library
        case about
    }

    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let notificationFeedback = UINotificationFeedbackGenerator()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        view.backgroundColor = .systemGroupedBackground
        tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.delegate = self
        tableView.dataSource = self

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                self?.dismiss(animated: true)
            }
        )
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    private var pendingScrobbleCount: Int {
        (try? DatabaseManager.shared.fetchPendingScrobbles().count) ?? 0
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .lastFM: return pendingScrobbleCount > 0 ? 2 : 1
        case .playback: return 2
        case .library: return 4
        case .about: return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .lastFM: return "Last.fm"
        case .playback: return "Playback"
        case .library: return "Library"
        case .about: return "About"
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .lastFM:
            if indexPath.row == 0 {
                return lastFMCell()
            }
            return pendingScrobblesCell()
        case .playback:
            return indexPath.row == 0 ? gaplessPlaybackCell() : audioQualityCell()
        case .library:
            switch indexPath.row {
            case 0: return importFilesCell()
            case 1: return rescanCell()
            case 2: return libraryStatsCell()
            default: return storageCell()
            }
        case .about:
            return aboutCell()
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        switch Section(rawValue: indexPath.section)! {
        case .lastFM:
            if indexPath.row == 0 {
                handleLastFMTap()
            } else {
                handleRetryScrobbles()
            }
        case .playback:
            break
        case .library:
            if indexPath.row == 0 {
                handleImportTap()
            } else if indexPath.row == 1 {
                handleRescanTap()
            }
        case .about:
            break
        }
    }

    override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        switch Section(rawValue: indexPath.section)! {
        case .lastFM: return true
        case .playback: return false
        case .library: return indexPath.row <= 1
        case .about: return false
        }
    }

    private func pendingScrobblesCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        let count = pendingScrobbleCount

        let countLabel = UILabel()
        countLabel.text = "\(count) pending scrobble\(count == 1 ? "" : "s")"
        countLabel.font = .preferredFont(forTextStyle: .body)
        countLabel.textColor = .secondaryLabel

        let retryLabel = UILabel()
        retryLabel.text = "Retry"
        retryLabel.font = .preferredFont(forTextStyle: .body)
        retryLabel.textColor = .tintColor

        let stack = UIStackView(arrangedSubviews: [countLabel, retryLabel])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        cell.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.bottomAnchor),
        ])

        return cell
    }

    private func handleRetryScrobbles() {
        impactLight.impactOccurred()
        Task {
            await AudioPlayer.shared.retryPendingScrobbles()
            notificationFeedback.notificationOccurred(.success)
            tableView.reloadSections(IndexSet(integer: Section.lastFM.rawValue), with: .automatic)
        }
    }

    private func lastFMCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        let authenticated = LastFMService.shared.isAuthenticated

        let dot = UIView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.backgroundColor = authenticated ? .systemGreen : .systemGray
        dot.layer.cornerRadius = 5

        let titleLabel = UILabel()
        titleLabel.font = .preferredFont(forTextStyle: .body)

        let statusLabel = UILabel()
        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.textColor = .secondaryLabel

        if authenticated {
            titleLabel.text = "Disconnect Last.fm"
            statusLabel.text = "Connected"
            titleLabel.textColor = .systemRed
        } else {
            titleLabel.text = "Connect to Last.fm"
            statusLabel.text = "Not connected"
            titleLabel.textColor = .label
        }

        let textStack = UIStackView(arrangedSubviews: [titleLabel, statusLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        let mainStack = UIStackView(arrangedSubviews: [dot, textStack])
        mainStack.axis = .horizontal
        mainStack.spacing = 12
        mainStack.alignment = .center
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        cell.contentView.addSubview(mainStack)

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            mainStack.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            mainStack.topAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.topAnchor),
            mainStack.bottomAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.bottomAnchor),
        ])

        if !authenticated {
            cell.accessoryType = .disclosureIndicator
        }

        return cell
    }

    private func importFilesCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)

        let icon = UIImageView(image: UIImage(systemName: "square.and.arrow.down"))
        icon.tintColor = .tintColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = "Import Files"
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .tintColor

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        cell.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            stack.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.bottomAnchor),
        ])

        return cell
    }

    private func handleImportTap() {
        impactLight.impactOccurred()
        dismiss(animated: true) { [weak self] in
            self?.onImportFiles?()
        }
    }

    private func rescanCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)

        let icon = UIImageView(image: UIImage(systemName: "arrow.clockwise"))
        icon.tintColor = .tintColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = "Rescan Library"
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .tintColor

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        cell.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            stack.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.bottomAnchor),
        ])

        return cell
    }

    private func libraryStatsCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none

        let library = Library.shared
        let albumCount = library.albums.count
        let trackCount = library.allTracks.count

        let albumLabel = UILabel()
        albumLabel.text = "\(albumCount) album\(albumCount == 1 ? "" : "s")"
        albumLabel.font = .preferredFont(forTextStyle: .body)
        albumLabel.textColor = .secondaryLabel

        let trackLabel = UILabel()
        trackLabel.text = "\(trackCount) track\(trackCount == 1 ? "" : "s")"
        trackLabel.font = .preferredFont(forTextStyle: .body)
        trackLabel.textColor = .secondaryLabel

        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [albumLabel, separator, trackLabel])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        cell.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.heightAnchor.constraint(equalToConstant: 16),
            stack.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.bottomAnchor),
        ])

        return cell
    }

    private func aboutCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none

        let appLabel = UILabel()
        appLabel.text = "flaccy"
        appLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

        let versionLabel = UILabel()
        versionLabel.text = "Version \(version) (\(build))"
        versionLabel.font = .preferredFont(forTextStyle: .caption1)
        versionLabel.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [appLabel, versionLabel])
        stack.axis = .vertical
        stack.spacing = 2
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        cell.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.bottomAnchor),
        ])

        return cell
    }

    private func gaplessPlaybackCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none

        let label = UILabel()
        label.text = "Gapless Playback"
        label.font = .preferredFont(forTextStyle: .body)

        let toggle = UISwitch()
        toggle.isOn = UserDefaults.standard.object(forKey: "gaplessPlayback") as? Bool ?? true
        toggle.addAction(UIAction { _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            UserDefaults.standard.set(toggle.isOn, forKey: "gaplessPlayback")
        }, for: .valueChanged)

        let stack = UIStackView(arrangedSubviews: [label, toggle])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        cell.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.bottomAnchor),
        ])

        return cell
    }

    private func audioQualityCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none

        let titleLabel = UILabel()
        titleLabel.text = "Audio Quality"
        titleLabel.font = .preferredFont(forTextStyle: .body)

        let valueLabel = UILabel()
        valueLabel.text = "FLAC (Lossless)"
        valueLabel.font = .preferredFont(forTextStyle: .body)
        valueLabel.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        cell.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.bottomAnchor),
        ])

        return cell
    }

    private func storageCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none

        let titleLabel = UILabel()
        titleLabel.text = "Storage Used"
        titleLabel.font = .preferredFont(forTextStyle: .body)

        let valueLabel = UILabel()
        valueLabel.text = calculateStorageUsed()
        valueLabel.font = .preferredFont(forTextStyle: .body)
        valueLabel.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        cell.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.bottomAnchor),
        ])

        return cell
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

    private func handleLastFMTap() {
        if LastFMService.shared.isAuthenticated {
            impactMedium.impactOccurred()
            let alert = UIAlertController(
                title: "Disconnect Last.fm",
                message: "This will stop scrobbling your listens.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Disconnect", style: .destructive) { [weak self] _ in
                LastFMService.shared.logout()
                self?.notificationFeedback.notificationOccurred(.success)
                self?.tableView.reloadSections(IndexSet(integer: Section.lastFM.rawValue), with: .automatic)
            })
            present(alert, animated: true)
        } else {
            impactLight.impactOccurred()
            guard let window = view.window else { return }
            Task {
                do {
                    try await LastFMService.shared.authenticate(from: window)
                    notificationFeedback.notificationOccurred(.success)
                    tableView.reloadSections(IndexSet(integer: Section.lastFM.rawValue), with: .automatic)
                } catch {
                    AppLogger.error("Last.fm auth failed: \(error.localizedDescription)", category: .auth)
                }
            }
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
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                systemItem: .done,
                primaryAction: UIAction { [weak self] _ in
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    self?.dismiss(animated: true)
                }
            )
            notificationFeedback.notificationOccurred(.success)
            tableView.reloadData()
        }
    }
}
