import FlaccyCore
import MidgarCore
import UIKit

/// The playlist page's table source: only songs can be taken out, and only
/// in Playlist Order without a search can they move.
final class PlaylistTableDataSource: UITableViewDiffableDataSource<PlaylistDetailViewController.Section, PlaylistDetailViewController.Item> {

    weak var owner: PlaylistDetailViewController?

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        if case .entry = itemIdentifier(for: indexPath) { return true }
        return false
    }

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        guard case .entry = itemIdentifier(for: indexPath) else { return false }
        return owner?.allowsReordering == true
    }

    override func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        owner?.moveRow(from: sourceIndexPath.row, to: destinationIndexPath.row)
    }
}

extension PlaylistDetailViewController {

    /// A row dragged from `source` to `destination` in Playlist Order: the
    /// page takes the new order at once and the database follows in one
    /// commit; its observation then finds nothing left to change.
    func moveRow(from source: Int, to destination: Int) {
        guard allowsReordering, source != destination, rows.indices.contains(source) else { return }
        let ids = rows.map(\.entryId)
        let previous = rows
        let moved = PlaylistEditing.moved(
            ids, moving: [ids[source]], to: PlaylistEditing.insertionIndex(movingRowFrom: source, to: destination)
        )
        rows = moved.compactMap { rowsById[$0] }
        shownRows = rows
        applySnapshot(animated: false)
        impactLight.impactOccurred()
        do {
            try db.reorderPlaylist(playlistId: playlistId, orderedEntryIDs: moved)
            registerUndo(name: String(localized: "Move Song")) { controller in
                try? controller.db.reorderPlaylist(playlistId: controller.playlistId, orderedEntryIDs: ids)
            }
        } catch {
            rows = previous
            shownRows = previous
            applySnapshot(animated: true)
            writeFailed(error)
        }
    }

    /// Takes entries out in one commit and offers Undo, which puts each song
    /// back where it stood.
    func remove(entryIds: [Int64]) {
        guard !entryIds.isEmpty else { return }
        let titles = entryIds.compactMap { rowsById[$0]?.track?.title }
        do {
            let removed = try db.removePlaylistEntries(ids: entryIds, fromPlaylist: playlistId)
            let gone = Set(entryIds)
            rows.removeAll { gone.contains($0.entryId) }
            shownRows.removeAll { gone.contains($0.entryId) }
            applySnapshot(animated: true)
            updateHeaderText()
            updateEmptyFooter()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            let message = removed.count == 1 && titles.count == 1 ? PlaylistCopy.removedOne(titles[0]) : PlaylistCopy.removed(removed.count)
            let pending = PendingRestore(removed)
            ToastView.showAction(message, actionTitle: PlaylistCopy.undo, in: view, style: .success) { [weak self] in
                self?.restore(pending)
            }
            registerUndo(name: PlaylistCopy.removeFromPlaylist) { controller in
                controller.restore(pending)
            }
            UIAccessibility.post(notification: .announcement, argument: message)
        } catch {
            writeFailed(error)
        }
    }

    /// Puts a removal back once, whichever of the toast's Undo and the undo
    /// manager asks first.
    func restore(_ pending: PendingRestore) {
        guard !pending.isDone else { return }
        pending.isDone = true
        do {
            try db.restorePlaylistEntries(pending.removed, toPlaylist: playlistId)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            writeFailed(error)
        }
    }

    private func registerUndo(name: String, _ handler: @escaping (PlaylistDetailViewController) -> Void) {
        undoManager?.registerUndo(withTarget: self, handler: handler)
        undoManager?.setActionName(name)
    }

    func writeFailed(_ error: Error) {
        MidgarLog.error("A playlist edit failed: \(error.localizedDescription)", category: .database)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        ToastView.show(PlaylistCopy.writeFailed(playlistName), in: view, style: .error)
    }

    /// VoiceOver's way to move a song and take it out without a drag.
    func accessibilityActions(for row: Row) -> [UIAccessibilityCustomAction] {
        var actions: [UIAccessibilityCustomAction] = []
        if allowsReordering, let index = rows.firstIndex(of: row) {
            if index > 0 {
                actions.append(UIAccessibilityCustomAction(name: String(localized: "Move Up")) { [weak self] _ in
                    self?.moveRow(from: index, to: index - 1)
                    return true
                })
            }
            if index < rows.count - 1 {
                actions.append(UIAccessibilityCustomAction(name: String(localized: "Move Down")) { [weak self] _ in
                    self?.moveRow(from: index, to: index + 1)
                    return true
                })
            }
        }
        actions.append(UIAccessibilityCustomAction(name: PlaylistCopy.removeFromPlaylist) { [weak self] _ in
            self?.remove(entryIds: [row.entryId])
            return true
        })
        return actions
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView.setEditing(editing, animated: animated)
        if editing {
            selectionFeedback.selectionChanged()
            searchController.isActive = false
        }
        showSelectionBar(editing, animated: animated)
        applySnapshot(animated: animated)
        updateBarItems()
        updateSelectionToolbar()
        if !editing {
            navigationItem.title = nil
            updateTitleVisibility()
            reloadSuggestionsIfPlaylistChanged()
        }
    }

    var selectedEntryIds: [Int64] {
        (tableView.indexPathsForSelectedRows ?? []).sorted().compactMap { indexPath in
            guard case .entry(let id) = dataSource.itemIdentifier(for: indexPath) else { return nil }
            return id
        }
    }

    var selectedTracks: [Track] { selectedEntryIds.compactMap { rowsById[$0]?.track } }

    /// Slides the selection bar up over the bottom of the page, or away, and
    /// keeps the last rows clear of it.
    private func showSelectionBar(_ shown: Bool, animated: Bool) {
        if shown, selectionBar.superview == nil {
            selectionBar.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(selectionBar)
            NSLayoutConstraint.activate([
                selectionBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
                selectionBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
                selectionBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            ])
            selectionBar.removeButton.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.remove(entryIds: self.selectedEntryIds)
                self.updateSelectionToolbar()
            }, for: .touchUpInside)
            view.layoutIfNeeded()
        }
        let offscreen = CGAffineTransform(translationX: 0, y: 120)
        if shown {
            selectionBar.isHidden = false
            selectionBar.alpha = 0
            selectionBar.transform = offscreen
        }
        let changes = {
            self.selectionBar.alpha = shown ? 1 : 0
            self.selectionBar.transform = shown ? .identity : offscreen
            self.tableView.contentInset.bottom = shown ? self.selectionBar.bounds.height + 16 : 0
        }
        let done: (Bool) -> Void = { _ in
            if !shown { self.selectionBar.isHidden = true }
        }
        if animated, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(springDuration: 0.4, bounce: 0.15, animations: changes, completion: done)
        } else {
            changes()
            done(true)
        }
    }

    /// The selection bar's buttons and the title follow the chosen songs.
    func updateSelectionToolbar() {
        guard isEditing else { return }
        let count = selectedEntryIds.count
        navigationItem.title = count == 0 ? PlaylistCopy.select : PlaylistCopy.selected(count)
        selectionBar.queueButton.menu = UIMenu(children: [
            UIAction(title: String(localized: "Play Next"), image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")) { [weak self] _ in
                self?.queueSelection(next: true)
            },
            UIAction(title: String(localized: "Add to Queue"), image: UIImage(systemName: "text.append")) { [weak self] _ in
                self?.queueSelection(next: false)
            },
        ])
        selectionBar.addButton.menu = PlaylistWriter.addMenu(for: { [weak self] in self?.selectedTracks ?? [] }, in: self)
        selectionBar.setEnabled(hasSongs: count > 0, hasPlayable: !selectedTracks.isEmpty)
    }

    private func queueSelection(next: Bool) {
        let tracks = selectedTracks
        guard !tracks.isEmpty else { return }
        if next {
            for track in tracks.reversed() { audioPlayer.insertNext(track) }
        } else {
            for track in tracks { audioPlayer.addToQueue(track) }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        ToastView.show(next ? String(localized: "Playing next") : String(localized: "Added to queue"), in: view, style: .success)
        setEditing(false, animated: true)
    }

    func toggleSelectAll() {
        let all = dataSource.snapshot().itemIdentifiers(inSection: .songs).compactMap { dataSource.indexPath(for: $0) }
        let everything = Set(tableView.indexPathsForSelectedRows ?? []).isSuperset(of: all) && !all.isEmpty
        for indexPath in all {
            if everything {
                tableView.deselectRow(at: indexPath, animated: false)
            } else {
                tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
            }
        }
        selectionFeedback.selectionChanged()
        updateSelectionToolbar()
        updateBarItems()
    }

    override var keyCommands: [UIKeyCommand]? {
        guard isEditing else { return nil }
        let delete = UIKeyCommand(
            title: PlaylistCopy.removeFromPlaylist, action: #selector(removeSelectionByKey), input: "\u{8}", modifierFlags: []
        )
        delete.wantsPriorityOverSystemBehavior = true
        return [delete]
    }

    @objc private func removeSelectionByKey() {
        guard !selectedEntryIds.isEmpty else { return }
        remove(entryIds: selectedEntryIds)
        updateSelectionToolbar()
    }
}

extension PlaylistDetailViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        if isEditing {
            guard case .entry = item else {
                tableView.deselectRow(at: indexPath, animated: false)
                return
            }
            selectionFeedback.selectionChanged()
            updateSelectionToolbar()
            updateBarItems()
            return
        }
        tableView.deselectRow(at: indexPath, animated: true)
        switch item {
        case .entry(let id):
            guard let row = rowsById[id], row.track != nil else {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                return
            }
            play(from: row)
        case .suggestion(let key):
            guard let track = suggestions.first(where: { Self.suggestionKey($0) == key }) else { return }
            addSuggestion(track)
        }
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        guard isEditing else { return }
        selectionFeedback.selectionChanged()
        updateSelectionToolbar()
        updateBarItems()
    }

    func tableView(_ tableView: UITableView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
        if case .entry = dataSource.itemIdentifier(for: indexPath) { return true }
        return false
    }

    func tableView(_ tableView: UITableView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
        if !isEditing { setEditing(true, animated: true) }
    }

    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        tableView.isEditing ? .none : .delete
    }

    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        false
    }

    func tableView(
        _ tableView: UITableView, targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath,
        toProposedIndexPath proposedDestinationIndexPath: IndexPath
    ) -> IndexPath {
        let songs = dataSource.snapshot().numberOfItems(inSection: .songs)
        let target = proposedDestinationIndexPath.section == 0
            ? proposedDestinationIndexPath
            : IndexPath(row: max(songs - 1, 0), section: 0)
        if target != sourceIndexPath { selectionFeedback.selectionChanged() }
        return target
    }

    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !isEditing, case .entry(let id) = dataSource.itemIdentifier(for: indexPath), let track = rowsById[id]?.track else {
            return nil
        }
        let next = UIContextualAction(style: .normal, title: String(localized: "Play Next")) { [weak self] _, _, done in
            self?.audioPlayer.insertNext(track)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            done(true)
        }
        next.image = UIImage(systemName: "text.line.first.and.arrowtriangle.forward")
        next.backgroundColor = .systemIndigo
        let later = UIContextualAction(style: .normal, title: String(localized: "Add to Queue")) { [weak self] _, _, done in
            self?.audioPlayer.addToQueue(track)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            done(true)
        }
        later.image = UIImage(systemName: "text.append")
        later.backgroundColor = .systemOrange
        return UISwipeActionsConfiguration(actions: [next, later])
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !isEditing, case .entry(let id) = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let remove = UIContextualAction(style: .destructive, title: String(localized: "Remove")) { [weak self] _, _, done in
            self?.remove(entryIds: [id])
            done(true)
        }
        remove.image = UIImage(systemName: "minus.circle")
        let configuration = UISwipeActionsConfiguration(actions: [remove])
        configuration.performsFirstActionWithFullSwipe = true
        return configuration
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard !isEditing, let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
        switch item {
        case .entry(let id):
            guard let row = rowsById[id] else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                self?.entryMenu(for: row)
            }
        case .suggestion(let key):
            guard let track = suggestions.first(where: { Self.suggestionKey($0) == key }) else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                guard let self else { return nil }
                let add = UIAction(title: PlaylistCopy.addSuggestion(track.title), image: UIImage(systemName: "plus.circle")) { [weak self] _ in
                    self?.addSuggestion(track)
                }
                return TrackContextMenu.build(
                    for: track, in: self,
                    push: { [weak self] in self?.navigationController?.pushViewController($0, animated: true) },
                    context: TrackContextMenu.Context(extraSections: [UIMenu(options: .displayInline, children: [add])])
                )
            }
        }
    }

    private func entryMenu(for row: Row) -> UIMenu? {
        var section: [UIMenuElement] = []
        if allowsReordering, let index = rows.firstIndex(of: row) {
            if index > 0 {
                section.append(UIAction(title: String(localized: "Move to Top"), image: UIImage(systemName: "arrow.up.to.line")) { [weak self] _ in
                    self?.moveRow(from: index, to: 0)
                })
            }
            if index < rows.count - 1 {
                section.append(UIAction(title: String(localized: "Move to Bottom"), image: UIImage(systemName: "arrow.down.to.line")) { [weak self] _ in
                    guard let self else { return }
                    self.moveRow(from: index, to: self.rows.count - 1)
                })
            }
        }
        section.append(UIAction(
            title: PlaylistCopy.removeFromPlaylist, image: UIImage(systemName: "minus.circle"), attributes: .destructive
        ) { [weak self] _ in
            self?.remove(entryIds: [row.entryId])
        })
        let extra = UIMenu(options: .displayInline, children: section)
        guard let track = row.track else { return UIMenu(children: [extra]) }
        return TrackContextMenu.build(
            for: track, in: self,
            push: { [weak self] in self?.navigationController?.pushViewController($0, animated: true) },
            context: TrackContextMenu.Context(extraSections: [extra])
        )
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateTitleVisibility()
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard dataSource.snapshot().sectionIdentifiers[safe: section] == .suggestions,
              let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: PlaylistSuggestionsHeaderView.reuseID)
                as? PlaylistSuggestionsHeaderView else { return nil }
        header.onRefresh = { [weak self] in self?.refreshSuggestions() }
        header.onHide = { [weak self] in self?.hideSuggestions() }
        return header
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        dataSource.snapshot().sectionIdentifiers[safe: section] == .suggestions ? UITableView.automaticDimension : 0
    }
}

extension PlaylistDetailViewController: UITableViewDragDelegate, UITableViewDropDelegate {

    /// A song lifts to be moved in Playlist Order, or on an iPad to be dropped
    /// into Up Next or another playlist; a sorted or searched list on an
    /// iPhone has nowhere for it to go.
    func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        guard case .entry(let id) = dataSource.itemIdentifier(for: indexPath), let row = rowsById[id] else { return [] }
        guard allowsReordering || DeviceKind.isPad else { return [] }
        session.localContext = self
        guard let track = row.track else {
            return allowsReordering ? [UIDragItem(itemProvider: NSItemProvider())] : []
        }
        return TrackDrag.items(for: [track], named: track.title)
    }

    func tableView(_ tableView: UITableView, dragSessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool {
        !DeviceKind.isPad
    }

    func tableView(_ tableView: UITableView, canHandle session: UIDropSession) -> Bool {
        isOwnDrag(session) || TrackDrag.carriesTracks(session)
    }

    func tableView(
        _ tableView: UITableView, dropSessionDidUpdate session: UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UITableViewDropProposal {
        if isOwnDrag(session) {
            guard allowsReordering, destinationIndexPath?.section ?? 0 == 0 else { return UITableViewDropProposal(operation: .forbidden) }
            return UITableViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
        }
        guard TrackDrag.carriesTracks(session) else { return UITableViewDropProposal(operation: .cancel) }
        return UITableViewDropProposal(operation: .copy, intent: allowsReordering ? .insertAtDestinationIndexPath : .unspecified)
    }

    func tableView(_ tableView: UITableView, performDropWith coordinator: UITableViewDropCoordinator) {
        guard !isOwnDrag(coordinator.session) else { return }
        let tracks = TrackDrag.tracks(in: coordinator.session)
        let destination = coordinator.destinationIndexPath.map { $0.section == 0 ? $0.row : rows.count }
        insert(tracks, at: allowsReordering ? destination : nil)
    }

    /// Adds songs the playlist does not hold yet and, when a place was given,
    /// moves them there in the same breath.
    func insert(_ tracks: [Track], at position: Int?) {
        let before = Set(rows.map(\.entryId))
        guard let addition = PlaylistWriter.add(tracks, toPlaylist: playlistId, named: playlistName, in: view),
              !addition.added.isEmpty, let position else { return }
        let entries = (try? db.fetchPlaylistTracks(playlistId: playlistId)) ?? []
        let ids = entries.compactMap(\.id)
        let fresh = Set(ids.filter { !before.contains($0) })
        let order = PlaylistEditing.moved(ids, moving: fresh, to: min(position, ids.count))
        do {
            try db.reorderPlaylist(playlistId: playlistId, orderedEntryIDs: order)
        } catch {
            writeFailed(error)
        }
    }

    private func isOwnDrag(_ session: UIDropSession) -> Bool {
        session.localDragSession?.localContext as AnyObject? === self
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
