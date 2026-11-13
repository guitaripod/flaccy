import FlaccyCore
import FlaccyEngine
import MidgarCore
import UIKit

/// Every song with a volume of its own, louder or quieter than the rest, with a way to put one or
/// all of them back to the album's level. The levels are set from Now Playing; this is where they
/// are found again.
final class SongVolumesViewController: UITableViewController {

    private static let reuseIdentifier = "SongVolume"

    private var songs: [(track: Track, tenths: Int)] = []
    private var observer: NSObjectProtocol?
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let notificationFeedback = UINotificationFeedbackGenerator()

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Song Volumes")
        navigationItem.largeTitleDisplayMode = .never
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.reuseIdentifier)
        tableView.accessibilityIdentifier = "settings.songVolumes"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Reset All"),
            primaryAction: UIAction { [weak self] _ in self?.confirmResetAll() }
        )
        observer = NotificationCenter.default.addObserver(forName: SongVolumeStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    private func reload() {
        songs = SongVolumeStore.shared.adjustedSongs(in: Library.shared.allTracks)
        navigationItem.rightBarButtonItem?.isEnabled = !songs.isEmpty
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(songs.count, 1)
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        String(localized: "Set a song's own volume from Now Playing. Swipe one here to put it back.")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.reuseIdentifier, for: indexPath)
        var content = UIListContentConfiguration.valueCell()
        cell.selectionStyle = .none
        guard songs.indices.contains(indexPath.row) else {
            content.text = String(localized: "Every song plays at its own level")
            content.textProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            return cell
        }
        let song = songs[indexPath.row]
        content = .subtitleCell()
        content.text = song.track.title
        content.secondaryText = song.track.artist
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        let level = UILabel()
        level.text = SongGain.label(song.tenths)
        level.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        level.textColor = song.tenths > 0 ? .systemOrange : .secondaryLabel
        level.sizeToFit()
        cell.accessoryView = level
        cell.accessibilityLabel = "\(song.track.title), \(song.track.artist)"
        cell.accessibilityValue = SongGain.label(song.tenths)
        return cell
    }

    override func tableView(
        _ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard songs.indices.contains(indexPath.row) else { return nil }
        let track = songs[indexPath.row].track
        let reset = UIContextualAction(style: .destructive, title: String(localized: "Reset")) { [weak self] _, _, done in
            self?.reset([track])
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [reset])
    }

    private func confirmResetAll() {
        guard !songs.isEmpty else { return }
        impactMedium.impactOccurred()
        let alert = UIAlertController(
            title: String(localized: "Reset All Song Volumes?"),
            message: String(localized: "Every song plays at the level it was mastered at again."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Reset All"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.reset(self.songs.map(\.track))
        })
        present(alert, animated: true)
    }

    private func reset(_ tracks: [Track]) {
        var failed = false
        for track in tracks {
            do {
                try SongVolumeStore.shared.set(0, for: track)
            } catch {
                failed = true
            }
        }
        notificationFeedback.notificationOccurred(failed ? .error : .success)
        if failed {
            ToastView.show(String(localized: "A song volume couldn't be reset. Try again."), in: view, style: .error)
        }
        reload()
    }
}
