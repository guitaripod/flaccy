import FlaccyCore
import UIKit

/// The sheet for arranging Home: which sections show, and in what order.
/// Nothing is saved until Done; Cancel, or swiping the sheet away, discards.
final class EditHomeViewController: UIViewController {

    private let store: HomeLayoutStore
    private var working: HomeLayout
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let restoreButton = UIButton(type: .system)
    private let impact = UIImpactFeedbackGenerator(style: .light)

    init(store: HomeLayoutStore = .shared) {
        self.store = store
        self.working = store.layout
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        let bar = makeBar()
        configureTable()
        view.addSubview(bar)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            tableView.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sizeHeaderAndFooter()
    }

    private func makeBar() -> UIView {
        let cancel = circleButton(symbol: "xmark", label: HomeCopy.cancel, tinted: false) { [weak self] in
            self?.dismiss(animated: true)
        }
        let done = circleButton(symbol: "checkmark", label: HomeCopy.done, tinted: true) { [weak self] in
            self?.commit()
        }
        let title = UILabel()
        title.text = HomeCopy.editHome
        title.font = .scaled(.headline, size: 17, weight: .semibold, maxSize: 24)
        title.adjustsFontForContentSizeCategory = true
        title.textAlignment = .center
        title.accessibilityTraits = .header
        let bar = UIStackView(arrangedSubviews: [cancel, title, done])
        bar.axis = .horizontal
        bar.alignment = .center
        bar.translatesAutoresizingMaskIntoConstraints = false
        return bar
    }

    private func circleButton(symbol: String, label: String, tinted: Bool, action: @escaping () -> Void) -> UIButton {
        var configuration = tinted ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
        configuration.image = UIImage(systemName: symbol)
        configuration.cornerStyle = .capsule
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = label
        button.addAction(UIAction { [weak self] _ in
            self?.impact.impactOccurred()
            action()
        }, for: .touchUpInside)
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }

    private func configureTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.isEditing = true
        tableView.allowsSelection = false
        tableView.backgroundColor = .clear
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellID)
        tableView.tableHeaderView = makeIntro()
        tableView.tableFooterView = makeFooter()
    }

    private static let cellID = "EditHomeRow"

    private func makeIntro() -> UIView {
        let label = UILabel()
        label.text = HomeCopy.editIntro
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return padded(label, insets: UIEdgeInsets(top: 4, left: 36, bottom: 4, right: 36))
    }

    private func makeFooter() -> UIView {
        let label = UILabel()
        label.text = HomeCopy.editFooter
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 0

        var configuration = UIButton.Configuration.plain()
        configuration.title = HomeCopy.restoreDefault
        configuration.contentInsets = .zero
        restoreButton.configuration = configuration
        restoreButton.contentHorizontalAlignment = .leading
        restoreButton.addAction(UIAction { [weak self] _ in self?.restoreDefault() }, for: .touchUpInside)
        updateRestoreButton()

        let stack = UIStackView(arrangedSubviews: [label, restoreButton])
        stack.axis = .vertical
        stack.spacing = 12
        return padded(stack, insets: UIEdgeInsets(top: 8, left: 36, bottom: 24, right: 36))
    }

    private func padded(_ content: UIView, insets: UIEdgeInsets) -> UIView {
        let holder = UIView()
        content.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: holder.topAnchor, constant: insets.top),
            content.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -insets.right),
            content.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -insets.bottom),
        ])
        return holder
    }

    private func sizeHeaderAndFooter() {
        for view in [tableView.tableHeaderView, tableView.tableFooterView].compactMap({ $0 }) {
            let fitted = view.systemLayoutSizeFitting(
                CGSize(width: tableView.bounds.width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
            )
            guard view.frame.height != fitted.height || view.frame.width != tableView.bounds.width else { continue }
            view.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: fitted.height)
            if view === tableView.tableHeaderView {
                tableView.tableHeaderView = view
            } else {
                tableView.tableFooterView = view
            }
        }
    }

    private func updateRestoreButton() {
        restoreButton.isEnabled = !working.isStandard
    }

    private func commit() {
        store.layout = working
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss(animated: true)
    }

    private func restoreDefault() {
        working = .standard
        tableView.reloadData()
        updateRestoreButton()
    }

    private func toggled(_ section: HomeSection, on: Bool) {
        UISelectionFeedbackGenerator().selectionChanged()
        working = working.setting(section, visible: on)
        updateRestoreButton()
    }

    private static func icon(for section: HomeSection) -> UIImage {
        let (symbol, color): (String, UIColor) = switch section {
        case .resume: ("play.fill", .systemBlue)
        case .jumpBackIn: ("clock.fill", .systemOrange)
        case .madeForYou: ("square.grid.2x2.fill", .systemPink)
        case .recentlyAdded: ("plus", .systemGreen)
        case .onThisDay: ("calendar", .systemRed)
        case .thisWeek: ("chart.bar.fill", .systemPurple)
        }
        let side: CGFloat = 30
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { _ in
            color.setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side), cornerRadius: 7).fill()
            let glyph = UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            )?.withTintColor(.white, renderingMode: .alwaysOriginal)
            if let glyph {
                glyph.draw(at: CGPoint(x: (side - glyph.size.width) / 2, y: (side - glyph.size.height) / 2))
            }
        }
    }
}

extension EditHomeViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        working.order.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellID, for: indexPath)
        let section = working.order[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.image = Self.icon(for: section)
        content.imageProperties.maximumSize = CGSize(width: 30, height: 30)
        content.imageToTextPadding = 14
        content.text = HomeCopy.title(for: section)
        content.textProperties.font = .scaled(.body, size: 17, weight: .semibold)
        content.secondaryText = HomeCopy.editSubtitle(for: section)
        content.secondaryTextProperties.font = .scaled(.footnote, size: 13, weight: .regular)
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content

        let toggle = UISwitch()
        toggle.isOn = working.isVisible(section)
        toggle.accessibilityLabel = "\(HomeCopy.visibleOnHome): \(HomeCopy.title(for: section))"
        toggle.addAction(UIAction { [weak self, weak toggle] _ in
            self?.toggled(section, on: toggle?.isOn ?? true)
        }, for: .valueChanged)
        cell.editingAccessoryView = toggle
        cell.accessoryView = toggle
        cell.showsReorderControl = true
        return cell
    }

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { true }

    func tableView(_ tableView: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
        working = working.moving(from: source.row, to: destination.row)
        UISelectionFeedbackGenerator().selectionChanged()
        updateRestoreButton()
    }

    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        .none
    }

    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool { false }
}
