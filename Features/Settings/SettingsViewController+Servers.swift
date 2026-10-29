import FlaccyCore
import MidgarCore
import UIKit

extension SettingsViewController {

    func observeServers() {
        serversModel.onChange = { [weak self] in
            self?.applySnapshot(animated: true)
        }
        serversModel.start()
    }

    func serverRows() -> [Row] {
        [.serversExplainer] + serversModel.rows.map { Row.server($0) } + [.addFlaccyServer, .addServer]
    }

    func configureServerRow(_ row: Row, cell: UITableViewCell, content: inout UIListContentConfiguration) {
        switch row {
        case .serversExplainer:
            content = .cell()
            content.text = RemoteCopy.explainer
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            content.textProperties.color = .secondaryLabel
            content.textProperties.numberOfLines = 0
            cell.selectionStyle = .none
            cell.accessibilityTraits = .staticText
            cell.accessibilityIdentifier = "settings.row.serversExplainer"

        case .server(let server):
            content.image = RowIcon.image(systemName: "server.rack", tint: .systemIndigo)
            content.text = server.name
            content.secondaryTextProperties.numberOfLines = 0
            cell.accessibilityLabel = server.name
            if let flaccy = server.flaccy {
                configureFlaccyServerRow(flaccy, cell: cell, content: &content)
            } else {
                content.secondaryText = RemoteCopy.detail(for: server)
                content.secondaryTextProperties.color = server.lastFailure == nil ? .secondaryLabel : .systemRed
                cell.selectionStyle = .none
                cell.accessoryView = makeServerMenuButton(for: server)
                cell.accessibilityTraits = []
                cell.accessibilityValue = RemoteCopy.detail(for: server)
                cell.accessibilityIdentifier = "settings.row.server"
            }

        case .addFlaccyServer:
            content.image = RowIcon.image(systemName: "plus", tint: .systemGreen)
            content.text = String(localized: "Add Flaccy Server")
            content.textProperties.color = .tintColor
            cell.accessibilityLabel = String(localized: "Add Flaccy Server")
            cell.accessibilityIdentifier = "settings.row.addFlaccyServer"

        case .addServer:
            content.image = RowIcon.image(systemName: "plus", tint: .systemGray)
            content.text = String(localized: "Add Other Server")
            content.textProperties.color = .tintColor
            cell.accessibilityLabel = String(localized: "Add Other Server")
            cell.accessibilityIdentifier = "settings.row.addServer"

        case .cacheLimit:
            content.image = RowIcon.image(systemName: "externaldrive.fill", tint: .systemTeal)
            content.text = String(localized: "Cache Limit")
            cell.selectionStyle = .none
            cell.accessibilityTraits = []
            cell.accessoryView = makeCacheLimitStepper(gigabytes: serversModel.cacheLimitGigabytes)
            cell.accessibilityIdentifier = "settings.row.cacheLimit"

        case .cacheUsage(let caption):
            content = .cell()
            content.text = caption.isEmpty ? "\u{2026}" : caption
            content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
            content.textProperties.color = .secondaryLabel
            cell.selectionStyle = .none
            cell.accessibilityTraits = .staticText
            cell.accessibilityIdentifier = "settings.row.cacheUsage"

        case .clearCache:
            content.image = RowIcon.image(systemName: "trash.fill", tint: .systemRed)
            content.text = String(localized: "Clear Cache")
            content.textProperties.color = .systemRed
            cell.accessibilityLabel = String(localized: "Clear Cache")
            cell.accessibilityHint = String(localized: "Removes cached songs and keeps your downloads")
            cell.accessibilityIdentifier = "settings.row.clearCache"

        default:
            break
        }
    }

    private func configureFlaccyServerRow(
        _ flaccy: FlaccyServerRowModel, cell: UITableViewCell, content: inout UIListContentConfiguration
    ) {
        content.secondaryText = flaccy.statusLine
        content.secondaryTextProperties.color = flaccy.needsPro ? .tintColor : .secondaryLabel
        cell.accessoryView = makeSyncBadge()
        cell.accessibilityTraits = [.button, .updatesFrequently]
        cell.accessibilityValue = flaccy.accessibilityValue
        cell.accessibilityHint = String(localized: "Opens the server\u{2019}s settings")
        cell.accessibilityIdentifier = "settings.row.flaccyServer"
    }

    private func makeSyncBadge() -> UIView {
        let label = PaddedBadgeLabel()
        label.text = String(localized: "Sync")
        label.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 12, weight: .semibold))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .tintColor
        label.backgroundColor = UIColor.tintColor.withAlphaComponent(0.14)
        label.layer.cornerRadius = 9
        label.layer.masksToBounds = true
        label.accessibilityIdentifier = "settings.row.flaccyServer.badge"
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = .tertiaryLabel
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let stack = UIStackView(arrangedSubviews: [label, chevron])
        stack.spacing = 10
        stack.alignment = .center
        stack.frame = CGRect(origin: .zero, size: stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize))
        return stack
    }

    func makeServerMenuButton(for server: RemoteServerRow) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "ellipsis.circle")
        let button = UIButton(configuration: configuration)
        button.menu = UIMenu(children: [
            UIAction(title: String(localized: "Refresh"), image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                self?.refreshServer(server)
            },
            UIAction(title: String(localized: "Rename"), image: UIImage(systemName: "pencil")) { [weak self] _ in
                self?.promptRename(server)
            },
            UIAction(title: String(localized: "Remove"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.confirmRemove(server)
            },
        ])
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = String(localized: "Actions for \(server.name)")
        button.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        return button
    }

    func makeCacheLimitStepper(gigabytes: Int) -> UIView {
        let stepper = UIStepper()
        stepper.minimumValue = Double(RemoteServersViewModel.cacheLimitRange.lowerBound)
        stepper.maximumValue = Double(RemoteServersViewModel.cacheLimitRange.upperBound)
        stepper.stepValue = 1
        stepper.value = Double(gigabytes)
        stepper.accessibilityLabel = String(localized: "Cache Limit")
        stepper.accessibilityValue = RemoteCopy.cacheLimit(gigabytes: gigabytes)
        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: 17, weight: .regular)
        label.textColor = .secondaryLabel
        label.text = RemoteCopy.cacheLimit(gigabytes: gigabytes)
        label.setContentHuggingPriority(.required, for: .horizontal)
        stepper.addAction(UIAction { [weak self, weak stepper, weak label] _ in
            guard let self, let stepper else { return }
            let value = Int(stepper.value)
            self.selectionFeedback.selectionChanged()
            label?.text = RemoteCopy.cacheLimit(gigabytes: value)
            stepper.accessibilityValue = RemoteCopy.cacheLimit(gigabytes: value)
            self.serversModel.cacheLimitGigabytes = value
        }, for: .valueChanged)
        let stack = UIStackView(arrangedSubviews: [label, stepper])
        stack.spacing = 12
        stack.alignment = .center
        stack.frame = CGRect(origin: .zero, size: stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize))
        return stack
    }

    override func tableView(
        _ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard case .server(let server) = dataSource.itemIdentifier(for: indexPath), server.flaccy == nil else { return nil }
        let remove = UIContextualAction(style: .destructive, title: String(localized: "Remove")) { [weak self] _, _, done in
            self?.confirmRemove(server)
            done(true)
        }
        let rename = UIContextualAction(style: .normal, title: String(localized: "Rename")) { [weak self] _, _, done in
            self?.promptRename(server)
            done(true)
        }
        rename.backgroundColor = .systemBlue
        let refresh = UIContextualAction(style: .normal, title: String(localized: "Refresh")) { [weak self] _, _, done in
            self?.refreshServer(server)
            done(true)
        }
        refresh.backgroundColor = .systemIndigo
        return UISwipeActionsConfiguration(actions: [remove, rename, refresh])
    }

    func handleAddFlaccyServerTap() {
        impactLight.impactOccurred()
        AddFlaccyServerViewController.present(from: self)
    }

    func handleAddServerTap() {
        impactLight.impactOccurred()
        AddServerViewController.present(from: self, servers: serversModel)
    }

    func handleServerTap(_ server: RemoteServerRow) {
        guard server.flaccy != nil, let record = try? DatabaseManager.shared.fetchRemoteServer(id: server.id) else { return }
        impactLight.impactOccurred()
        navigationController?.pushViewController(FlaccyServerDetailViewController(record: record), animated: true)
    }

    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        guard dataSource.sectionIdentifier(for: section) == .servers, FlaccyServerNudge.isVisible(serverCount: serversModel.rows.count)
        else { return nil }
        return FlaccyServerNudgeView { [weak self] in
            self?.impactLight.impactOccurred()
            FlaccyServerNudge.dismiss()
            guard let self else { return }
            var snapshot = self.dataSource.snapshot()
            snapshot.reloadSections([.servers])
            self.dataSource.apply(snapshot, animatingDifferences: true)
        }
    }

    func refreshServer(_ server: RemoteServerRow) {
        impactLight.impactOccurred()
        serversModel.refresh(serverID: server.id)
    }

    func promptRename(_ server: RemoteServerRow) {
        impactLight.impactOccurred()
        let alert = UIAlertController(
            title: String(localized: "Rename Server"),
            message: String(localized: "The name shows in the library\u{2019}s source filter and in messages. Its songs stay where they are."),
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.text = server.name
            field.placeholder = String(localized: "Name")
            field.autocapitalizationType = .words
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Rename"), style: .default) { [weak self, weak alert] _ in
            let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self?.rename(server, to: name)
        })
        present(alert, animated: true)
    }

    private func rename(_ server: RemoteServerRow, to name: String) {
        guard !name.isEmpty else {
            notificationFeedback.notificationOccurred(.warning)
            ToastView.show(String(localized: "A server needs a name. Type one and try again."), in: view, style: .error)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.serversModel.rename(serverID: server.id, to: name)
                self.notificationFeedback.notificationOccurred(.success)
            } catch {
                let host = server.address
                self.notificationFeedback.notificationOccurred(.error)
                ToastView.show(RemoteFailure.from(error, host: host).errorDescription ?? "", in: self.view, style: .error)
            }
        }
    }

    func confirmRemove(_ server: RemoteServerRow) {
        impactMedium.impactOccurred()
        let alert = UIAlertController(
            title: String(localized: "Remove \u{201C}\(server.name)\u{201D}?"),
            message: RemoteCopy.removalMessage(songCount: server.songCount),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Remove Server"), style: .destructive) { [weak self] _ in
            self?.remove(server)
        })
        present(alert, animated: true)
    }

    private func remove(_ server: RemoteServerRow) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let sentence = try await self.serversModel.remove(serverID: server.id)
                self.notificationFeedback.notificationOccurred(.success)
                ToastView.show(sentence, in: self.view, style: .info)
            } catch {
                self.notificationFeedback.notificationOccurred(.error)
                ToastView.show(RemoteFailure.from(error, host: server.address).errorDescription ?? "", in: self.view, style: .error)
            }
        }
    }

    func handleClearCacheTap() {
        impactMedium.impactOccurred()
        let alert = UIAlertController(
            title: String(localized: "Clear Cache?"),
            message: String(localized: "Songs you streamed are fetched from the server again the next time you play them. Songs you downloaded are not touched."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Clear Cache"), style: .destructive) { [weak self] _ in
            Task { [weak self] in
                guard let self else { return }
                let freed = await self.serversModel.clearCache()
                self.notificationFeedback.notificationOccurred(.success)
                ToastView.show(RemoteCopy.cacheCleared(bytes: freed), in: self.view, style: .success)
            }
        })
        present(alert, animated: true)
    }
}
