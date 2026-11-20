import UIKit

/// Every copy of one song the library holds, with the one the lists show
/// marked and where each copy lives. Tapping a row plays that copy; swiping
/// deletes a copy's file on this device, or removes a server copy's download.
/// A copy on a server is never deleted from here: the server keeps it.
final class DuplicateCopiesViewController: UITableViewController {

    private var copies: [Track]
    private let shownURL: URL

    init(shown: Track, others: [Track]) {
        self.shownURL = shown.fileURL
        self.copies = [shown] + others
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func present(shown: Track, others: [Track], from presenter: UIViewController) {
        let controller = DuplicateCopiesViewController(shown: shown, others: others)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.overrideUserInterfaceStyle = .dark
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        presenter.present(navigation, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Copies of This Song")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "copy")
        tableView.backgroundColor = .black
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        copies.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        String(localized: "Flaccy lists one copy of each song. Tap a copy to play it. Swipe a copy on this device to delete its file; copies on a server stay there.")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "copy", for: indexPath)
        let track = copies[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = track.albumTitle.isEmpty ? track.title : track.albumTitle
        content.textProperties.font = .scaled(.body, size: 16, weight: .semibold)
        content.textProperties.color = .white
        content.secondaryText = detail(for: track)
        content.secondaryTextProperties.font = .scaled(.footnote, size: 13, weight: .regular)
        content.secondaryTextProperties.color = UIColor.white.withAlphaComponent(0.6)
        cell.contentConfiguration = content
        cell.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        if track.fileURL == shownURL {
            let label = UILabel()
            label.text = String(localized: "Shown")
            label.font = .scaled(.caption1, size: 11, weight: .semibold)
            label.textColor = .systemBlue
            label.sizeToFit()
            cell.accessoryView = label
        } else {
            cell.accessoryView = nil
        }
        return cell
    }

    private func detail(for track: Track) -> String {
        var parts: [String] = [track.artist, location(of: track)]
        if let song = track.remoteSong, RemoteAvailability.shared.isDownloaded(path: song.path) {
            parts.append(RemoteCopy.downloadedMarkLabel)
        }
        if let badge = track.qualityBadge { parts.append(badge) }
        let minutes = Int(track.duration) / 60
        let seconds = Int(track.duration) % 60
        parts.append(String(format: "%d:%02d", minutes, seconds))
        return parts.joined(separator: " \u{00B7} ")
    }

    /// This device, or the name of the server the copy plays from.
    private func location(of track: Track) -> String {
        guard let song = track.remoteSong else { return LibrarySource.localTitle }
        return serverNames[song.serverID] ?? song.serverID
    }

    private lazy var serverNames: [String: String] = Dictionary(
        ((try? DatabaseManager.shared.fetchRemoteServers()) ?? []).map { ($0.id, $0.name) },
        uniquingKeysWith: { first, _ in first }
    )

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        AudioPlayer.shared.play([copies[indexPath.row]], startingAt: 0)
    }

    override func tableView(
        _ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let track = copies[indexPath.row]
        if let song = track.remoteSong {
            guard RemoteAvailability.shared.isPinned(path: song.path) else { return nil }
            let remove = UIContextualAction(style: .normal, title: RemoteCopy.removeDownloadAction) { [weak self] _, _, completion in
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                Task { @MainActor in
                    let removed = await RemoteDownloads.remove(paths: [song.path])
                    if let view = self?.view { ToastView.show(RemoteCopy.downloadsRemoved(removed), in: view, style: .info) }
                    self?.tableView.reloadData()
                }
                completion(true)
            }
            remove.image = UIImage(systemName: "arrow.down.circle")
            return UISwipeActionsConfiguration(actions: [remove])
        }
        let keeper = copies.first { $0.remoteSong != nil }.flatMap(\.remoteSong).map { serverNames[$0.serverID] ?? $0.serverID }
        let message = keeper.map {
            String(localized: "The file from \"\(track.albumTitle)\" is deleted from this device. \($0) keeps its copy.")
        } ?? String(localized: "The audio file from \"\(track.albumTitle)\" will be removed from this device.")
        let delete = UIContextualAction(style: .destructive, title: String(localized: "Delete")) { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            TrackContextMenu.confirmDelete(
                title: String(localized: "Delete this copy?"),
                message: message,
                in: self
            ) { [weak self] in
                Task { @MainActor in
                    await Library.shared.deleteTracks([track])
                    self?.remove(track)
                }
            }
            completion(true)
        }
        delete.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [delete])
    }

    private func remove(_ track: Track) {
        guard let row = copies.firstIndex(where: { $0.fileURL == track.fileURL }) else { return }
        copies.remove(at: row)
        if copies.count < 2 {
            dismiss(animated: true)
            return
        }
        tableView.deleteRows(at: [IndexPath(row: row, section: 0)], with: .automatic)
    }
}
