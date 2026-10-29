import FlaccyCore
import MidgarCore
import UIKit

/// The sheet that adds a music server: address, how to sign in, a name, a Test button and Add.
/// A scanned or tapped `flaccy://server` link fills it in with API-key sign-in.
final class AddServerViewController: UITableViewController {

    nonisolated enum Section: Int, Hashable {
        case address
        case signIn
        case name
        case actions
    }

    nonisolated enum Row: Hashable {
        case address
        case scan
        case authKind
        case username
        case password
        case apiKey
        case name
        case test
        case status
    }

    var onAdded: ((RemoteServerRecord) -> Void)?

    private let form = AddServerViewModel()
    private let servers: RemoteServersViewModel
    private var dataSource: UITableViewDiffableDataSource<Section, Row>!
    private let selection = UISelectionFeedbackGenerator()
    private let notification = UINotificationFeedbackGenerator()
    private var addButton: UIBarButtonItem!

    init(servers: RemoteServersViewModel, link: ServerLink? = nil, address: String? = nil) {
        self.servers = servers
        super.init(style: .insetGrouped)
        if let link { form.apply(link: link) }
        if let address {
            form.address = address
            form.suggestName()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func present(from host: UIViewController, servers: RemoteServersViewModel, link: ServerLink? = nil, address: String? = nil) {
        let controller = AddServerViewController(servers: servers, link: link, address: address)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .pageSheet
        host.present(navigation, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Add Server")
        tableView.accessibilityIdentifier = "addServer.table"
        tableView.keyboardDismissMode = .interactive
        tableView.register(FormFieldCell.self, forCellReuseIdentifier: FormFieldCell.reuseID)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ActionCell")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "SegmentCell")

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        addButton = UIBarButtonItem(
            title: String(localized: "Add"), image: nil, primaryAction: UIAction { [weak self] _ in self?.addTapped() }
        )
        addButton.style = .done
        addButton.accessibilityIdentifier = "addServer.add"
        navigationItem.rightBarButtonItem = addButton

        dataSource = UITableViewDiffableDataSource(tableView: tableView) { [weak self] tableView, indexPath, row in
            self?.cell(for: row, at: indexPath, in: tableView) ?? UITableViewCell()
        }
        form.onChange = { [weak self] in self?.formChanged() }
        applySnapshot(animated: false)
    }

    private var signInRows: [Row] {
        form.kind == .password ? [.authKind, .username, .password] : [.authKind, .apiKey]
    }

    private func applySnapshot(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections([.address, .signIn, .name, .actions])
        snapshot.appendItems([.address, .scan], toSection: .address)
        snapshot.appendItems(signInRows, toSection: .signIn)
        snapshot.appendItems([.name], toSection: .name)
        snapshot.appendItems([.test, .status], toSection: .actions)
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    private func formChanged() {
        guard isViewLoaded else { return }
        let current = dataSource.snapshot().itemIdentifiers(inSection: .signIn)
        if current != signInRows {
            applySnapshot(animated: true)
        }
        var snapshot = dataSource.snapshot()
        let status = snapshot.itemIdentifiers.filter { $0 == .status || $0 == .test }
        snapshot.reconfigureItems(status)
        if let nameRow = snapshot.itemIdentifiers.first(where: { $0 == .name }), !isEditing(.name) {
            snapshot.reconfigureItems([nameRow])
        }
        for row in [Row.address, .username, .password, .apiKey] where snapshot.itemIdentifiers.contains(row) && !isEditing(row) {
            snapshot.reconfigureItems([row])
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        addButton.isEnabled = !form.isAdding
    }

    private func isEditing(_ row: Row) -> Bool {
        guard let indexPath = dataSource.indexPath(for: row),
              let cell = tableView.cellForRow(at: indexPath) as? FormFieldCell else { return false }
        return cell.isEditingField
    }

    private func cell(for row: Row, at indexPath: IndexPath, in tableView: UITableView) -> UITableViewCell {
        switch row {
        case .address:
            return fieldCell(in: tableView, at: indexPath, title: String(localized: "Address"), value: form.address,
                             placeholder: String(localized: "music.example.com or http://192.168.1.20:4533"), identifier: "addServer.address") { cell in
                cell.field.keyboardType = .URL
                cell.field.autocapitalizationType = .none
                cell.field.autocorrectionType = .no
                cell.field.textContentType = .URL
            } onChange: { [weak self] text in
                self?.form.address = text
            } onEnd: { [weak self] in
                self?.form.suggestName()
            }
        case .username:
            return fieldCell(in: tableView, at: indexPath, title: String(localized: "Username"), value: form.username,
                             placeholder: String(localized: "Required"), identifier: "addServer.username") { cell in
                cell.field.autocapitalizationType = .none
                cell.field.autocorrectionType = .no
                cell.field.textContentType = .username
            } onChange: { [weak self] in self?.form.username = $0 }
        case .password:
            return fieldCell(in: tableView, at: indexPath, title: String(localized: "Password"), value: form.password,
                             placeholder: String(localized: "Required"), identifier: "addServer.password") { cell in
                cell.field.isSecureTextEntry = true
                cell.field.autocapitalizationType = .none
                cell.field.textContentType = .password
            } onChange: { [weak self] in self?.form.password = $0 }
        case .apiKey:
            return fieldCell(in: tableView, at: indexPath, title: String(localized: "API Key"), value: form.apiKey,
                             placeholder: String(localized: "Required"), identifier: "addServer.apiKey") { cell in
                cell.field.isSecureTextEntry = true
                cell.field.autocapitalizationType = .none
                cell.field.autocorrectionType = .no
            } onChange: { [weak self] in self?.form.apiKey = $0 }
        case .name:
            return fieldCell(in: tableView, at: indexPath, title: String(localized: "Name"), value: form.name,
                             placeholder: String(localized: "Home Server"), identifier: "addServer.name") { cell in
                cell.field.autocapitalizationType = .words
            } onChange: { [weak self] in self?.form.name = $0 }
        case .authKind:
            return segmentCell(in: tableView, at: indexPath)
        case .scan:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ActionCell", for: indexPath)
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "Scan QR Code")
            content.image = UIImage(systemName: "qrcode.viewfinder")
            content.textProperties.color = .tintColor
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "addServer.scan"
            return cell
        case .test:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ActionCell", for: indexPath)
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "Test")
            content.image = UIImage(systemName: "bolt.horizontal.circle")
            content.textProperties.color = form.testState == .testing ? .secondaryLabel : .tintColor
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "addServer.test"
            return cell
        case .status:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ActionCell", for: indexPath)
            cell.contentConfiguration = statusContent()
            cell.accessibilityIdentifier = "addServer.status"
            cell.accessibilityTraits = .staticText
            return cell
        }
    }

    private func statusContent() -> UIListContentConfiguration {
        var content = UIListContentConfiguration.cell()
        content.textProperties.numberOfLines = 0
        content.textProperties.font = .preferredFont(forTextStyle: .footnote)
        switch form.testState {
        case .idle:
            content.text = RemoteCopy.explainer
            content.textProperties.color = .secondaryLabel
        case .testing:
            content.text = String(localized: "Testing the connection\u{2026}")
            content.textProperties.color = .secondaryLabel
        case .passed(let summary):
            content.text = summary
            content.image = UIImage(systemName: "checkmark.circle.fill")
            content.imageProperties.tintColor = .systemGreen
            content.textProperties.color = .label
        case .failed(let message):
            content.text = message
            content.image = UIImage(systemName: "exclamationmark.triangle.fill")
            content.imageProperties.tintColor = .systemRed
            content.textProperties.color = .label
        }
        return content
    }

    private func fieldCell(
        in tableView: UITableView, at indexPath: IndexPath, title: String, value: String, placeholder: String,
        identifier: String, configure: (FormFieldCell) -> Void, onChange: @escaping (String) -> Void,
        onEnd: (() -> Void)? = nil
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: FormFieldCell.reuseID, for: indexPath) as! FormFieldCell
        cell.reset()
        configure(cell)
        cell.show(title: title, value: value, placeholder: placeholder)
        cell.field.accessibilityIdentifier = identifier
        cell.onChange = onChange
        cell.onEnd = onEnd
        return cell
    }

    private func segmentCell(in tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SegmentCell", for: indexPath)
        cell.selectionStyle = .none
        cell.contentView.subviews.forEach { $0.removeFromSuperview() }
        let segmented = UISegmentedControl(items: AddServerViewModel.Kind.allCases.map(\.title))
        segmented.selectedSegmentIndex = form.kind.rawValue
        segmented.accessibilityIdentifier = "addServer.kind"
        segmented.addAction(UIAction { [weak self, weak segmented] _ in
            guard let self, let segmented, let kind = AddServerViewModel.Kind(rawValue: segmented.selectedSegmentIndex) else { return }
            self.selection.selectionChanged()
            self.form.kind = kind
        }, for: .valueChanged)
        segmented.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(segmented)
        NSLayoutConstraint.activate([
            segmented.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            segmented.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            segmented.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
            segmented.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
        ])
        return cell
    }

    override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .scan: true
        case .test: form.testState != .testing
        default: false
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .scan: scanTapped()
        case .test: testTapped()
        default: break
        }
    }

    private func scanTapped() {
        selection.selectionChanged()
        view.endEditing(true)
        let scanner = QRScannerViewController { [weak self] parsed in
            self?.dismiss(animated: true) {
                guard let self else { return }
                switch parsed {
                case .subsonic(let link):
                    self.form.apply(link: link)
                    self.notification.notificationOccurred(.success)
                    self.applySnapshot(animated: false)
                    self.formChanged()
                case .flaccyServer(let link):
                    self.openFlaccyServerSheet(for: link)
                }
            }
        }
        present(UINavigationController(rootViewController: scanner), animated: true)
    }

    private func openFlaccyServerSheet(for link: FlaccyServerLink) {
        notification.notificationOccurred(.success)
        guard let presenter = presentingViewController else { return }
        dismiss(animated: true) {
            AddFlaccyServerViewController.present(from: presenter, link: link)
        }
    }

    #if DEBUG
    func fillForCapture(address: String, username: String, password: String) async {
        form.address = address
        form.suggestName()
        form.username = username
        form.password = password
        applySnapshot(animated: false)
        formChanged()
        await form.test(using: servers)
    }
    #endif

    private func testTapped() {
        selection.selectionChanged()
        view.endEditing(true)
        Task {
            await form.test(using: servers)
            switch form.testState {
            case .passed: notification.notificationOccurred(.success)
            case .failed: notification.notificationOccurred(.error)
            default: break
            }
        }
    }

    private func addTapped() {
        view.endEditing(true)
        selection.selectionChanged()
        Task {
            if let record = await form.add(using: servers) {
                notification.notificationOccurred(.success)
                onAdded?(record)
                dismiss(animated: true)
            } else {
                notification.notificationOccurred(.error)
            }
        }
    }
}

/// A form row with a caption and a text field beside it.
final class FormFieldCell: UITableViewCell, UITextFieldDelegate {

    static let reuseID = "FormFieldCell"

    let field = UITextField()
    var onChange: ((String) -> Void)?
    var onEnd: (() -> Void)?
    var onReturn: (() -> Void)?

    private let captionLabel = UILabel()

    var isEditingField: Bool { field.isFirstResponder }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        captionLabel.font = .preferredFont(forTextStyle: .body)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.setContentHuggingPriority(.required, for: .horizontal)
        captionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.textAlignment = .right
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .next
        field.delegate = self
        field.addAction(UIAction { [weak self] _ in self?.onChange?(self?.field.text ?? "") }, for: .editingChanged)
        field.addAction(UIAction { [weak self] _ in self?.onEnd?() }, for: .editingDidEnd)

        let row = UIStackView(arrangedSubviews: [captionLabel, field])
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            captionLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func reset() {
        field.isSecureTextEntry = false
        field.keyboardType = .default
        field.autocapitalizationType = .sentences
        field.autocorrectionType = .default
        field.textContentType = nil
        field.returnKeyType = .next
        onReturn = nil
    }

    func show(title: String, value: String, placeholder: String) {
        captionLabel.text = title
        if !field.isFirstResponder { field.text = value }
        field.placeholder = placeholder
        field.accessibilityLabel = title
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        onReturn?()
        return true
    }
}
