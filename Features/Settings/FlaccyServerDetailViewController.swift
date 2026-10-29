import FlaccyCore
import MidgarCore
import UIKit

/// The screen of one Flaccy Server (docs/server/UX.md section 4): Status, Library, Sync, Devices and Disconnect.
final class FlaccyServerDetailViewController: UITableViewController {

    nonisolated enum Section: Int, Hashable, CaseIterable {
        case status
        case library
        case sync
        case devices
        case disconnect
    }

    nonisolated enum Row: Hashable {
        case status(String)
        case lastSynced(String)
        case songs(String)
        case libraryToggle(title: String, isOn: Bool)
        case syncToggle(title: String, isOn: Bool)
        case proSync(String)
        case devicesLoading
        case devicesFailed(String)
        case device(FlaccyServerDetailViewModel.DeviceRow)
        case disconnect(String)
    }

    private let model: FlaccyServerDetailViewModel
    private lazy var dataSource = DataSource(tableView: tableView) { [weak self] tableView, indexPath, row in
        self?.cell(for: row, at: indexPath, in: tableView) ?? UITableViewCell()
    }
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let heavy = UIImpactFeedbackGenerator(style: .medium)
    private let notification = UINotificationFeedbackGenerator()
    private var lastStatusLine = ""

    init(record: RemoteServerRecord) {
        model = FlaccyServerDetailViewModel(record: record)
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = model.name
        tableView.accessibilityIdentifier = "flaccyServer.table"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        dataSource.titles = { section in Self.header(for: section) }
        refreshControl = UIRefreshControl()
        refreshControl?.addAction(UIAction { [weak self] _ in self?.refreshDevices() }, for: .valueChanged)
        model.onChange = { [weak self] in self?.modelChanged() }
        model.onProRequested = { [weak self] in self?.presentPaywall() }
        model.start()
        applySnapshot(animated: false)
    }

    deinit {
        MainActor.assumeIsolated { model.stop() }
    }

    private final class DataSource: UITableViewDiffableDataSource<Section, Row> {
        var titles: ((Section) -> String?)?

        override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
            sectionIdentifier(for: section).flatMap { titles?($0) }
        }
    }

    private static func header(for section: Section) -> String? {
        switch section {
        case .status: String(localized: "Status")
        case .library: String(localized: "Library")
        case .sync: String(localized: "Sync")
        case .devices: String(localized: "Devices")
        case .disconnect: nil
        }
    }

    private func rows(in section: Section) -> [Row] {
        switch section {
        case .status:
            var rows: [Row] = [.status(model.statusLine)]
            if let last = model.lastSyncedLine { rows.append(.lastSynced(last)) }
            return rows
        case .library:
            return [.songs(model.songs), .libraryToggle(title: model.libraryToggleTitle, isOn: model.isLibraryShown)]
        case .sync:
            return model.isPro ? [.syncToggle(title: model.syncToggleTitle, isOn: model.isSyncOn)] : [.proSync(model.proRowTitle)]
        case .devices:
            switch model.devices {
            case .loading: return [.devicesLoading]
            case .failed(let message): return [.devicesFailed(message)]
            case .loaded(let devices): return devices.map(Row.device)
            }
        case .disconnect:
            return [.disconnect(model.disconnectTitle)]
        }
    }

    private func applySnapshot(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        for section in Section.allCases {
            snapshot.appendSections([section])
            snapshot.appendItems(rows(in: section), toSection: section)
        }
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    private func modelChanged() {
        guard isViewLoaded else { return }
        title = model.name
        refreshControl?.endRefreshing()
        applySnapshot(animated: false)
        let line = model.statusLine
        if line != lastStatusLine {
            lastStatusLine = line
            UIAccessibility.post(notification: .announcement, argument: line)
        }
    }

    private func cell(for row: Row, at indexPath: IndexPath, in tableView: UITableView) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var content = UIListContentConfiguration.valueCell()
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 0
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .none
        cell.accessibilityTraits = .staticText
        cell.accessibilityValue = nil
        cell.accessibilityLabel = nil
        switch row {
        case .status(let line):
            content = .cell()
            content.text = line
            content.textProperties.numberOfLines = 0
            cell.accessibilityTraits = [.staticText, .updatesFrequently]
            cell.accessibilityIdentifier = "flaccyServer.status"
        case .lastSynced(let line):
            content = .cell()
            content.text = line
            content.textProperties.color = .secondaryLabel
            content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
            cell.accessibilityIdentifier = "flaccyServer.lastSynced"
        case .songs(let songs):
            content.text = String(localized: "Songs")
            content.secondaryText = songs
            cell.accessibilityIdentifier = "flaccyServer.songs"
        case .libraryToggle(let title, let isOn):
            content = .cell()
            content.text = title
            content.textProperties.numberOfLines = 0
            cell.accessoryView = makeSwitch(isOn: isOn, label: title, identifier: "flaccyServer.library") { [weak self] on in
                self?.libraryChanged(on)
            }
            cell.accessibilityIdentifier = "flaccyServer.libraryRow"
        case .syncToggle(let title, let isOn):
            content = .cell()
            content.text = title
            cell.accessoryView = makeSwitch(isOn: isOn, label: title, identifier: "flaccyServer.sync") { [weak self] on in
                self?.syncChanged(on)
            }
            cell.accessibilityIdentifier = "flaccyServer.syncRow"
        case .proSync(let title):
            content = .cell()
            content.text = title
            content.textProperties.numberOfLines = 0
            content.textProperties.color = .tintColor
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            cell.accessibilityTraits = .button
            cell.accessibilityHint = String(localized: "Opens Flaccy Pro")
            cell.accessibilityIdentifier = "flaccyServer.proSync"
        case .devicesLoading:
            content = .cell()
            content.text = String(localized: "Loading devices\u{2026}")
            content.textProperties.color = .secondaryLabel
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessoryView = spinner
        case .devicesFailed(let message):
            content = .cell()
            content.text = message
            content.textProperties.numberOfLines = 0
            content.textProperties.color = .secondaryLabel
            cell.accessibilityIdentifier = "flaccyServer.devicesFailed"
        case .device(let device):
            content = .subtitleCell()
            content.text = device.name
            content.secondaryText = device.isCurrent ? model.thisDeviceLabel : device.lastSeen
            content.secondaryTextProperties.color = .secondaryLabel
            if device.isCurrent {
                cell.selectionStyle = .default
                cell.accessoryView = Self.pencil()
                cell.accessibilityTraits = .button
                cell.accessibilityHint = String(localized: "Renames this device")
            }
            cell.accessibilityIdentifier = "flaccyServer.device"
        case .disconnect(let title):
            content = .cell()
            content.text = title
            content.textProperties.color = .systemRed
            content.textProperties.alignment = .center
            cell.selectionStyle = .default
            cell.accessibilityTraits = .button
            cell.accessibilityIdentifier = "flaccyServer.disconnect"
        }
        cell.contentConfiguration = content
        return cell
    }

    private static func pencil() -> UIView {
        let image = UIImageView(image: UIImage(systemName: "pencil"))
        image.tintColor = .secondaryLabel
        image.sizeToFit()
        return image
    }

    private func makeSwitch(isOn: Bool, label: String, identifier: String, onChange: @escaping (Bool) -> Void) -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.accessibilityLabel = label
        toggle.accessibilityIdentifier = identifier
        toggle.addAction(UIAction { [weak toggle] _ in
            guard let toggle else { return }
            onChange(toggle.isOn)
        }, for: .valueChanged)
        return toggle
    }

    override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .proSync, .disconnect: true
        case .device(let device)?: device.isCurrent
        default: false
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .proSync: presentPaywall()
        case .disconnect: confirmDisconnect()
        case .device(let device)?: promptRename(device)
        default: break
        }
    }

    override func tableView(
        _ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard case .device(let device)? = dataSource.itemIdentifier(for: indexPath), !device.isCurrent else { return nil }
        let remove = UIContextualAction(style: .destructive, title: String(localized: "Remove")) { [weak self] _, _, done in
            self?.confirmRemove(device)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [remove])
    }

    private func presentPaywall() {
        impact.impactOccurred()
        PaywallViewController.presentSheet(from: self)
    }

    private func refreshDevices() {
        impact.impactOccurred()
        Task { await model.loadDevices() }
    }

    private func libraryChanged(_ shown: Bool) {
        impact.impactOccurred()
        Task {
            do {
                try await model.setLibraryShown(shown)
                notification.notificationOccurred(.success)
            } catch {
                notification.notificationOccurred(.error)
                ToastView.show(RemoteFailure.from(error, host: model.address).errorDescription ?? "", in: view, style: .error)
                applySnapshot(animated: false)
            }
        }
    }

    private func syncChanged(_ on: Bool) {
        impact.impactOccurred()
        Task { await model.setSyncOn(on) }
    }

    private func promptRename(_ device: FlaccyServerDetailViewModel.DeviceRow) {
        impact.impactOccurred()
        let alert = UIAlertController(
            title: String(localized: "Rename This Device"),
            message: String(localized: "This is the name \(model.name) shows for this device."),
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.text = device.name
            field.placeholder = String(localized: "Name")
            field.autocapitalizationType = .words
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Rename"), style: .default) { [weak self, weak alert] _ in
            let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self?.rename(device, to: name)
        })
        present(alert, animated: true)
    }

    private func rename(_ device: FlaccyServerDetailViewModel.DeviceRow, to name: String) {
        guard !name.isEmpty else {
            notification.notificationOccurred(.warning)
            ToastView.show(String(localized: "A device needs a name. Type one and try again."), in: view, style: .error)
            return
        }
        Task {
            do {
                try await model.rename(device: device, to: name)
                notification.notificationOccurred(.success)
            } catch {
                notification.notificationOccurred(.error)
                ToastView.show(FlaccyServerDetailViewModel.devicesFailure(error, server: model.name), in: view, style: .error)
            }
        }
    }

    private func confirmRemove(_ device: FlaccyServerDetailViewModel.DeviceRow) {
        heavy.impactOccurred()
        let alert = UIAlertController(
            title: String(localized: "Remove \u{201C}\(device.name)\u{201D}?"),
            message: String(localized: "It stops syncing with \(model.name) and needs a new code to be added again."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Remove"), style: .destructive) { [weak self] _ in
            self?.remove(device)
        })
        present(alert, animated: true)
    }

    private func remove(_ device: FlaccyServerDetailViewModel.DeviceRow) {
        Task {
            do {
                try await model.remove(device: device)
                notification.notificationOccurred(.success)
            } catch {
                notification.notificationOccurred(.error)
                ToastView.show(FlaccyServerDetailViewModel.devicesFailure(error, server: model.name), in: view, style: .error)
            }
        }
    }

    private func confirmDisconnect() {
        heavy.impactOccurred()
        let alert = UIAlertController(title: model.disconnectTitle, message: model.disconnectMessage, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Disconnect"), style: .destructive) { [weak self] _ in
            self?.disconnect()
        })
        present(alert, animated: true)
    }

    private func disconnect() {
        Task {
            do {
                try await model.disconnect()
                ServerSyncLifecycle.shared.disconnected()
                notification.notificationOccurred(.success)
                navigationController?.popViewController(animated: true)
            } catch {
                notification.notificationOccurred(.error)
                ToastView.show(
                    String(localized: "Couldn't disconnect from \(model.name). Try again in a moment."), in: view, style: .error
                )
            }
        }
    }
}
