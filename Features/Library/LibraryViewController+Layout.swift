import Combine
import MidgarCore
import FlaccyCore
import UIKit
import UniformTypeIdentifiers

/// The proportions of the Albums carousel on a touch screen.
nonisolated enum CarouselMetrics {
    static let spacing: CGFloat = 14
    static let captionHeight: CGFloat = 64
    static let neighbourScale: CGFloat = 0.82
    static let widthShare: CGFloat = 0.68
    static let largestSide: CGFloat = 420
    static let verticalBias: CGFloat = 0.36

    /// The cover's edge: most of the width, but never taller than the room
    /// left above the mini player.
    static func coverSide(width: CGFloat, height: CGFloat) -> CGFloat {
        max(160, min(width * widthShare, height - captionHeight - 140, largestSide)).rounded()
    }
}

extension LibraryViewController {

    /// A cover-wall section of square art tiles at the given column count,
    /// or split evenly about a fold that runs down the window.
    func gridSection(
        environment: NSCollectionLayoutEnvironment, topInset: CGFloat
    ) -> NSCollectionLayoutSection {
        if let grid = (collectionView as? FoldAwareCollectionView)?.foldGrid(leading: 20, trailing: 12) {
            return .foldGrid(
                grid, spacing: 10, rowSpacing: 12, height: .estimated(180),
                insets: NSDirectionalEdgeInsets(top: topInset, leading: 20, bottom: 24, trailing: 12)
            )
        }
        let columns = AdaptiveLayout.gridColumns(forWidth: environment.container.effectiveContentSize.width)
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0 / CGFloat(columns)),
            heightDimension: .estimated(180)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(180))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, repeatingSubitem: item, count: columns)
        group.interItemSpacing = .fixed(10)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 12
        section.contentInsetsReference = .safeArea
        section.contentInsets = NSDirectionalEdgeInsets(top: topInset, leading: 20, bottom: 24, trailing: 12)
        return section
    }

    /// Covers edge to edge with nothing between them: twice as many columns as
    /// the grid would be wide tiles, each exactly as wide as its column.
    func wallSection(environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let width = environment.container.effectiveContentSize.width
        let columns = max(3, AdaptiveLayout.gridColumns(forWidth: width))
        let side = NSCollectionLayoutDimension.fractionalWidth(1.0 / CGFloat(columns))
        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: side, heightDimension: side))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: side),
            repeatingSubitem: item, count: columns
        )
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 24, trailing: 0)
        return section
    }

    /// One album at a time: a large cover in the middle of the screen that
    /// pages sideways, its neighbours smaller and dimmer on either side.
    func carouselSection(environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let container = environment.container.effectiveContentSize
        let side = CarouselMetrics.coverSide(width: container.width, height: container.height)
        let size = NSCollectionLayoutSize(
            widthDimension: .absolute(side), heightDimension: .absolute(side + CarouselMetrics.captionHeight)
        )
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .groupPagingCentered
        section.interGroupSpacing = CarouselMetrics.spacing
        let top = max(12, (container.height - size.heightDimension.dimension) * CarouselMetrics.verticalBias)
        section.contentInsets = NSDirectionalEdgeInsets(top: top, leading: 0, bottom: 24, trailing: 0)
        section.visibleItemsInvalidationHandler = { items, offset, environment in
            let centre = offset.x + environment.container.contentSize.width / 2
            for item in items {
                let distance = min(abs(item.frame.midX - centre) / (side + CarouselMetrics.spacing), 1)
                let scale = 1 - (1 - CarouselMetrics.neighbourScale) * distance
                item.transform = CGAffineTransform(scaleX: scale, y: scale)
                item.alpha = 1 - (1 - CGFloat(FlowGeometry.neighbourOpacity)) * distance
            }
        }
        return section
    }

    func listLayout(leadingInset: CGFloat, leadingSwipeLove: Bool) -> UICollectionViewCompositionalLayout {
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.showsSeparators = true
        config.backgroundColor = .clear
        if leadingSwipeLove {
            config.leadingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.loveSwipeConfiguration(at: indexPath)
            }
        }
        return UICollectionViewCompositionalLayout { _, environment in
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            section.contentInsetsReference = .safeArea
            section.contentInsets.leading = leadingInset
            return section
        }
    }

    func createLayout(for segment: LibraryViewModel.Segment) -> UICollectionViewCompositionalLayout {
        switch segment {
        case .albums:
            switch viewModel.albumsLayoutMode {
            case .wall:
                return UICollectionViewCompositionalLayout { [weak self] _, environment in
                    self?.wallSection(environment: environment)
                }
            case .carousel:
                return UICollectionViewCompositionalLayout { [weak self] _, environment in
                    self?.carouselSection(environment: environment)
                }
            case .grid:
                return UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
                    guard let self else { return nil }
                    let hasRecent = self.dataSource.snapshot().numberOfSections > 1
                    if sectionIndex == 0 && hasRecent {
                        let itemSize = NSCollectionLayoutSize(widthDimension: .absolute(110), heightDimension: .estimated(160))
                        let item = NSCollectionLayoutItem(layoutSize: itemSize)
                        let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])
                        let section = NSCollectionLayoutSection(group: group)
                        section.orthogonalScrollingBehavior = .continuous
                        section.interGroupSpacing = 10
                        section.contentInsetsReference = .safeArea
                        section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 12)
                        let headerSize = NSCollectionLayoutSize(
                            widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(32)
                        )
                        section.boundarySupplementaryItems = [
                            NSCollectionLayoutBoundarySupplementaryItem(
                                layoutSize: headerSize,
                                elementKind: UICollectionView.elementKindSectionHeader,
                                alignment: .top
                            )
                        ]
                        return section
                    }
                    return self.gridSection(environment: environment, topInset: 12)
                }
            case .list:
                return listLayout(leadingInset: 20, leadingSwipeLove: false)
            case .compact:
                return listLayout(leadingInset: 20, leadingSwipeLove: false)
            }
        case .songs:
            switch viewModel.layoutMode {
            case .grid, .wall, .carousel:
                return UICollectionViewCompositionalLayout { [weak self] _, environment in
                    self?.gridSection(environment: environment, topInset: 12)
                }
            case .list, .compact:
                return listLayout(leadingInset: 20, leadingSwipeLove: true)
            }
        case .artists:
            return listLayout(leadingInset: 20, leadingSwipeLove: false)
        case .playlists:
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.showsSeparators = true
            config.backgroundColor = .clear
            config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                guard let self,
                      let item = self.dataSource.itemIdentifier(for: indexPath),
                      case .playlist(let playlist) = item
                else { return nil }
                let deleteAction = UIContextualAction(style: .destructive, title: String(localized: "Delete")) { _, _, completion in
                    PlaylistCommands.confirmDelete(id: playlist.id, name: playlist.name, from: self) {
                        self.viewModel.refreshPlaylists()
                    }
                    completion(false)
                }
                let coverAction = UIContextualAction(style: .normal, title: String(localized: "Cover")) { _, _, completion in
                    self.impactLight.impactOccurred()
                    self.presentCoverEditor(for: playlist)
                    completion(true)
                }
                coverAction.image = UIImage(systemName: "photo")
                coverAction.backgroundColor = .systemIndigo
                return UISwipeActionsConfiguration(actions: [deleteAction, coverAction])
            }
            return UICollectionViewCompositionalLayout { _, environment in
                let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
                section.contentInsetsReference = .safeArea
                return section
            }
        }
    }
}
