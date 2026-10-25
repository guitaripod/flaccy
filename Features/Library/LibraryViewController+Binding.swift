import Combine
import MidgarCore
import FlaccyCore
import UIKit
import UniformTypeIdentifiers

extension LibraryViewController {

    func bindViewModel() {
        viewModel.snapshotPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                let segment = self.viewModel.currentSegment
                let filter = self.viewModel.filter
                let layout = self.viewModel.layoutMode
                let segmentChanged = self.lastRenderedSegment != nil && self.lastRenderedSegment != segment
                let filterChanged = self.lastRenderedFilter != nil && self.lastRenderedFilter != filter
                let previousSegment = self.lastRenderedSegment
                self.lastRenderedSegment = segment
                self.lastRenderedFilter = filter
                self.filterChipsView.setSelected(filter, animated: false)
                let useReload = self.shouldReload(
                    snapshot, segmentChanged: segmentChanged, isFirstRender: previousSegment == nil
                )
                self.applyLibrarySnapshot(
                    snapshot,
                    segment: segment,
                    layout: layout,
                    forceLayout: segmentChanged || filterChanged,
                    useReload: useReload
                )
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: LovedTracksService.didChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleLovedChange() }
            .store(in: &cancellables)

        viewModel.loadStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.render(loadState: state) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AlbumArtworkCache.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconfigureVisibleArtwork() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: Library.albumCoversHoisted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in self?.absorbHoistedCovers(notification) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: RemoteAvailability.didChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconfigureVisibleArtwork() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: RemoteSyncStatus.didChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.render(loadState: self.viewModel.currentLoadState)
            }
            .store(in: &cancellables)

        render(loadState: viewModel.currentLoadState, animated: false)
    }

    /// Whether to swap the list wholesale instead of diffing it.
    ///
    /// A full list swap of a large library is far cheaper as a reload than as a
    /// 6 000-item identity diff, but a library refresh keeps its rows — and
    /// during the Debut's second act the AI is retitling albums under a reader
    /// who is scrolling, where a reload would tear the grid down rather than
    /// move the one row that changed.
    func shouldReload(
        _ snapshot: LibraryViewModel.Snapshot, segmentChanged: Bool, isFirstRender: Bool
    ) -> Bool {
        if segmentChanged || isFirstRender { return true }
        guard viewModel.snapshotIntent == .replaceList else { return false }
        return snapshot.numberOfItems > 200
    }

    /// Repaints the artwork of every visible card and row after a cover was
    /// changed, which the cache has already forgotten.
    func reconfigureVisibleArtwork() {
        let affected = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
        guard !affected.isEmpty else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(affected)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Refreshes loved heart indicators when love state changes elsewhere. When
    /// the Favorites pivot is active, membership changes so the list is rebuilt;
    /// otherwise the visible rows are reconfigured in place.
    func handleLovedChange() {
        if viewModel.filter == .favorites {
            viewModel.refilter()
            return
        }
        var snapshot = dataSource.snapshot()
        let affected = collectionView.indexPathsForVisibleItems
            .compactMap { dataSource.itemIdentifier(for: $0) }
            .filter {
                switch $0 {
                case .song, .album, .recentAlbum: return true
                default: return false
                }
            }
        guard !affected.isEmpty else { return }
        snapshot.reconfigureItems(affected)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Builds a leading swipe action that toggles the loved state of the song at
    /// the given index, with a heart-fill title, accent color, and haptic.
    func loveSwipeConfiguration(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath),
              case .song(let track) = item else { return nil }
        let loved = LovedTracksService.shared.isLoved(track: track)
        let action = UIContextualAction(
            style: .normal,
            title: loved ? String(localized: "Unlove") : String(localized: "Love")
        ) { _, _, completion in
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Task {
                await LovedTracksService.shared.toggleLove(track: track)
                await MainActor.run { completion(true) }
            }
        }
        action.image = UIImage(systemName: loved ? "heart.slash.fill" : "heart.fill")
        action.backgroundColor = .systemPink
        return UISwipeActionsConfiguration(actions: [action])
    }
}
