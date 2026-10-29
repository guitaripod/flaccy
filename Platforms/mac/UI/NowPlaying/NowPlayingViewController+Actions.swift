import AppKit
import MidgarCore
import AVFoundation
import AVKit
import Combine

extension NowPlayingViewController {

    func prefetchLyrics() {
        guard let track = player.currentTrack else { return }
        LyricsService.shared.prefetch(
            track: track.title, artist: track.artist, album: track.albumTitle,
            fileURL: track.fileURL, duration: track.duration
        )
    }

    func chaseSeek(to time: TimeInterval) {
        guard !chaseInFlight else {
            pendingChaseTime = time
            return
        }
        chaseInFlight = true
        let generation = chaseGeneration
        let target = CMTime(seconds: time, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.12, preferredTimescale: 600)
        player.seekSmooth(to: target, tolerance: tolerance) { [weak self] in
            guard let self else { return }
            self.chaseInFlight = false
            guard generation == self.chaseGeneration, let pending = self.pendingChaseTime else { return }
            self.pendingChaseTime = nil
            self.chaseSeek(to: pending)
        }
    }

    func showSleepMenu(from button: NSView) {
        let menu = SleepTimerMenuBuilder.build()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    func shareCurrentTrack(from button: NSView) {
        guard let track = player.currentTrack else { return }
        let menu = NSMenu()
        let share = menu.addItem(withTitle: String(localized: "Share via Songlink…"), action: #selector(shareSonglink(_:)), keyEquivalent: "")
        share.target = self
        share.representedObject = button
        let copy = menu.addItem(withTitle: String(localized: "Copy Songlink URL"), action: #selector(copySonglink(_:)), keyEquivalent: "")
        copy.target = self
        if LyricsService.shared.cachedLyrics(track: track.title, artist: track.artist) != nil {
            let lyrics = menu.addItem(withTitle: LyricShareCopy.menuTitle, action: #selector(shareLyrics(_:)), keyEquivalent: "")
            lyrics.target = self
        }
        menu.addItem(.separator())
        let info = menu.addItem(withTitle: "\(track.title) — \(track.artist)", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc func shareSonglink(_ sender: NSMenuItem) {
        guard let track = player.currentTrack else { return }
        let anchor = (sender.representedObject as? NSView) ?? shareCapsule
        Task { [weak self] in
            let outcome = await SonglinkService.shared.lookup(title: track.title, artist: track.artist)
            guard let result = outcome.result else {
                if let message = outcome.failureMessage(title: track.title) {
                    MacToast.show(message, style: .error, in: self?.view.window)
                }
                return
            }
            guard self != nil, let anchor else { return }
            let picker = NSSharingServicePicker(items: [
                String(localized: "\(result.title) by \(result.artist)"), result.pageURL,
            ])
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
    }

    @objc func shareLyrics(_ sender: NSMenuItem) {
        guard let session = LyricShareSession.forCurrentTrack() else {
            MacToast.show(LyricShareCopy.nothingToShare, style: .error, in: view.window)
            return
        }
        LyricShareWindowController.present(session, from: view.window)
    }

    @objc func copySonglink(_ sender: NSMenuItem) {
        guard let track = player.currentTrack else { return }
        Task { [weak self] in
            let outcome = await SonglinkService.shared.lookup(title: track.title, artist: track.artist)
            guard let result = outcome.result else {
                if let message = outcome.failureMessage(title: track.title) {
                    MacToast.show(message, style: .error, in: self?.view.window)
                }
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.pageURL.absoluteString, forType: .string)
            MacToast.show(String(localized: "Songlink copied"), style: .success, in: self?.view.window)
        }
    }

    @objc func artistTapped() {
        guard let track = player.currentTrack else { return }
        LibraryNavigator.revealArtist(LibraryHygiene.primaryArtist(track.artist))
        closeTapped()
    }

    @objc func closeTapped() {
        onClose?()
    }

    @objc func togglePlayPause() { player.togglePlayPause() }
    @objc func nextTrack() { player.nextTrack() }
    @objc func previousTrack() { player.previousTrack() }
    @objc func toggleShuffle() { player.toggleShuffle() }
    @objc func cycleRepeat() { player.cycleRepeatMode() }

    @objc func skipBackFifteen() {
        player.seek(to: max(0, player.currentTime - 15))
    }

    @objc func skipForwardFifteen() {
        player.seek(to: min(player.duration, player.currentTime + 15))
    }

    @objc func toggleLove() {
        guard let track = player.currentTrack else { return }
        Task { _ = await LovedTracksService.shared.toggleLove(track: track) }
    }

    @objc func modesChanged() {
        shuffleButton.isActiveToggle = player.shuffleEnabled
        repeatButton.isActiveToggle = player.repeatMode != .off
        repeatButton.setSymbol(player.repeatMode == .one ? "repeat.1" : "repeat", pointSize: 15)
    }

    @objc func lovedChanged() {
        guard let track = player.currentTrack else {
            loveButton.setSymbol("heart", pointSize: 16)
            return
        }
        let loved = LovedTracksService.shared.isLoved(track: track)
        loveButton.setSymbol(loved ? "heart.fill" : "heart", pointSize: 16)
        loveButton.contentTintColor = loved
            ? NSColor(red: 1.0, green: 0.28, blue: 0.42, alpha: 1)
            : .secondaryLabelColor
    }

    @objc func sleepTimerChanged() {
        if let remaining = player.sleepTimerRemaining {
            let total = Int(remaining)
            sleepCapsule.title = String(format: "%d:%02d", total / 60, total % 60)
            sleepCapsule.isActiveToggle = true
        } else if player.sleepAtEndOfTrack {
            sleepCapsule.title = String(localized: "End of track")
            sleepCapsule.isActiveToggle = true
        } else {
            sleepCapsule.title = String(localized: "Sleep")
            sleepCapsule.isActiveToggle = false
        }
    }
}
