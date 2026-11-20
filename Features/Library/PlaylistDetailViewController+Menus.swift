import FlaccyCore
import MidgarCore
import UIKit

extension PlaylistDetailViewController {

    /// Select and the More menu while browsing; Select All and Done while
    /// choosing songs. Add Songs sits beside them.
    func updateBarItems() {
        guard isViewLoaded else { return }
        if isEditing {
            let all = dataSource.snapshot().numberOfItems(inSection: .songs)
            let everything = !selectedEntryIds.isEmpty && selectedEntryIds.count == all
            let toggle = UIBarButtonItem(
                title: everything ? PlaylistCopy.deselectAll : PlaylistCopy.selectAll,
                primaryAction: UIAction { [weak self] _ in self?.toggleSelectAll() }
            )
            let done = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
                self?.setEditing(false, animated: true)
            })
            done.accessibilityIdentifier = "playlist.done"
            navigationItem.leftBarButtonItem = toggle
            navigationItem.hidesBackButton = true
            navigationItem.rightBarButtonItems = [done]
            return
        }
        navigationItem.leftBarButtonItem = nil
        navigationItem.hidesBackButton = false
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: moreMenu())
        more.accessibilityLabel = String(localized: "More")
        more.accessibilityIdentifier = "playlist.more"
        let add = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in self?.presentAddSongs() }
        )
        add.accessibilityLabel = PlaylistCopy.addSongs
        add.accessibilityIdentifier = "playlist.addSongs"
        let select = UIBarButtonItem(
            title: PlaylistCopy.select,
            primaryAction: UIAction { [weak self] _ in self?.setEditing(true, animated: true) }
        )
        select.accessibilityIdentifier = "playlist.select"
        select.isEnabled = !rows.isEmpty
        navigationItem.rightBarButtonItems = [more, add, select]
    }

    private func moreMenu() -> UIMenu {
        UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.moreMenuElements() ?? [])
        }])
    }

    private func moreMenuElements() -> [UIMenuElement] {
        var elements: [UIMenuElement] = [
            UIMenu(options: .displayInline, children: Array(PlaylistCommands.playbackActions(id: playlistId, name: playlistName, in: view).dropFirst(2))),
            sortMenu(),
            UIMenu(options: .displayInline, children: [
                UIAction(title: PlaylistCopy.addSongsMenu, image: UIImage(systemName: "plus")) { [weak self] _ in
                    self?.presentAddSongs()
                },
                UIAction(
                    title: PlaylistSuggestionsSetting.isShown ? PlaylistCopy.hideSuggestions : PlaylistCopy.showSuggestions,
                    image: UIImage(systemName: PlaylistSuggestionsSetting.isShown ? "eye.slash" : "sparkles")
                ) { [weak self] _ in
                    self?.selectionFeedback.selectionChanged()
                    PlaylistSuggestionsSetting.setShown(!PlaylistSuggestionsSetting.isShown)
                },
            ]),
        ]
        var cover: [UIMenuElement] = [UIAction(title: String(localized: "Edit Cover…"), image: UIImage(systemName: "photo")) { [weak self] _ in
            self?.presentCoverEditor()
        }]
        if AlbumArtworkEditor.hasCustomCover(coverSubject) {
            cover.append(UIAction(title: String(localized: "Use Automatic Cover"), image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in
                self?.confirmAutomaticCover()
            })
        }
        elements.append(UIMenu(options: .displayInline, children: cover))
        var tidy: [UIMenuElement] = []
        if let download = RemoteDownloadActions.action(for: rows.compactMap(\.track), in: self) { tidy.append(download) }
        let duplicates = duplicateEntryIds()
        if !duplicates.isEmpty {
            tidy.append(UIAction(
                title: String(localized: "Remove \(duplicates.count) Duplicate Songs"), image: UIImage(systemName: "square.on.square")
            ) { [weak self] _ in
                self?.remove(entryIds: duplicates)
            })
        }
        let missing = rows.filter { $0.track == nil }.map(\.entryId)
        if !missing.isEmpty {
            tidy.append(UIAction(
                title: String(localized: "Remove \(missing.count) Missing Songs"), image: UIImage(systemName: "questionmark.square.dashed")
            ) { [weak self] _ in
                self?.remove(entryIds: missing)
            })
        }
        if !tidy.isEmpty { elements.append(UIMenu(options: .displayInline, children: tidy)) }
        elements += PlaylistCommands.manageActions(
            id: playlistId, name: playlistName, from: self,
            renamed: { [weak self] name in self?.showRenamed(name) },
            deleted: { [weak self] in self?.navigationController?.popViewController(animated: true) }
        )
        return elements
    }

    private func sortMenu() -> UIMenu {
        let actions = PlaylistSongOrder.allCases.map { option in
            let action = UIAction(title: option.title, image: UIImage(systemName: option.systemImage)) { [weak self] _ in
                self?.setOrder(option)
            }
            action.state = option == order ? .on : .off
            return action
        }
        let menu = UIMenu(title: PlaylistCopy.sortBy, image: UIImage(systemName: "arrow.up.arrow.down"), children: actions)
        menu.subtitle = order.title
        return menu
    }

    func setOrder(_ newOrder: PlaylistSongOrder) {
        guard newOrder != order else { return }
        order = newOrder
        PlaylistSongOrder.save(newOrder, for: playlistId)
        selectionFeedback.selectionChanged()
        refreshShownRows(animated: true)
        MidgarLog.debug("Playlist order \(newOrder.rawValue)", category: .ui)
    }

    /// Entries that repeat a song an earlier entry already plays, in any
    /// release. The first entry keeps the person's place in the order.
    func duplicateEntryIds() -> [Int64] {
        var seen: [String: [TimeInterval]] = [:]
        var ids: [Int64] = []
        for row in rows {
            guard let track = row.track else { continue }
            let key = LibraryHygiene.songKey(title: track.title, artist: track.artist)
            let tolerance = LibraryHygiene.songDurationTolerance
            if seen[key]?.contains(where: { abs($0 - track.duration) <= tolerance }) == true {
                ids.append(row.entryId)
            } else {
                seen[key, default: []].append(track.duration)
            }
        }
        return ids
    }

    func renameTapped() {
        guard !isEditing else { return }
        PlaylistCommands.promptRename(id: playlistId, name: playlistName, from: self) { [weak self] name in
            self?.showRenamed(name)
        }
    }

    func presentAddSongs() {
        impactLight.impactOccurred()
        let picker = PlaylistAddSongsViewController(playlistId: playlistId, playlistName: playlistName)
        picker.suggestions = suggestions
        let navigation = UINavigationController(rootViewController: picker)
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(navigation, animated: true)
    }
}
