import UIKit

/// One page below the Settings root. It shows the rows `SettingsViewController` builds for its
/// page and hands every tap, swipe and footer back to that controller, which holds the state,
/// so a switch flipped here and the summary on the root never disagree.
final class SettingsPageViewController: UITableViewController {

    let page: SettingsViewController.Page
    private weak var root: SettingsViewController?
    private(set) var dataSource: SettingsViewController.DataSource?

    init(page: SettingsViewController.Page, root: SettingsViewController) {
        self.page = page
        self.root = root
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = page.title
        navigationItem.largeTitleDisplayMode = .never
        tableView.accessibilityIdentifier = page.accessibilityIdentifier
        view.backgroundColor = .systemGroupedBackground
        guard let root else { return }
        SettingsViewController.registerCells(in: tableView)
        dataSource = root.makeDataSource(for: tableView)
        root.pageDidLoad(self)
        apply(animated: false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        root?.pageDidLayout(self)
    }

    func apply(animated: Bool) {
        guard let root, let dataSource else { return }
        dataSource.apply(root.snapshot(for: page), animatingDifferences: animated && view.window != nil)
    }

    override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard let row = dataSource?.itemIdentifier(for: indexPath) else { return false }
        return root?.isSelectable(row) ?? false
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource?.itemIdentifier(for: indexPath) else { return }
        root?.select(row)
    }

    override func tableView(
        _ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let row = dataSource?.itemIdentifier(for: indexPath) else { return nil }
        return root?.swipeActions(for: row)
    }

    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        guard let section = dataSource?.sectionIdentifier(for: section) else { return nil }
        return root?.footerView(for: section)
    }
}
