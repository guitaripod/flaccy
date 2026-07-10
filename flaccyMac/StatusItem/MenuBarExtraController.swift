import AppKit

/// The optional menu bar player: a waveform status item whose menu shows the
/// current track (artwork, title, artist), transport and love controls, the
/// sleep timer submenu, and an Open Flaccy shortcut. The menu is rebuilt in
/// menuNeedsUpdate, so nothing polls; observers only refresh the icon.
final class MenuBarExtraController: NSObject, NSMenuDelegate {

    var onOpenApp: (() -> Void)?

    private var statusItem: NSStatusItem?

    func bootstrap() {
        if MenuBarExtraSetting.isEnabled {
            install()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingChanged), name: .flaccyMenuBarExtraSettingChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(playbackChanged), name: AudioPlayer.trackDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(playbackChanged), name: AudioPlayer.playbackStateDidChange, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Flaccy")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        AppLogger.info("Menu bar extra installed", category: .ui)
    }

    private func remove() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        AppLogger.info("Menu bar extra removed", category: .ui)
    }

    @objc private func settingChanged() {
        if MenuBarExtraSetting.isEnabled {
            install()
        } else {
            remove()
        }
    }

    @objc private func playbackChanged() {
        guard let button = statusItem?.button else { return }
        let playing = AudioPlayer.shared.isPlaying
        button.image = NSImage(
            systemSymbolName: playing ? "waveform" : "waveform.slash",
            accessibilityDescription: "Flaccy"
        ) ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "Flaccy")
        if let track = AudioPlayer.shared.currentTrack {
            button.toolTip = "\(track.title) — \(track.artist)"
            AppLogger.debug("Menu bar extra updated: \(track.title)", category: .ui)
        } else {
            button.toolTip = "Flaccy"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let player = AudioPlayer.shared

        if let track = player.currentTrack {
            if let artwork = track.artwork
                ?? AlbumArtworkCache.shared.thumbnail(forAlbum: track.albumTitle, artist: track.artist) {
                let artworkItem = NSMenuItem()
                let resized = NSImage(size: NSSize(width: 96, height: 96), flipped: false) { rect in
                    artwork.draw(in: rect)
                    return true
                }
                artworkItem.image = resized
                artworkItem.title = ""
                artworkItem.isEnabled = false
                menu.addItem(artworkItem)
            }
            let titleItem = menu.addItem(withTitle: track.title, action: nil, keyEquivalent: "")
            titleItem.isEnabled = false
            let artistItem = menu.addItem(withTitle: track.artist, action: nil, keyEquivalent: "")
            artistItem.isEnabled = false
            menu.addItem(.separator())
        } else {
            let idle = menu.addItem(withTitle: "Nothing Playing", action: nil, keyEquivalent: "")
            idle.isEnabled = false
            menu.addItem(.separator())
        }

        let hasQueue = !player.queue.isEmpty
        let playPause = menu.addItem(
            withTitle: player.isPlaying ? "Pause" : "Play",
            action: #selector(togglePlayPause), keyEquivalent: ""
        )
        playPause.target = self
        playPause.isEnabled = hasQueue
        let next = menu.addItem(withTitle: "Next Track", action: #selector(nextTrack), keyEquivalent: "")
        next.target = self
        next.isEnabled = hasQueue
        let previous = menu.addItem(withTitle: "Previous Track", action: #selector(previousTrack), keyEquivalent: "")
        previous.target = self
        previous.isEnabled = hasQueue

        if let track = player.currentTrack {
            let loved = LovedTracksService.shared.isLoved(track: track)
            let love = menu.addItem(
                withTitle: loved ? "Unlove" : "Love", action: #selector(toggleLove), keyEquivalent: ""
            )
            love.target = self
        }

        menu.addItem(.separator())
        let sleepItem = menu.addItem(withTitle: sleepTimerTitle(), action: nil, keyEquivalent: "")
        sleepItem.submenu = SleepTimerMenuBuilder.build()

        menu.addItem(.separator())
        let open = menu.addItem(withTitle: "Open Flaccy", action: #selector(openApp), keyEquivalent: "")
        open.target = self
    }

    private func sleepTimerTitle() -> String {
        if let remaining = AudioPlayer.shared.sleepTimerRemaining {
            let total = Int(remaining)
            return String(format: "Sleep Timer (%d:%02d)", total / 60, total % 60)
        }
        if AudioPlayer.shared.sleepAtEndOfTrack {
            return "Sleep Timer (end of track)"
        }
        return "Sleep Timer"
    }

    @objc private func togglePlayPause() {
        AudioPlayer.shared.togglePlayPause()
    }

    @objc private func nextTrack() {
        AudioPlayer.shared.nextTrack()
    }

    @objc private func previousTrack() {
        AudioPlayer.shared.previousTrack()
    }

    @objc private func toggleLove() {
        guard let track = AudioPlayer.shared.currentTrack else { return }
        Task { _ = await LovedTracksService.shared.toggleLove(track: track) }
    }

    @objc private func openApp() {
        NSApp.activate()
        onOpenApp?()
    }
}
