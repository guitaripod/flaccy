import FlaccyCore
import MidgarCore
import UIKit

/// The Add Flaccy Server sheet of docs/server/UX.md section 3: scan the code the server printed, or type its address and the
/// code, then Connect. A link only fills the fields in; nothing connects without a tap.
final class AddFlaccyServerViewController: UITableViewController {

    nonisolated enum Section: Int, Hashable {
        case scan
        case fields
        case status
        case actions
    }

    nonisolated enum Row: Hashable {
        case scan
        case address
        case code
        case status
        case connect
        case done
        case failureButton(Int)
    }

    private let model: AddFlaccyServerViewModel
    private lazy var dataSource = DataSource(tableView: tableView) { [weak self] tableView, indexPath, row in
        self?.cell(for: row, at: indexPath, in: tableView) ?? UITableViewCell()
    }
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let notification = UINotificationFeedbackGenerator()
    private weak var codeCell: FormFieldCell?
    private var announcedState: AddFlaccyServerViewModel.State = .idle

    init(model: AddFlaccyServerViewModel = AddFlaccyServerViewModel(), link: FlaccyServerLink? = nil) {
        self.model = model
        super.init(style: .insetGrouped)
        if let link { model.apply(link: link) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func present(from host: UIViewController, link: FlaccyServerLink? = nil) {
        let controller = AddFlaccyServerViewController(link: link)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .pageSheet
        host.present(navigation, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Add Flaccy Server")
        tableView.accessibilityIdentifier = "addFlaccyServer.table"
        tableView.keyboardDismissMode = .interactive
        tableView.register(FormFieldCell.self, forCellReuseIdentifier: FormFieldCell.reuseID)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ActionCell")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.cancelTapped() }
        )
        model.onChange = { [weak self] in self?.modelChanged() }
        applySnapshot(animated: false)
    }

    #if DEBUG
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if FlaccyServerShot.drivesConnect, model.canConnect, case .idle = model.state { connectTapped() }
    }
    #endif

    private final class DataSource: UITableViewDiffableDataSource<Section, Row> {
        override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
            sectionIdentifier(for: section) == .fields ? String(localized: "Type it instead") : nil
        }
    }

    private func applySnapshot(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        switch model.state {
        case .idle:
            snapshot.appendSections([.scan, .fields, .actions])
            snapshot.appendItems([.scan], toSection: .scan)
            snapshot.appendItems([.address, .code], toSection: .fields)
            snapshot.appendItems([.connect], toSection: .actions)
        case .checking:
            snapshot.appendSections([.scan, .fields, .status, .actions])
            snapshot.appendItems([.scan], toSection: .scan)
            snapshot.appendItems([.address, .code], toSection: .fields)
            snapshot.appendItems([.status], toSection: .status)
            snapshot.appendItems([.connect], toSection: .actions)
        case .connected:
            snapshot.appendSections([.status, .actions])
            snapshot.appendItems([.status], toSection: .status)
            snapshot.appendItems([.done], toSection: .actions)
        case .failed(let copy):
            snapshot.appendSections([.scan, .fields, .status, .actions])
            snapshot.appendItems([.scan], toSection: .scan)
            snapshot.appendItems([.address, .code], toSection: .fields)
            snapshot.appendItems([.status], toSection: .status)
            snapshot.appendItems(copy.buttons.indices.map(Row.failureButton), toSection: .actions)
        }
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    private func modelChanged() {
        guard isViewLoaded else { return }
        let state = model.state
        if state != announcedState {
            announcedState = state
            applySnapshot(animated: true)
            navigationItem.leftBarButtonItem?.isHidden = model.isConnected
            reactToNew(state)
        }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { $0 == .connect || $0 == .status })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func reactToNew(_ state: AddFlaccyServerViewModel.State) {
        switch state {
        case .connected(let info):
            #if DEBUG
            FlaccyServerShot.noteConnected(serverName: info.serverName)
            #endif
            notification.notificationOccurred(.success)
            UIAccessibility.post(notification: .announcement, argument: Self.connectedTitle(info.serverName))
        case .failed(let copy):
            notification.notificationOccurred(.error)
            UIAccessibility.post(notification: .announcement, argument: "\(copy.title). \(copy.body)")
        case .checking(let server):
            UIAccessibility.post(notification: .announcement, argument: Self.checkingTitle(server))
        case .idle:
            break
        }
    }

    private func cell(for row: Row, at indexPath: IndexPath, in tableView: UITableView) -> UITableViewCell {
        switch row {
        case .address:
            return fieldCell(in: tableView, at: indexPath, title: String(localized: "Address"), value: model.address,
                             placeholder: String(localized: "arch or 100.91.211.44"), identifier: "addFlaccyServer.address") { cell in
                cell.field.keyboardType = .URL
                cell.field.autocapitalizationType = .none
                cell.field.autocorrectionType = .no
                cell.field.textContentType = .URL
            } onChange: { [weak self] in self?.model.address = $0 }
        case .code:
            return fieldCell(in: tableView, at: indexPath, title: String(localized: "Code"), value: model.code,
                             placeholder: String(localized: "ABCD-EFGH-\u{2026}"), identifier: "addFlaccyServer.code") { [weak self] cell in
                cell.field.keyboardType = .asciiCapable
                cell.field.autocapitalizationType = .allCharacters
                cell.field.autocorrectionType = .no
                cell.field.spellCheckingType = .no
                cell.field.returnKeyType = .go
                cell.onReturn = { [weak self] in self?.connectTapped() }
                self?.codeCell = cell
            } onChange: { [weak self] text in
                guard let self else { return }
                self.model.code = text
                if self.codeCell?.field.text != self.model.code { self.codeCell?.field.text = self.model.code }
            }
        case .scan:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ActionCell", for: indexPath)
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "Scan QR Code")
            content.image = UIImage(systemName: "qrcode.viewfinder")
            content.textProperties.color = .tintColor
            cell.contentConfiguration = content
            cell.accessoryView = nil
            cell.accessibilityTraits = .button
            cell.accessibilityIdentifier = "addFlaccyServer.scan"
            return cell
        case .connect:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ActionCell", for: indexPath)
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "Connect")
            content.textProperties.alignment = .center
            content.textProperties.font = .preferredFont(forTextStyle: .headline)
            content.textProperties.color = model.canConnect ? .tintColor : .secondaryLabel
            cell.contentConfiguration = content
            cell.accessoryView = nil
            cell.accessibilityTraits = model.canConnect ? .button : [.button, .notEnabled]
            cell.accessibilityIdentifier = "addFlaccyServer.connect"
            return cell
        case .done:
            return buttonCell(in: tableView, at: indexPath, title: String(localized: "Done"), identifier: "addFlaccyServer.done")
        case .failureButton(let index):
            guard case .failed(let copy) = model.state, copy.buttons.indices.contains(index) else { return UITableViewCell() }
            return buttonCell(
                in: tableView, at: indexPath, title: copy.buttons[index].title, identifier: "addFlaccyServer.failure.\(index)"
            )
        case .status:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ActionCell", for: indexPath)
            configureStatus(cell)
            return cell
        }
    }

    private func buttonCell(in tableView: UITableView, at indexPath: IndexPath, title: String, identifier: String) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ActionCell", for: indexPath)
        var content = UIListContentConfiguration.cell()
        content.text = title
        content.textProperties.alignment = .center
        content.textProperties.color = .tintColor
        content.textProperties.font = .preferredFont(forTextStyle: .headline)
        cell.contentConfiguration = content
        cell.accessoryView = nil
        cell.accessibilityTraits = .button
        cell.accessibilityIdentifier = identifier
        return cell
    }

    private func configureStatus(_ cell: UITableViewCell) {
        var content = UIListContentConfiguration.cell()
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 0
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryTextProperties.color = .secondaryLabel
        cell.accessoryView = nil
        switch model.state {
        case .idle:
            break
        case .checking(let server):
            content.text = Self.checkingTitle(server)
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessoryView = spinner
        case .connected(let info):
            content.text = Self.connectedTitle(info.serverName)
            content.secondaryText = info.libraryAdded ? Self.connectedBody : Self.connectedWithoutMusicBody
            content.image = UIImage(systemName: "checkmark.circle.fill")
            content.imageProperties.tintColor = .systemGreen
        case .failed(let copy):
            content.text = copy.title
            content.secondaryText = copy.body
            content.image = UIImage(systemName: "exclamationmark.triangle.fill")
            content.imageProperties.tintColor = .systemRed
        }
        cell.contentConfiguration = content
        cell.accessibilityTraits = [.staticText, .updatesFrequently]
        cell.accessibilityLabel = [content.text, content.secondaryText].compactMap { $0 }.joined(separator: ". ")
        cell.accessibilityIdentifier = "addFlaccyServer.status"
    }

    private func fieldCell(
        in tableView: UITableView, at indexPath: IndexPath, title: String, value: String, placeholder: String,
        identifier: String, configure: (FormFieldCell) -> Void, onChange: @escaping (String) -> Void
    ) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: FormFieldCell.reuseID, for: indexPath) as? FormFieldCell else {
            return UITableViewCell()
        }
        cell.reset()
        configure(cell)
        cell.show(title: title, value: value, placeholder: placeholder)
        cell.field.accessibilityIdentifier = identifier
        cell.onChange = onChange
        return cell
    }

    override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .scan, .done, .failureButton: true
        case .connect: model.canConnect
        default: false
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .scan: scanTapped()
        case .connect: connectTapped()
        case .done: doneTapped()
        case .failureButton(let index): failureTapped(index)
        default: break
        }
    }

    private func scanTapped() {
        impact.impactOccurred()
        view.endEditing(true)
        let scanner = QRScannerViewController { [weak self] parsed in
            self?.dismiss(animated: true) {
                guard let self else { return }
                switch parsed {
                case .flaccyServer(let link):
                    self.notification.notificationOccurred(.success)
                    self.model.apply(link: link)
                    self.applySnapshot(animated: false)
                case .subsonic(let link):
                    self.openRegularServerSheet(link: link, address: nil)
                }
            }
        }
        present(UINavigationController(rootViewController: scanner), animated: true)
    }

    private func connectTapped() {
        guard model.canConnect else { return }
        impact.impactOccurred()
        view.endEditing(true)
        Task { await model.connect() }
    }

    private func doneTapped() {
        impact.impactOccurred()
        dismiss(animated: true)
    }

    private func cancelTapped() {
        impact.impactOccurred()
        dismiss(animated: true)
    }

    private func failureTapped(_ index: Int) {
        guard case .failed(let copy) = model.state, copy.buttons.indices.contains(index) else { return }
        impact.impactOccurred()
        switch copy.buttons[index].action {
        case .tryAgain:
            retry(after: copy.failure)
        case .openTailscale:
            Self.openTailscale()
        case .addAsRegularServer:
            openRegularServerSheet(link: nil, address: model.address)
        case .openAppStore:
            if let url = Self.appStoreURL { UIApplication.shared.open(url) }
        case .dismiss:
            model.reset()
        case .cancel:
            dismiss(animated: true)
        }
    }

    private func retry(after failure: ServerSetupFailure) {
        if case .codeRefused = failure {
            model.code = ""
            model.reset()
            applySnapshot(animated: false)
            codeCell?.field.text = ""
            codeCell?.field.becomeFirstResponder()
        } else {
            Task { await model.connect() }
        }
    }

    private func openRegularServerSheet(link: ServerLink?, address: String?) {
        guard let presenter = presentingViewController else { return }
        dismiss(animated: true) {
            AddServerViewController.present(from: presenter, servers: RemoteServersViewModel(), link: link, address: address)
        }
    }

    private static func openTailscale() {
        guard let app = URL(string: "tailscale://"), let store = URL(string: "https://apps.apple.com/app/tailscale/id1470499037") else { return }
        UIApplication.shared.open(app) { opened in
            if !opened { UIApplication.shared.open(store) }
        }
    }

    private static var appStoreURL: URL? {
        URL(string: "itms-apps://apps.apple.com/app/id6787493695")
    }

    static func checkingTitle(_ server: String) -> String {
        String(localized: "Connecting to \(server)\u{2026}")
    }

    static func connectedTitle(_ server: String) -> String {
        String(localized: "Connected to \(server).")
    }

    static var connectedBody: String {
        String(localized: "Your playlists, loves and history now sync with this server. Its music is in your library under Servers.")
    }

    static var connectedWithoutMusicBody: String {
        String(localized: "Your playlists, loves and history now sync with this server. Its music will be added to your library the next time you open Flaccy.")
    }
}
