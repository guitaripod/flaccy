import UIKit
import UserNotifications

/// Dedicated configurator for Recap notifications: cadence, delivery day and
/// time, a live preview of the exact notification, the next scheduled delivery,
/// and a test send so the user can feel the result immediately.
final class RecapNotificationsViewController: UITableViewController {

    nonisolated private enum Section: Int, CaseIterable, Hashable {
        case permission
        case frequency
        case schedule
        case preview
        case test

        var header: String? {
            switch self {
            case .permission: return nil
            case .frequency: return "Frequency"
            case .schedule: return "Delivery"
            case .preview: return "Preview"
            case .test: return nil
            }
        }
    }

    nonisolated private enum Row: Hashable {
        case permissionDenied
        case frequency(RecapNotificationFrequency, selected: Bool)
        case deliveryTime
        case weekday(name: String)
        case monthDay(day: Int)
        case nextDelivery(text: String)
        case preview(title: String, body: String)
        case sendTest
    }

    private final class DataSource: UITableViewDiffableDataSource<Section, Row> {
        override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
            sectionIdentifier(for: section)?.header
        }

        override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
            switch sectionIdentifier(for: section) {
            case .frequency:
                return "Reminders are generated on this device from your local play history."
            case .test:
                return "Your Year in Music special edition always arrives on December 1. The test notification lands in a few seconds — lock the screen or swipe to Home to see the full card."
            default:
                return nil
            }
        }
    }

    private static let cellReuseIdentifier = "RecapNotificationsCell"

    private let scheduler = RecapNotificationScheduler.shared
    private var dataSource: DataSource!
    private var authorizationDenied = false

    private let selectionFeedback = UISelectionFeedbackGenerator()
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let notificationFeedback = UINotificationFeedbackGenerator()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Recap Notifications"
        tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellReuseIdentifier)
        view.backgroundColor = .systemGroupedBackground
        configureDataSource()
        applySnapshot(animated: false)
        refreshAuthorization()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshAuthorization),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
    }

    @objc private func refreshAuthorization() {
        Task {
            let status = await scheduler.authorizationStatus()
            let denied = status == .denied && scheduler.frequency != .off
            if denied != authorizationDenied {
                authorizationDenied = denied
                applySnapshot(animated: true)
            }
        }
    }

    private func configureDataSource() {
        dataSource = DataSource(tableView: tableView) {
            [weak self] tableView, indexPath, row in
            self?.cell(for: row, at: indexPath, in: tableView) ?? UITableViewCell()
        }
        dataSource.defaultRowAnimation = .fade
    }

    private func applySnapshot(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        let frequency = scheduler.frequency

        if authorizationDenied {
            snapshot.appendSections([.permission])
            snapshot.appendItems([.permissionDenied], toSection: .permission)
        }

        snapshot.appendSections([.frequency])
        snapshot.appendItems(
            RecapNotificationFrequency.allCases.map { .frequency($0, selected: $0 == frequency) },
            toSection: .frequency
        )

        if frequency != .off {
            snapshot.appendSections([.schedule])
            var scheduleRows: [Row] = [.deliveryTime]
            switch frequency {
            case .weekly:
                let symbols = Calendar.current.weekdaySymbols
                scheduleRows.append(.weekday(name: symbols[scheduler.weeklyWeekday - 1]))
            case .monthly:
                scheduleRows.append(.monthDay(day: scheduler.monthlyDay))
            case .off:
                break
            }
            scheduleRows.append(.nextDelivery(text: nextDeliveryText()))
            snapshot.appendItems(scheduleRows, toSection: .schedule)

            snapshot.appendSections([.preview])
            let preview = scheduler.previewContent()
            snapshot.appendItems([.preview(title: preview.title, body: preview.body)], toSection: .preview)
        }

        snapshot.appendSections([.test])
        snapshot.appendItems([.sendTest], toSection: .test)
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    private func nextDeliveryText() -> String {
        guard let date = scheduler.nextDeliveryDate() else { return "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }

    private func cell(for row: Row, at indexPath: IndexPath, in tableView: UITableView) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellReuseIdentifier, for: indexPath)
        cell.accessoryType = .none
        cell.accessoryView = nil
        cell.selectionStyle = .default
        cell.accessibilityTraits = .button

        var content = UIListContentConfiguration.valueCell()
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .body)
        content.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.color = .secondaryLabel

        switch row {
        case .permissionDenied:
            content.text = "Notifications Are Off"
            content.secondaryText = "Open Settings"
            content.textProperties.color = .systemRed
            content.image = UIImage(systemName: "bell.slash.fill")?.withTintColor(.systemRed, renderingMode: .alwaysOriginal)
            cell.accessibilityLabel = "Notifications are off"
            cell.accessibilityHint = "Opens system Settings to allow notifications"

        case .frequency(let frequency, let selected):
            content.text = frequency.displayName
            cell.accessoryType = selected ? .checkmark : .none
            cell.accessibilityLabel = frequency.displayName
            cell.accessibilityTraits = selected ? [.button, .selected] : .button

        case .deliveryTime:
            content.text = "Time"
            cell.selectionStyle = .none
            cell.accessoryView = makeTimePicker()
            cell.accessibilityTraits = []

        case .weekday(let name):
            content.text = "Day of Week"
            cell.selectionStyle = .none
            cell.accessoryView = makeWeekdayButton(currentName: name)
            cell.accessibilityTraits = []

        case .monthDay(let day):
            content.text = "Day of Month"
            cell.selectionStyle = .none
            cell.accessoryView = makeMonthDayButton(currentDay: day)
            cell.accessibilityTraits = []

        case .nextDelivery(let text):
            content.text = "Next Delivery"
            content.secondaryText = text
            cell.selectionStyle = .none
            cell.accessibilityTraits = .staticText
            cell.accessibilityLabel = "Next delivery"
            cell.accessibilityValue = text

        case .preview(let title, let body):
            cell.selectionStyle = .none
            cell.accessibilityTraits = .staticText
            cell.contentConfiguration = previewConfiguration(title: title, body: body)
            return cell

        case .sendTest:
            content = .cell()
            content.text = "Send Test Notification"
            content.textProperties.color = .tintColor
            content.textProperties.alignment = .center
            cell.accessibilityLabel = "Send Test Notification"
            cell.accessibilityHint = "Delivers a sample recap notification in a few seconds"
        }

        cell.contentConfiguration = content
        return cell
    }

    private func previewConfiguration(title: String, body: String) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.subtitleCell()
        content.text = title
        content.secondaryText = body
        content.textProperties.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
        content.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 3
        content.textToSecondaryTextVerticalPadding = 2
        content.image = UIImage(systemName: "sparkles")?.withTintColor(.systemIndigo, renderingMode: .alwaysOriginal)
        content.imageProperties.maximumSize = CGSize(width: 28, height: 28)
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        return content
    }

    private func makeTimePicker() -> UIDatePicker {
        let picker = UIDatePicker()
        picker.datePickerMode = .time
        picker.preferredDatePickerStyle = .compact
        var components = DateComponents()
        components.hour = scheduler.deliveryHour
        components.minute = scheduler.deliveryMinute
        picker.date = Calendar.current.date(from: components) ?? Date(timeIntervalSince1970: 0)
        picker.accessibilityLabel = "Delivery time"
        picker.addAction(UIAction { [weak self] action in
            guard let self, let picker = action.sender as? UIDatePicker else { return }
            let parts = Calendar.current.dateComponents([.hour, .minute], from: picker.date)
            self.scheduler.deliveryHour = parts.hour ?? 19
            self.scheduler.deliveryMinute = parts.minute ?? 0
            self.selectionFeedback.selectionChanged()
            self.rescheduleAndRefresh()
        }, for: .valueChanged)
        return picker
    }

    private func makeWeekdayButton(currentName: String) -> UIButton {
        let symbols = Calendar.current.weekdaySymbols
        let actions = symbols.enumerated().map { index, name in
            UIAction(title: name, state: index + 1 == scheduler.weeklyWeekday ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.scheduler.weeklyWeekday = index + 1
                self.selectionFeedback.selectionChanged()
                self.rescheduleAndRefresh()
            }
        }
        return makeMenuButton(title: currentName, actions: actions, accessibilityLabel: "Day of week")
    }

    private func makeMonthDayButton(currentDay: Int) -> UIButton {
        let actions = (1...28).map { day in
            UIAction(title: "\(day)", state: day == scheduler.monthlyDay ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.scheduler.monthlyDay = day
                self.selectionFeedback.selectionChanged()
                self.rescheduleAndRefresh()
            }
        }
        return makeMenuButton(title: "\(currentDay)", actions: actions, accessibilityLabel: "Day of month")
    }

    private func makeMenuButton(title: String, actions: [UIAction], accessibilityLabel: String) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.title = title
        config.cornerStyle = .medium
        config.baseForegroundColor = .label
        config.buttonSize = .small
        let button = UIButton(configuration: config)
        button.menu = UIMenu(children: actions)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = accessibilityLabel
        button.sizeToFit()
        return button
    }

    private func rescheduleAndRefresh() {
        Task {
            await scheduler.refreshSchedule(force: true)
            applySnapshot(animated: true)
        }
    }

    override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return false }
        switch row {
        case .permissionDenied, .frequency, .sendTest: return true
        default: return false
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        switch row {
        case .permissionDenied:
            impactLight.impactOccurred()
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        case .frequency(let frequency, let selected):
            guard !selected else { return }
            selectionFeedback.selectionChanged()
            applyFrequency(frequency)
        case .sendTest:
            impactLight.impactOccurred()
            sendTest()
        default:
            break
        }
    }

    private func applyFrequency(_ frequency: RecapNotificationFrequency) {
        Task {
            let authorized = await scheduler.setFrequency(frequency)
            if authorized {
                notificationFeedback.notificationOccurred(.success)
            } else {
                notificationFeedback.notificationOccurred(.error)
            }
            refreshAuthorization()
            applySnapshot(animated: true)
        }
    }

    private func sendTest() {
        Task {
            let sent = await scheduler.sendTestNotification()
            if sent {
                notificationFeedback.notificationOccurred(.success)
                ToastView.show("Test notification on its way", in: view, style: .success)
            } else {
                notificationFeedback.notificationOccurred(.error)
                ToastView.show("Allow notifications in Settings first", in: view, style: .error)
            }
            refreshAuthorization()
        }
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        .systemFont(ofSize: pointSize, weight: weight)
    }
}
