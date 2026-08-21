import FlaccyCore
import UIKit

/// What Flaccy found, what it is still looking for, and what it gave up on.
///
/// The one screen in the app that talks about enrichment on demand rather than
/// ambiently: three counts, a Try Again, and a named row for every album and
/// artist that burned its attempts. It repaints from the same notification the
/// ambient line listens to, so a pass running underneath the reader counts down
/// in front of them.
final class EnrichmentReportViewController: UITableViewController {

    private typealias Section = EnrichmentReportViewModel.Section
    private typealias Row = EnrichmentReportViewModel.Row

    private final class DataSource: UITableViewDiffableDataSource<Section, Row> {
        var footerForSection: ((Section) -> String?)?

        override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
            guard let section = sectionIdentifier(for: section) else { return nil }
            return footerForSection?(section)
        }
    }

    private static let summaryReuseIdentifier = "EnrichmentSummaryCell"
    private static let entityReuseIdentifier = "EnrichmentEntityCell"

    private let viewModel = EnrichmentReportViewModel()
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let notificationFeedback = UINotificationFeedbackGenerator()
    private var dataSource: DataSource!
    private var wasRetrying = false

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Metadata")
        navigationItem.largeTitleDisplayMode = .never
        tableView.accessibilityIdentifier = "enrichmentReport.table"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.summaryReuseIdentifier)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.entityReuseIdentifier)
        view.backgroundColor = .systemGroupedBackground

        configureDataSource()
        viewModel.onChange = { [weak self] in
            self?.reportDidChange()
        }
        applySnapshot(animated: false)
        viewModel.start()
    }

    private func configureDataSource() {
        dataSource = DataSource(tableView: tableView) { [weak self] tableView, indexPath, row in
            self?.cell(for: row, at: indexPath, in: tableView) ?? UITableViewCell()
        }
        dataSource.footerForSection = { [weak self] section in
            self?.viewModel.footer(for: section)
        }
        dataSource.defaultRowAnimation = .fade
    }

    /// One `.success` when a requeue lands, and nothing at all while the job
    /// counts down underneath — background work does not get to buzz somebody's
    /// pocket on a timer.
    private func reportDidChange() {
        if wasRetrying, !viewModel.isRetrying {
            notificationFeedback.notificationOccurred(.success)
        }
        wasRetrying = viewModel.isRetrying
        applySnapshot(animated: true)
    }

    private func applySnapshot(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        for section in viewModel.sections {
            snapshot.appendSections([section])
            snapshot.appendItems(viewModel.rows(in: section), toSection: section)
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers(inSection: .retry))
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    private func cell(for row: Row, at indexPath: IndexPath, in tableView: UITableView) -> UITableViewCell {
        switch row {
        case .summary(let text): return summaryCell(text: text, at: indexPath, in: tableView)
        case .tryAgain(let isRetrying): return tryAgainCell(isRetrying: isRetrying, at: indexPath, in: tableView)
        case .entity(let entity): return entityCell(entity, at: indexPath, in: tableView)
        }
    }

    private func summaryCell(text: String, at indexPath: IndexPath, in tableView: UITableView) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.summaryReuseIdentifier, for: indexPath)
        var content = UIListContentConfiguration.cell()
        content.text = text
        content.textProperties.font = UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.textProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.accessoryView = nil
        cell.selectionStyle = .none
        cell.accessibilityTraits = [.staticText, .updatesFrequently]
        cell.accessibilityLabel = text
        return cell
    }

    private func tryAgainCell(isRetrying: Bool, at indexPath: IndexPath, in tableView: UITableView) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.summaryReuseIdentifier, for: indexPath)
        var content = UIListContentConfiguration.cell()
        content.text = EnrichmentJobCopy.tryAgain
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.textProperties.color = viewModel.canRetry ? .tintColor : .tertiaryLabel
        cell.contentConfiguration = content
        cell.accessoryView = isRetrying ? makeSpinnerAccessory() : nil
        cell.selectionStyle = viewModel.canRetry ? .default : .none
        cell.accessibilityTraits = viewModel.canRetry ? .button : [.button, .notEnabled]
        cell.accessibilityLabel = EnrichmentJobCopy.tryAgain
        cell.accessibilityIdentifier = "enrichmentReport.tryAgain"
        return cell
    }

    private func entityCell(
        _ entity: EnrichmentReportEntity, at indexPath: IndexPath, in tableView: UITableView
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.entityReuseIdentifier, for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        content.text = entity.name
        content.secondaryText = entity.detail
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.textProperties.numberOfLines = 2
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
        content.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.color = .secondaryLabel
        content.image = UIImage(
            systemName: entity.scope == .artist ? "person.crop.circle" : "square.stack",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        )
        content.imageProperties.tintColor = .tertiaryLabel
        cell.contentConfiguration = content
        cell.accessoryView = nil
        cell.selectionStyle = .none
        cell.accessibilityTraits = .staticText
        cell.accessibilityLabel = entity.name
        cell.accessibilityValue = entity.detail
        return cell
    }

    private func makeSpinnerAccessory() -> UIActivityIndicatorView {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        return spinner
    }

    override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard case .tryAgain = dataSource.itemIdentifier(for: indexPath) else { return false }
        return viewModel.canRetry
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case .tryAgain = dataSource.itemIdentifier(for: indexPath), viewModel.canRetry else { return }
        impactLight.impactOccurred()
        notificationFeedback.prepare()
        wasRetrying = true
        viewModel.retry()
        AppLogger.info("Metadata report: retrying exhausted entities", category: .content)
    }
}
