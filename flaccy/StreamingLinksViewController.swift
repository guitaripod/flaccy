import UIKit

final class StreamingLinksViewController: UIViewController {

    private enum Section: Int, CaseIterable {
        case universal
        case platforms
    }

    private let result: SonglinkResult
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var platforms: [(SonglinkPlatform, URL)] = []

    init(result: SonglinkResult) {
        self.result = result
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        title = "Share"

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                self?.dismiss(animated: true)
            }
        )

        platforms = SonglinkPlatform.allCases.compactMap { platform in
            guard let url = result.platformLinks[platform] else { return nil }
            return (platform, url)
        }

        setupTableView()
    }

    private func setupTableView() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = UILabel()
        titleLabel.text = result.title
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2

        let artistLabel = UILabel()
        artistLabel.text = result.artist
        artistLabel.font = .systemFont(ofSize: 16, weight: .regular)
        artistLabel.textColor = .secondaryLabel
        artistLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [titleLabel, artistLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.alignment = .center

        let header = UIView()
        header.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 80)
        stack.frame = header.bounds.inset(by: UIEdgeInsets(top: 20, left: 20, bottom: 12, right: 20))
        stack.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        header.addSubview(stack)
        tableView.tableHeaderView = header

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func shareURL(_ url: URL, label: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let text = "\(result.title) by \(result.artist)"
        let activity = UIActivityViewController(activityItems: [text, url], applicationActivities: nil)
        activity.completionWithItemsHandler = { [weak self] type, completed, _, _ in
            if completed {
                self?.dismiss(animated: true)
            }
        }
        present(activity, animated: true)
    }

    private func copyURL(_ url: URL, label: String) {
        UIPasteboard.general.url = url
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        ToastView.show("\(label) link copied", in: view, style: .success)
    }

    private func colorFromHex(_ hex: UInt) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1.0
        )
    }
}

extension StreamingLinksViewController: UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .universal: return 2
        case .platforms: return platforms.count
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .universal: return "Universal Link"
        case .platforms: return "Share Platform Link"
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .universal: return "Recipients choose their preferred platform"
        case .platforms: return nil
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .universal:
            return indexPath.row == 0 ? shareUniversalCell() : copyUniversalCell()
        case .platforms:
            return platformCell(for: indexPath)
        }
    }

    private func shareUniversalCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var config = UIListContentConfiguration.cell()
        config.text = "Share"
        config.secondaryText = result.pageURL.absoluteString
        config.secondaryTextProperties.color = .tertiaryLabel
        config.secondaryTextProperties.font = .systemFont(ofSize: 12)
        config.secondaryTextProperties.numberOfLines = 1
        config.image = UIImage(systemName: "square.and.arrow.up")
        config.imageProperties.tintColor = .tintColor
        cell.contentConfiguration = config
        return cell
    }

    private func copyUniversalCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var config = UIListContentConfiguration.cell()
        config.text = "Copy Link"
        config.image = UIImage(systemName: "doc.on.doc")
        config.imageProperties.tintColor = .tintColor
        cell.contentConfiguration = config
        return cell
    }

    private func platformCell(for indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: "PlatformCell")
        let (platform, _) = platforms[indexPath.row]

        let icon = UIImageView(image: UIImage(systemName: platform.iconName))
        icon.tintColor = colorFromHex(platform.tintColorHex)
        icon.contentMode = .scaleAspectFit

        let label = UILabel()
        label.text = platform.displayName
        label.font = .preferredFont(forTextStyle: .body)

        let shareIcon = UIImageView(image: UIImage(systemName: "square.and.arrow.up"))
        shareIcon.tintColor = .tertiaryLabel
        shareIcon.contentMode = .scaleAspectFit
        shareIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)

        let stack = UIStackView(arrangedSubviews: [icon, label, UIView(), shareIcon])
        stack.spacing = 14
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            stack.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -10),
        ])

        return cell
    }
}

extension StreamingLinksViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        switch Section(rawValue: indexPath.section)! {
        case .universal:
            if indexPath.row == 0 {
                shareURL(result.pageURL, label: "Universal")
            } else {
                copyURL(result.pageURL, label: "Universal")
            }
        case .platforms:
            let (platform, url) = platforms[indexPath.row]
            shareURL(url, label: platform.displayName)
        }
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let url: URL
        let label: String

        switch Section(rawValue: indexPath.section)! {
        case .universal:
            url = result.pageURL
            label = "Universal"
        case .platforms:
            let (platform, platformURL) = platforms[indexPath.row]
            url = platformURL
            label = platform.displayName
        }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }

            let share = UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                self.shareURL(url, label: label)
            }
            let copy = UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { _ in
                self.copyURL(url, label: label)
            }
            let open = UIAction(title: "Open", image: UIImage(systemName: "safari")) { _ in
                UIApplication.shared.open(url)
            }
            return UIMenu(children: [share, copy, open])
        }
    }
}
