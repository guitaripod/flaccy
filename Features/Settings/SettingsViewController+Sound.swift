import AVFoundation
import FlaccyCore
import FlaccyEngine
import MidgarCore
import UIKit

/// The Sound page's account of the song playing now: the file, what Flaccy does to it, where it
/// goes, and the one-line verdict, each read from the player, the equalizer, the song's own
/// volume and the audio route.
nonisolated struct SignalPathSummary: Hashable {
    let source: String
    let sourceDetail: String
    let processing: String
    let processingDetail: String?
    let output: String
    let outputDetail: String?
    let verdict: SignalPathVerdict
    let outputKind: SignalOutputKind?
}

/// The library by the numbers for the top of the Library page.
nonisolated struct LibraryOverviewSummary: Hashable {
    let songs: Int
    let albums: Int
    let artists: Int
    let hours: Int
    let losslessPercent: Int
    let hiRes: Int
    let musicBytes: Int64
    let formats: [Format]

    nonisolated struct Format: Hashable {
        let codec: String
        let songs: Int
    }

    static let empty = LibraryOverviewSummary(
        songs: 0, albums: 0, artists: 0, hours: 0, losslessPercent: 0, hiRes: 0, musicBytes: 0, formats: []
    )
}

extension SettingsViewController {

    func makeSignalPathSummary() -> SignalPathSummary {
        let track = AudioPlayer.shared.currentTrack
        let engine = EqualizerEngine.shared
        let running = engine.runningProfile
        let tenths = track.map { SongVolumeStore.shared.level(for: $0) } ?? 0
        let output = engine.output
        let outputKind = output.map { SignalOutputKind(rawValue: $0.kind.rawValue) ?? .other }
        let verdict = SignalPathVerdict.of(
            sourceIsLossless: track.map(\.isLossless),
            processed: running != nil || tenths != 0,
            output: outputKind
        )
        return SignalPathSummary(
            source: track.map { $0.qualityBadge ?? $0.title } ?? String(localized: "Nothing playing"),
            sourceDetail: track.map(Self.sourceDetail(of:)) ?? String(localized: "Play a song to see how it reaches you."),
            processing: running == nil && tenths == 0 ? String(localized: "Untouched") : String(localized: "Shaped"),
            processingDetail: Self.processingDetail(profile: running, tenths: tenths),
            output: output?.name ?? String(localized: "This device"),
            outputDetail: Self.outputDetail(kind: outputKind),
            verdict: verdict,
            outputKind: outputKind
        )
    }

    nonisolated static func sourceDetail(of track: Track) -> String {
        let hiRes = (track.bitDepth ?? 0) > 16 || (track.sampleRate ?? 0) > 48_000
        let quality = track.isLossless
            ? (hiRes ? String(localized: "Lossless, hi-res") : String(localized: "Lossless"))
            : String(localized: "Lossy")
        return "\(track.title) · \(quality)"
    }

    static func processingDetail(profile: EqualizerProfile?, tenths: Int) -> String? {
        var parts: [String] = []
        if let profile {
            parts.append(String(localized: "Equalizer: \(EqualizerCopy.name(of: profile))"))
        }
        if tenths != 0 {
            parts.append(String(localized: "Song volume \(SongGain.label(tenths))"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The kind of output and the rate the system runs it at, such as "Bluetooth · 48 kHz".
    static func outputDetail(kind: SignalOutputKind?) -> String? {
        let name: String? = switch kind {
        case .speaker: String(localized: "Built-in speaker")
        case .headphones: String(localized: "Wired headphones")
        case .bluetooth: String(localized: "Bluetooth")
        case .airPlay: String(localized: "AirPlay")
        case .usb: String(localized: "USB audio")
        case .display: String(localized: "Display")
        case .car: String(localized: "CarPlay")
        case .other, nil: nil
        }
        let hertz = AVAudioSession.sharedInstance().sampleRate
        let rate = hertz > 0 ? "\((hertz / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz" : nil
        let parts = [name, rate].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The Listening Guide cards worth reading for the output in use, each opening the guide.
    func guideRows(for kind: SignalOutputKind?) -> [Row] {
        let cards = ListeningGuideContent.cards
        return SignalPathVerdict.guideCards(for: kind).compactMap { index in
            guard cards.indices.contains(index) else { return nil }
            return .guideCard(index: index, title: cards[index].title, symbolName: cards[index].symbolName)
        }
    }

    func soundSections() -> [(Section, [Row])] {
        let summary = makeSignalPathSummary()
        return [
            (.signalPath, [.signalPath(summary)]),
            (.thisOutput, guideRows(for: summary.outputKind)),
            (.soundControls, [
                .equalizer(summary: EqualizerCopy.settingsSummary),
                .songVolumes(count: SongVolumeStore.shared.adjustedCount),
            ]),
            (.listeningGuide, [.listeningGuide]),
        ]
    }

    /// Reads the library overview off the main thread and shows it once it lands.
    func refreshLibraryOverview() {
        let albums = Library.shared.albums
        Task.detached(priority: .utility) { [weak self] in
            guard let totals = try? DatabaseManager.shared.libraryOverview() else { return }
            let artists = Set(albums.map { LibraryHygiene.artistKey($0.artist) }).count
            let summary = LibraryOverviewSummary(
                songs: totals.tracks,
                albums: albums.count,
                artists: artists,
                hours: Int((totals.seconds / 3600).rounded()),
                losslessPercent: Int((totals.losslessShare * 100).rounded()),
                hiRes: totals.hiRes,
                musicBytes: totals.localBytes,
                formats: totals.codecs.map { LibraryOverviewSummary.Format(codec: $0.codec, songs: $0.tracks) }
            )
            await MainActor.run { [weak self] in
                guard let self, self.libraryOverview != summary else { return }
                self.libraryOverview = summary
                self.applySnapshot(animated: false)
            }
        }
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
            soundObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if libraryChanged { self?.refreshLibraryOverview() }
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
