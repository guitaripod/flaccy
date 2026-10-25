import UIKit

extension HomeViewController {

    private static let pageInset: CGFloat = 16
    private static let gridSpacing: CGFloat = 10

    func makeLayout() -> UICollectionViewCompositionalLayout {
        let configuration = UICollectionViewCompositionalLayoutConfiguration()
        configuration.interSectionSpacing = 0
        return UICollectionViewCompositionalLayout(sectionProvider: { [weak self] index, _ in
            guard let self, let id = self.dataSource?.sectionIdentifier(for: index) else { return nil }
            return self.layoutSection(for: id)
        }, configuration: configuration)
    }

    private func layoutSection(for id: HomeSectionID) -> NSCollectionLayoutSection {
        switch id {
        case .banners: bannerSection()
        case .hero: heroSection()
        case .jumpBackIn: jumpSection()
        case .madeForYou: shelfSection(width: HomeMixCardCell.artSide, height: HomeMixCardCell.artSide + 66)
        case .recentlyAdded: shelfSection(width: HomeAlbumCardCell.artSide, height: HomeAlbumCardCell.artSide + 56)
        case .onThisDay, .thisWeek: glanceSection(columns: 1)
        case .pair: glanceSection(columns: 2)
        case .footer: footerSection()
        }
    }

    private func bannerSection() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(34))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
        return NSCollectionLayoutSection(group: group)
    }

    private func heroSection() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(300))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: Self.pageInset, bottom: 22, trailing: Self.pageInset)
        return section
    }

    private func header() -> NSCollectionLayoutBoundarySupplementaryItem {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(36))
        return NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: size, elementKind: HomeSectionHeaderView.kind, alignment: .top
        )
    }

    private func jumpSection() -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(0.5), heightDimension: .estimated(HomeJumpTileCell.height)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1), heightDimension: .estimated(HomeJumpTileCell.height)
        )
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, repeatingSubitem: item, count: 2)
        group.interItemSpacing = .fixed(Self.gridSpacing)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = Self.gridSpacing
        section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: Self.pageInset, bottom: 20, trailing: Self.pageInset)
        section.boundarySupplementaryItems = [header()]
        return section
    }

    private func shelfSection(width: CGFloat, height: CGFloat) -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .absolute(width), heightDimension: .estimated(height))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuousGroupLeadingBoundary
        section.interGroupSpacing = 12
        section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: Self.pageInset, bottom: 20, trailing: Self.pageInset)
        section.boundarySupplementaryItems = [header()]
        return section
    }

    private func glanceSection(columns: Int) -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1 / CGFloat(columns)), heightDimension: .fractionalHeight(1)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(180))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, repeatingSubitem: item, count: columns)
        group.interItemSpacing = .fixed(12)
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: Self.pageInset, bottom: 20, trailing: Self.pageInset)
        return section
    }

    private func footerSection() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(72))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Self.pageInset, bottom: 24, trailing: Self.pageInset)
        return section
    }
}
