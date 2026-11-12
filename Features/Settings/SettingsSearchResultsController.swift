import UIKit

/// The search field on the Settings root: it finds any switch or action by its name and opens
/// the page that holds it, or runs it straight away when it lives on the root.
final class SettingsSearchResultsController: UITableViewController, UISearchResultsUpdating {

    /// One searchable setting: its name and icon, and where it leads: the page that holds it, or
    /// the root row to run when it has no page of its own.
    struct Entry {
        enum Target {
            case page(SettingsViewController.Page)
            case row(SettingsViewController.Row)
        }

        let title: String
        let symbolName: String
        let tint: UIColor
        let target: Target

        init(_ title: String, in page: SettingsViewController.Page) {
            self.title = title
            symbolName = page.symbolName
            tint = page.tint
            target = .page(page)
        }

        init(_ title: String, symbolName: String, tint: UIColor, row: SettingsViewController.Row) {
            self.title = title
            self.symbolName = symbolName
            self.tint = tint
            target = .row(row)
        }

        /// The page a match lives on, named under it unless the match is the page itself.
        var location: String? {
            guard case .page(let page) = target, page.title != title else { return nil }
            return page.title
        }
    }

    private static let reuseIdentifier = "SettingsSearchResult"

    private weak var root: SettingsViewController?
    private var results: [Entry] = []

    init(root: SettingsViewController) {
        self.root = root
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.reuseIdentifier)
        tableView.accessibilityIdentifier = "settings.search.results"
        tableView.keyboardDismissMode = .onDrag
    }

    func updateSearchResults(for searchController: UISearchController) {
        let query = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespaces)
        let entries = root?.searchEntries() ?? []
        results = query.isEmpty ? [] : entries.filter {
            $0.title.localizedStandardContains(query) || ($0.location?.localizedStandardContains(query) ?? false)
        }
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        results.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.reuseIdentifier, for: indexPath)
        let entry = results[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.image = SettingsViewController.RowIcon.image(systemName: entry.symbolName, tint: entry.tint)
        content.imageProperties.maximumSize = CGSize(width: SettingsViewController.RowIcon.side, height: SettingsViewController.RowIcon.side)
        content.text = entry.title
        content.secondaryText = entry.location
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityLabel = entry.title
        cell.accessibilityValue = content.secondaryText
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        root?.openSearchResult(results[indexPath.row])
    }
}
