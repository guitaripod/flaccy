import AVFoundation
import FlaccyCore
import FlaccyEngine
import MidgarCore
import UIKit

extension SettingsViewController {

    /// The Listening Guide cards worth reading for the output in use, each opening the guide.
    func guideRows(for kind: SignalOutputKind?) -> [Row] {
        SignalPathSummary.guideCards(for: kind).map {
            .guideCard(index: $0.index, title: $0.card.title, symbolName: $0.card.symbolName)
        }
    }

    func soundSections() -> [(Section, [Row])] {
        let summary = SignalPathSummary.current()
        return [
            (.signalPath, [.signalPath(summary)]),
            (.thisOutput, guideRows(for: summary.outputKind)),
            (.soundControls, [
                .equalizer(summary: EqualizerCopy.settingsSummary),
                .songVolumes(count: songVolumeCount),
            ]),
            (.listeningGuide, [.listeningGuide]),
        ]
    }

    /// Reads the library overview off the main thread and shows it once it lands.
    func refreshLibraryOverview() {
        let albums = Library.shared.albums
        Task { [weak self] in
            guard let summary = await LibraryOverviewSummary.load(albums: albums),
                  let self, self.libraryOverview != summary else { return }
            self.libraryOverview = summary
            self.applySnapshot(animated: false)
        }
    }

    /// Counts the songs in this library with a volume of their own, the list Song Volumes shows.
    /// Levels synced from another device for songs this library lacks are not counted.
    func refreshSongVolumeCount() {
        songVolumeCount = SongVolumeStore.shared.adjustedSongs(in: Library.shared.allTracks).count
    }

    /// Keeps the Sound page and the root's Sound row with the song, the equalizer, the song's own
    /// volume and the output as they change.
    func observeSound() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            AudioPlayer.trackDidChange, EqualizerEngine.stateDidChange, EqualizerEngine.outputDidChange,
            SongVolumeStore.didChange, AVAudioSession.routeChangeNotification, Library.didUpdateNotification,
        ]
        for name in names {
            let libraryChanged = name == Library.didUpdateNotification
            let songsChanged = libraryChanged || name == SongVolumeStore.didChange
            soundObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if libraryChanged { self?.refreshLibraryOverview() }
                    if songsChanged { self?.refreshSongVolumeCount() }
                    self?.applySnapshot(animated: false)
                }
            })
        }
    }

    func handleGuideCardTap(_ index: Int?) {
        selectionFeedback.selectionChanged()
        navigationController?.pushViewController(ListeningGuideViewController(focusing: index), animated: true)
    }

    func handleSongVolumesTap() {
        selectionFeedback.selectionChanged()
        navigationController?.pushViewController(SongVolumesViewController(), animated: true)
    }

    func handleHomeScreenTap() {
        selectionFeedback.selectionChanged()
        let editor = EditHomeViewController()
        editor.modalPresentationStyle = .pageSheet
        editor.sheetPresentationController?.detents = [.large()]
        editor.sheetPresentationController?.prefersGrabberVisible = true
        presenter.present(editor, animated: true)
    }

    func handlePlayerButtonsTap() {
        guard PlayerActionOrderStore.shared.order != .standard else { return }
        impactMedium.impactOccurred()
        let alert = UIAlertController(
            title: String(localized: "Reset Player Buttons?"),
            message: String(localized: "The buttons under Now Playing go back to their original order."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Reset"), style: .destructive) { [weak self] _ in
            PlayerActionOrderStore.shared.restoreDefault()
            self?.notificationFeedback.notificationOccurred(.success)
            self?.applySnapshot(animated: true)
        })
        presenter.present(alert, animated: true)
    }
}
