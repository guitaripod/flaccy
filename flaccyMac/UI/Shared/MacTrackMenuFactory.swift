import AppKit

/// Builds the canonical right-click menus for tracks and albums so every
/// surface — grid, songs table, details, playlists — offers the identical
/// action set, mirroring the iOS TrackContextMenu vocabulary.
enum MacTrackMenuFactory {

    struct TrackOptions {
        var includePlay = true
        var includeGoToAlbum = true
        var includeGoToArtist = true
        var includeDelete = true
        var removeFromPlaylist: (() -> Void)?

        init() {}
    }

    static func menu(for track: Track, anchor: NSView?, options: TrackOptions = TrackOptions()) -> NSMenu {
        let menu = NSMenu()
        let window = anchor?.window

        if let badge = track.qualityBadge {
            menu.addItem(disabledHeader(badge))
            menu.addItem(.separator())
        }

        if options.includePlay {
            menu.addItem(ClosureMenuItem(title: "Play", systemImage: "play.fill") {
                AudioPlayer.shared.play([track], startingAt: 0)
            })
        }
        menu.addItem(ClosureMenuItem(title: "Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
            AudioPlayer.shared.insertNext(track)
            MacToast.show("Playing next", style: .success, in: window)
        })
        menu.addItem(ClosureMenuItem(title: "Add to Queue", systemImage: "text.append") {
            AudioPlayer.shared.addToQueue(track)
            MacToast.show("Added to queue", style: .success, in: window)
        })
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(title: "Start Station", systemImage: "dot.radiowaves.left.and.right") {
            AudioPlayer.shared.startStation(seedTrack: track)
            MacToast.show("Station started from \u{201C}\(track.title)\u{201D}", style: .success, in: window)
        })
        let loved = LovedTracksService.shared.isLoved(track: track)
        menu.addItem(ClosureMenuItem(
            title: loved ? "Unlove" : "Love",
            systemImage: loved ? "heart.slash" : "heart"
        ) {
            Task { _ = await LovedTracksService.shared.toggleLove(track: track) }
        })

        let playlistItem = NSMenuItem(title: "Add to Playlist", action: nil, keyEquivalent: "")
        playlistItem.image = NSImage(systemSymbolName: "music.note.list", accessibilityDescription: nil)
        playlistItem.submenu = PlaylistActions.addToPlaylistSubmenu(for: [track], in: window)
        menu.addItem(playlistItem)
        menu.addItem(.separator())

        if options.includeGoToAlbum {
            menu.addItem(ClosureMenuItem(title: "Go to Album", systemImage: "square.stack") {
                LibraryNavigator.revealAlbum(title: track.albumTitle, artist: track.artist)
            })
        }
        if options.includeGoToArtist {
            menu.addItem(ClosureMenuItem(title: "Go to Artist", systemImage: "music.microphone") {
                LibraryNavigator.revealArtist(LibraryHygiene.primaryArtist(track.artist))
            })
        }
        menu.addItem(ClosureMenuItem(title: "View Lyrics", systemImage: "quote.bubble") {
            NotificationCenter.default.post(name: .flaccyToggleLyrics, object: nil)
        })
        menu.addItem(.separator())

        menu.addItem(shareSubmenuItem(
            subject: .track(title: track.title, artist: track.artist), anchor: anchor
        ))
        menu.addItem(ClosureMenuItem(title: "Show in Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([track.fileURL])
        })

        if let removeFromPlaylist = options.removeFromPlaylist {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Remove from Playlist", systemImage: "minus.circle") {
                removeFromPlaylist()
            })
        }
        if options.includeDelete {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(
                title: LibraryRoot.shared.isUsingDefaultRoot ? "Move to Trash…" : "Remove from Library…",
                systemImage: "trash"
            ) {
                TrackDeletion.confirmAndDelete([track], in: window)
            })
        }
        return menu
    }

    static func menu(for album: Album, anchor: NSView?, includeViewAlbum: Bool = true) -> NSMenu {
        let menu = NSMenu()
        let window = anchor?.window

        if let summary = DetailChip.albumQualitySummary(tracks: album.tracks) {
            menu.addItem(disabledHeader(summary))
            menu.addItem(.separator())
        }

        if includeViewAlbum {
            menu.addItem(ClosureMenuItem(title: "View Album", systemImage: "square.stack") {
                LibraryNavigator.revealAlbum(title: album.title, artist: album.artist)
            })
            menu.addItem(.separator())
        }

        menu.addItem(ClosureMenuItem(title: "Play", systemImage: "play.fill") {
            AudioPlayer.shared.play(album.tracks, startingAt: 0)
        })
        menu.addItem(ClosureMenuItem(title: "Shuffle", systemImage: "shuffle") {
            AudioPlayer.shared.play(album.tracks.shuffled(), startingAt: 0)
        })
        menu.addItem(ClosureMenuItem(title: "Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
            for track in album.tracks.reversed() {
                AudioPlayer.shared.insertNext(track)
            }
            MacToast.show("Playing \u{201C}\(album.title)\u{201D} next", style: .success, in: window)
        })
        menu.addItem(ClosureMenuItem(title: "Add to Queue", systemImage: "text.append") {
            for track in album.tracks {
                AudioPlayer.shared.addToQueue(track)
            }
            MacToast.show("Added \u{201C}\(album.title)\u{201D} to queue", style: .success, in: window)
        })
        menu.addItem(.separator())

        let playlistItem = NSMenuItem(title: "Add to Playlist", action: nil, keyEquivalent: "")
        playlistItem.image = NSImage(systemSymbolName: "music.note.list", accessibilityDescription: nil)
        playlistItem.submenu = PlaylistActions.addToPlaylistSubmenu(for: album.tracks, in: window)
        menu.addItem(playlistItem)
        menu.addItem(.separator())

        menu.addItem(shareSubmenuItem(
            subject: .album(title: album.title, artist: album.artist), anchor: anchor
        ))
        menu.addItem(ClosureMenuItem(title: "Enrich Metadata", systemImage: "sparkles") {
            enrichAlbum(album, in: window)
        })
        return menu
    }

    private static func shareSubmenuItem(subject: MacSonglinkSharing.Subject, anchor: NSView?) -> NSMenuItem {
        let share = NSMenu()
        share.addItem(ClosureMenuItem(title: "Share Songlink…", systemImage: "square.and.arrow.up") { [weak anchor] in
            MacSonglinkSharing.share(subject, from: anchor)
        })
        share.addItem(ClosureMenuItem(title: "Copy Songlink", systemImage: "link") { [weak anchor] in
            MacSonglinkSharing.copyLink(subject, from: anchor)
        })
        let item = NSMenuItem(title: "Share", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        item.submenu = share
        return item
    }

    private static func enrichAlbum(_ album: Album, in window: NSWindow?) {
        MacToast.show("Enriching \u{201C}\(album.title)\u{201D}…", style: .info, in: window)
        Task {
            let result = await MetadataEnrichmentService.shared.enrichAlbum(
                title: album.title, artist: album.artist
            )
            do {
                var info = try DatabaseManager.shared.fetchOrCreateAlbumInfo(
                    title: album.title, artist: album.artist
                )
                info.coverArtURL = result.coverArtURL ?? info.coverArtURL
                info.coverArtData = result.coverArtData ?? info.coverArtData
                info.musicBrainzID = result.musicBrainzID ?? info.musicBrainzID
                info.year = result.year ?? info.year
                info.genre = result.genre ?? info.genre
                info.lastFetched = Date()
                try DatabaseManager.shared.updateAlbumInfo(info)

                if let bio = result.artistBio {
                    var artist = try DatabaseManager.shared.fetchOrCreateArtist(name: album.artist)
                    artist.bio = bio
                    artist.imageURL = result.artistImageURL ?? artist.imageURL
                    artist.musicBrainzID = result.artistMusicBrainzID ?? artist.musicBrainzID
                    artist.lastFetched = Date()
                    try DatabaseManager.shared.updateArtist(artist)
                }
                await Library.shared.reload()
                let foundAnything = result.coverArtData != nil || result.year != nil || result.genre != nil
                MacToast.show(
                    foundAnything ? "Metadata updated" : "No new metadata found",
                    style: foundAnything ? .success : .info, in: window
                )
            } catch {
                AppLogger.error("Manual enrichment failed: \(error.localizedDescription)", category: .database)
                MacToast.show("Couldn't update metadata.", style: .error, in: window)
            }
        }
    }

    private static func disabledHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

/// Removal flow shared by the songs table, details, and menus: files under the
/// managed default root are trashed silently on confirm; user-chosen folders
/// get an explicit warning because Flaccy indexes them in place.
enum TrackDeletion {

    static func confirmAndDelete(_ tracks: [Track], in window: NSWindow?) {
        guard !tracks.isEmpty else { return }
        let usingDefaultRoot = LibraryRoot.shared.isUsingDefaultRoot
        let subject = tracks.count == 1
            ? "\u{201C}\(tracks[0].title)\u{201D}"
            : "\(tracks.count) songs"

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move \(subject) to the Trash?"
        alert.informativeText = usingDefaultRoot
            ? "The audio file\(tracks.count == 1 ? "" : "s") will be moved to the Trash and removed from your library."
            : "Flaccy indexes your music folder in place, so removing from the library moves the original file\(tracks.count == 1 ? "" : "s") to the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")

        let respond: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            performDeletion(tracks, in: window)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    private static func performDeletion(_ tracks: [Track], in window: NSWindow?) {
        var trashed = 0
        for track in tracks {
            do {
                try FileManager.default.trashItem(at: track.fileURL, resultingItemURL: nil)
                trashed += 1
            } catch {
                AppLogger.error(
                    "Trash failed for \(track.fileURL.lastPathComponent): \(error.localizedDescription)",
                    category: .content
                )
            }
        }
        AudioPlayer.shared.handleDeletedTracks(Set(tracks.map(\.fileURL)))
        AppLogger.info("Moved \(trashed) track(s) to Trash", category: .content)
        MacToast.show(
            trashed == tracks.count
                ? "Moved to Trash"
                : "Removed \(trashed) of \(tracks.count) — see log",
            style: trashed == tracks.count ? .success : .error,
            in: window
        )
        Task { await Library.shared.reload() }
    }
}
