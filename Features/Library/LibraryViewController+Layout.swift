import Combine
import MidgarCore
import FlaccyCore
import UIKit
import UniformTypeIdentifiers

extension LibraryViewController {

    /// A cover-wall section of square art tiles at the given column count.
    func gridSection(
        environment: NSCollectionLayoutEnvironment, topInset: CGFloat
    ) -> NSCollectionLayoutSection {
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
            switch viewModel.layoutMode {
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
                        section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
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
            case .grid:
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
                    do {
                        try DatabaseManager.shared.deletePlaylist(id: playlist.id)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        self.viewModel.refreshPlaylists()
                        completion(true)
                    } catch {
                        MidgarLog.error("Failed to delete playlist: \(error.localizedDescription)", category: .database)
                        ToastView.show(String(localized: "Couldn't delete \u{201C}\(playlist.name)\u{201D} — the library database couldn't be written. Check free disk space and try again."), in: self.view, style: .error)
                        completion(false)
                    }
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
