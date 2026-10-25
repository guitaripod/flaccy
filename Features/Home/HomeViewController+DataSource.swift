import FlaccyCore
import UIKit

extension HomeViewController {

    func setupDataSource() {
        let hero = UICollectionView.CellRegistration<HomeHeroCell, HomeItem> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.onAction = { [weak self] action in self?.handle(hero: action) }
            cell.configure(with: self.model)
        }
        let empty = UICollectionView.CellRegistration<HomeEmptyCell, HomeItem> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.onAction = { [weak self] action in self?.handle(empty: action) }
            self.library.applySampleButtonState()
            cell.configure(sample: self.library.sampleMusicButton.configuration)
        }
        let banner = UICollectionView.CellRegistration<HomeBannerCell, HomeItem> { [weak self] cell, _, item in
            guard let self else { return }
            cell.host(item == .runwayBanner ? self.runwayBannerView : self.statusBannerView)
        }
        let jump = UICollectionView.CellRegistration<HomeJumpTileCell, HomeFeed.Item> { cell, _, item in
            cell.configure(with: item)
        }
        let mix = UICollectionView.CellRegistration<HomeMixCardCell, HomeItem> { [weak self] cell, _, item in
            guard let self else { return }
            switch item {
            case .mix(let id):
                guard let mix = self.model.feed.mixes.first(where: { $0.id == id }) else { return }
                cell.configure(mix: mix, covers: self.model.mixCovers[id] ?? [])
                cell.onPlay = { [weak self] in self?.play(mix: mix, shuffled: false) }
            case .libraryRadio:
                cell.configureRadio()
                cell.onPlay = { AudioPlayer.shared.playLibraryRadio() }
            default:
                cell.configurePlaceholder()
            }
        }
        let recent = UICollectionView.CellRegistration<HomeAlbumCardCell, Album> { cell, _, album in
            cell.configure(with: album)
        }
        let memory = UICollectionView.CellRegistration<HomeMemoryCardCell, HomeFeed.Memory> { cell, _, memory in
            cell.configure(with: memory)
        }
        let week = UICollectionView.CellRegistration<HomeWeekCardCell, WeekGlance> { cell, _, week in
            cell.configure(with: week)
        }
        let edit = UICollectionView.CellRegistration<HomeEditFooterCell, HomeItem> { [weak self] cell, _, _ in
            cell.onTap = { [weak self] in self?.presentEditHome() }
        }

        dataSource = UICollectionViewDiffableDataSource<HomeSectionID, HomeItem>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, item in
            guard let self else { return nil }
            let feed = self.model.feed
            switch item {
            case .hero:
                return collectionView.dequeueConfiguredReusableCell(using: hero, for: indexPath, item: item)
            case .empty:
                return collectionView.dequeueConfiguredReusableCell(using: empty, for: indexPath, item: item)
            case .runwayBanner, .statusBanner:
                return collectionView.dequeueConfiguredReusableCell(using: banner, for: indexPath, item: item)
            case .jump(let context):
                guard let entry = feed.jumpBackIn.first(where: { $0.context == context }) else { return nil }
                return collectionView.dequeueConfiguredReusableCell(using: jump, for: indexPath, item: entry)
            case .mix, .libraryRadio, .moreMixes:
                return collectionView.dequeueConfiguredReusableCell(using: mix, for: indexPath, item: item)
            case .recent(let id):
                guard let album = feed.recentlyAdded.first(where: { $0.id == id }) else { return nil }
                return collectionView.dequeueConfiguredReusableCell(using: recent, for: indexPath, item: album)
            case .memory:
                guard let entry = feed.onThisDay else { return nil }
                return collectionView.dequeueConfiguredReusableCell(using: memory, for: indexPath, item: entry)
            case .week:
                guard let entry = feed.week else { return nil }
                return collectionView.dequeueConfiguredReusableCell(using: week, for: indexPath, item: entry)
            case .edit:
                return collectionView.dequeueConfiguredReusableCell(using: edit, for: indexPath, item: item)
            }
        }

        let headers = UICollectionView.SupplementaryRegistration<HomeSectionHeaderView>(
            elementKind: HomeSectionHeaderView.kind
        ) { [weak self] header, _, indexPath in
            guard let self, let section = self.dataSource.sectionIdentifier(for: indexPath.section) else { return }
            switch section {
            case .jumpBackIn:
                header.configure(title: HomeCopy.title(for: .jumpBackIn))
            case .madeForYou:
                header.configure(title: HomeCopy.title(for: .madeForYou))
            case .recentlyAdded:
                header.configure(title: HomeCopy.title(for: .recentlyAdded), actionTitle: HomeCopy.seeAll) { [weak self] in
                    self?.tabController?.showRecentlyAddedInLibrary()
                }
            default:
                break
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headers, for: indexPath)
        }
    }
}
