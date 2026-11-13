import AppKit
import FlaccyCore
import FlaccyEngine
import MidgarCore

/// Sound: how the song playing reaches the ear (file, Flaccy, output, verdict), the Listening
/// Guide cards that fit the output in use, the equalizer, every song's own volume, and the guide.
final class SoundSettingsPane: SettingsPane {

    private let signalPath = MacSignalPathView()
    private let guideCards = NSStackView()
    private let equalizerSummary = NSTextField(labelWithString: "")
    private let songVolumesSummary = NSTextField(labelWithString: "")
    private let songVolumesTable = NSTableView()
    private let songVolumesScroll = NSScrollView()
    private let resetButton = NSButton(title: String(localized: "Reset"), target: nil, action: nil)
    private let resetAllButton = NSButton(title: String(localized: "Reset All"), target: nil, action: nil)
    private let thisSongButton = NSButton(title: String(localized: "Song Volume…"), target: nil, action: nil)
    private var songs: [(track: Track, tenths: Int)] = []
    private var observers: [NSObjectProtocol] = []

    override func buildForm() {
        formStack.addArrangedSubview(sectionLabel(String(localized: "Signal Path")))
        addFullWidth(signalPath)
        addFullWidth(explanation(String(localized: "Flaccy sees the file, its own processing and the kind of output. What the device does after that is up to the device.")))
        formStack.addArrangedSubview(separator())

        formStack.addArrangedSubview(sectionLabel(String(localized: "About This Output")))
        guideCards.orientation = .vertical
        guideCards.alignment = .leading
        guideCards.spacing = 4
        formStack.addArrangedSubview(guideCards)
        formStack.addArrangedSubview(separator())

        formStack.addArrangedSubview(sectionLabel(EqualizerCopy.title))
        equalizerSummary.font = .systemFont(ofSize: 13)
        let equalizerButton = NSButton(title: String(localized: "Open Equalizer…"), target: self, action: #selector(openEqualizer))
        equalizerButton.bezelStyle = .rounded
        addRow([equalizerSummary, equalizerButton], spacing: 10)
        formStack.addArrangedSubview(separator())

        formStack.addArrangedSubview(sectionLabel(String(localized: "Song Volumes")))
        songVolumesSummary.font = .systemFont(ofSize: 13)
        addFullWidth(songVolumesSummary)
        configureSongVolumesTable()
        addFullWidth(songVolumesScroll)
        for button in [resetButton, resetAllButton, thisSongButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
        }
        resetButton.action = #selector(resetSelected)
        resetAllButton.action = #selector(confirmResetAll)
        thisSongButton.action = #selector(openThisSong)
        addRow([resetButton, resetAllButton, thisSongButton], spacing: 8)
        addFullWidth(explanation(String(localized: "A song's own volume is set from Now Playing or the Playback menu. Reset puts it back at the level it was mastered at.")))
        formStack.addArrangedSubview(separator())

        formStack.addArrangedSubview(sectionLabel(String(localized: "Listening Guide")))
        let guideButton = NSButton(title: String(localized: "Open Listening Guide"), target: self, action: #selector(openGuide))
        guideButton.bezelStyle = .rounded
        formStack.addArrangedSubview(guideButton)
        addFullWidth(explanation(String(localized: "How Bluetooth, AAC, and lossless files really affect what you hear.")))
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
        let center = NotificationCenter.default
        for name in [
            AudioPlayer.trackDidChange, EqualizerEngine.stateDidChange, EqualizerEngine.outputDidChange,
            SongVolumeStore.didChange, Library.didUpdateNotification, EqualizerOutputWatcher.sampleRateDidChange,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func refresh() {
        let path = SignalPathSummary.current()
        signalPath.configure(path)
        renderGuideCards(for: path.outputKind)
        equalizerSummary.stringValue = EqualizerCopy.settingsSummary
        let selected = Set(songVolumesTable.selectedRowIndexes.compactMap { songs.indices.contains($0) ? songs[$0].track.fileURL : nil })
        songs = SongVolumeStore.shared.adjustedSongs(in: Library.shared.allTracks)
        songVolumesSummary.stringValue = songs.isEmpty
            ? String(localized: "Every song plays at its own level")
            : String(localized: "\(songs.count) songs have a volume of their own")
        songVolumesScroll.isHidden = songs.isEmpty
        songVolumesTable.reloadData()
        let kept = IndexSet(songs.indices.filter { selected.contains(songs[$0].track.fileURL) })
        songVolumesTable.selectRowIndexes(kept, byExtendingSelection: false)
        resetAllButton.isEnabled = !songs.isEmpty
        resetButton.isEnabled = !songVolumesTable.selectedRowIndexes.isEmpty
        thisSongButton.isEnabled = AudioPlayer.shared.currentTrack != nil
    }

    private func renderGuideCards(for kind: SignalOutputKind?) {
        guideCards.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for entry in SignalPathSummary.guideCards(for: kind) {
            let button = NSButton(title: " " + entry.card.title, target: self, action: #selector(openGuideCard(_:)))
            button.tag = entry.index
            button.isBordered = false
            button.image = MacSettingsIcon.image(symbol: entry.card.symbolName, tint: .systemCyan, side: 20)
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.contentTintColor = .linkColor
            button.font = .systemFont(ofSize: 13)
            button.setAccessibilityHelp(String(localized: "Opens this card of the Listening Guide"))
            button.setAccessibilityLabel(entry.card.title)
            guideCards.addArrangedSubview(button)
        }
    }

    private func configureSongVolumesTable() {
        let songColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("song"))
        songColumn.title = String(localized: "Song")
        songColumn.width = 380
        let levelColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("level"))
        levelColumn.title = String(localized: "Volume")
        levelColumn.width = 90
        songVolumesTable.addTableColumn(songColumn)
        songVolumesTable.addTableColumn(levelColumn)
        songVolumesTable.dataSource = self
        songVolumesTable.delegate = self
        songVolumesTable.allowsMultipleSelection = true
        songVolumesTable.usesAlternatingRowBackgroundColors = true
        songVolumesTable.rowHeight = 22
        songVolumesTable.setAccessibilityLabel(String(localized: "Song Volumes"))
        songVolumesScroll.documentView = songVolumesTable
        songVolumesScroll.hasVerticalScroller = true
        songVolumesScroll.borderType = .bezelBorder
        songVolumesScroll.heightAnchor.constraint(equalToConstant: 132).isActive = true
    }

    @objc private func openEqualizer() {
        MacEqualizerWindowController.shared.show()
    }

    @objc private func openGuide() {
        ListeningGuideFocus.open(card: nil)
    }

    @objc private func openGuideCard(_ sender: NSButton) {
        ListeningGuideFocus.open(card: sender.tag)
    }

    @objc private func openThisSong() {
        guard let track = AudioPlayer.shared.currentTrack else { return }
        MacSongVolumePresenter.present(for: track, from: thisSongButton)
    }

    @objc private func resetSelected() {
        let tracks = songVolumesTable.selectedRowIndexes.compactMap { songs.indices.contains($0) ? songs[$0].track : nil }
        reset(tracks)
    }

    @objc private func confirmResetAll() {
        guard !songs.isEmpty, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Reset All Song Volumes?")
        alert.informativeText = String(localized: "Every song plays at the level it was mastered at again.")
        alert.addButton(withTitle: String(localized: "Reset All"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.reset(self.songs.map(\.track))
        }
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
        if failed {
            MidgarLog.error("Song volume reset failed for at least one of \(tracks.count) songs", category: .playback)
            MacToast.show(String(localized: "A song volume couldn't be reset. Try again."), style: .error, in: view.window)
        }
        refresh()
    }
}

extension SoundSettingsPane: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        songs.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard songs.indices.contains(row), let column = tableColumn else { return nil }
        let song = songs[row]
        let text: String
        let color: NSColor
        if column.identifier.rawValue == "level" {
            text = SongGain.label(song.tenths)
            color = song.tenths > 0 ? .systemOrange : .secondaryLabelColor
        } else {
            text = "\(song.track.title) — \(song.track.artist)"
            color = .labelColor
        }
        let label = NSTextField(labelWithString: text)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.font = column.identifier.rawValue == "level"
            ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            : .systemFont(ofSize: 12)
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        resetButton.isEnabled = !songVolumesTable.selectedRowIndexes.isEmpty
    }
}
