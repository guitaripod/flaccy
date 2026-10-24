import Combine
import MidgarCore
import FlaccyCore
import UIKit
import UniformTypeIdentifiers

extension LibraryViewController {

    func updateRightBarButton(for segment: LibraryViewModel.Segment) {
        switch segment {
        case .albums:
            navigationItem.rightBarButtonItems = [
                sortButton(menu: albumSortMenu()),
                layoutToggleButton(),
            ]
        case .songs:
            let range = UIBarButtonItem(image: UIImage(systemName: "calendar"), menu: scrobbleRangeMenu())
            range.accessibilityLabel = String(localized: "Play history range")
            navigationItem.rightBarButtonItems = [
                sortButton(menu: songSortMenu()),
                range,
                layoutToggleButton(),
            ]
        case .artists:
            navigationItem.rightBarButtonItem = sortButton(menu: artistSortMenu())
        case .playlists:
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.createPlaylistTapped() }
            )
        }
    }

    func sortButton(menu: UIMenu) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: "arrow.up.arrow.down"), menu: menu)
        item.accessibilityIdentifier = "library.sort"
        return item
    }

    func layoutToggleButton() -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: viewModel.layoutMode.icon),
            primaryAction: UIAction { [weak self] _ in self?.toggleLayoutMode() }
        )
        item.accessibilityLabel = viewModel.layoutMode.accessibilityLabel
        item.accessibilityIdentifier = viewModel.layoutMode.accessibilityIdentifier
        return item
    }

    func toggleLayoutMode() {
        selectionFeedback.selectionChanged()
        viewModel.cycleLayoutMode()
        updateRightBarButton(for: viewModel.currentSegment)
        applyLayoutAndSnapshot(crossfade: true)
    }

    func albumSortMenu() -> UIMenu {
        let actions = LibraryViewModel.AlbumSort.allCases.map { sort -> UIAction in
            let action = UIAction(
                title: sort.displayName,
                image: UIImage(systemName: sort.icon),
                state: viewModel.albumSort == sort ? .on : .off
            ) { [weak self] _ in
                self?.impactLight.impactOccurred()
                self?.viewModel.setAlbumSort(sort)
                self?.updateRightBarButton(for: .albums)
                self?.updateSectionIndex()
                self?.scrollToTopForSortChange()
            }
            action.accessibilityIdentifier = "sort.option.\(sort.rawValue)"
            return action
        }
        return UIMenu(title: String(localized: "Sort By"), image: UIImage(systemName: "arrow.up.arrow.down"), children: actions)
    }

    func songSortMenu() -> UIMenu {
        let actions = LibraryViewModel.SongSort.allCases
            .map { sort -> UIAction in
                let action = UIAction(
                    title: sort.displayName,
                    image: UIImage(systemName: sort.icon),
                    state: viewModel.songSort == sort ? .on : .off
                ) { [weak self] _ in
                    self?.impactLight.impactOccurred()
                    self?.viewModel.setSongSort(sort)
                    self?.updateRightBarButton(for: .songs)
                    self?.updateSectionIndex()
                    self?.scrollToTopForSortChange()
                }
                action.accessibilityIdentifier = "sort.option.\(sort.rawValue)"
                return action
            }
        let sortMenu = UIMenu(title: String(localized: "Sort By"), image: UIImage(systemName: "arrow.up.arrow.down"), children: actions)
        let hideDuplicates = UIAction(
            title: String(localized: "Hide Duplicate Songs"),
            image: UIImage(systemName: "square.on.square"),
            state: HideDuplicateSongsSetting.isEnabled ? .on : .off
        ) { [weak self] _ in
            self?.impactLight.impactOccurred()
            HideDuplicateSongsSetting.set(!HideDuplicateSongsSetting.isEnabled)
            self?.updateRightBarButton(for: .songs)
        }
        return UIMenu(children: [sortMenu, UIMenu(options: .displayInline, children: [hideDuplicates])])
    }

    func scrollToTopForSortChange() {
        collectionView.setContentOffset(
            CGPoint(x: 0, y: -collectionView.adjustedContentInset.top),
            animated: false
        )
    }

    func scrobbleRangeMenu() -> UIMenu {
        let actions = ChartPeriod.allCases.map { period in
            UIAction(
                title: period.displayName,
                state: viewModel.scrobbleRange == period ? .on : .off
            ) { [weak self] _ in
                self?.impactLight.impactOccurred()
                self?.viewModel.setScrobbleRange(period)
                self?.updateRightBarButton(for: .songs)
            }
        }
        return UIMenu(
            title: String(localized: "Plays From"),
            image: UIImage(systemName: "calendar"),
            children: actions
        )
    }

    func artistSortMenu() -> UIMenu {
        let actions = LibraryViewModel.ArtistSort.allCases.map { sort -> UIAction in
            let action = UIAction(
                title: sort.displayName,
                image: UIImage(systemName: sort.icon),
                state: viewModel.artistSort == sort ? .on : .off
            ) { [weak self] _ in
                self?.impactLight.impactOccurred()
                self?.viewModel.setArtistSort(sort)
                self?.updateRightBarButton(for: .artists)
                self?.updateSectionIndex()
                self?.scrollToTopForSortChange()
            }
            action.accessibilityIdentifier = "sort.option.\(sort.rawValue)"
            return action
        }
        return UIMenu(title: String(localized: "Sort By"), image: UIImage(systemName: "arrow.up.arrow.down"), children: actions)
    }
}
