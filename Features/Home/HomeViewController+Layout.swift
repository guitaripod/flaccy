import UIKit

extension HomeViewController {

    private static let compactInset: CGFloat = 16
    private static let wideInset: CGFloat = 24
    private static let gridSpacing: CGFloat = 10
    private static let columnGap: CGFloat = 20

    func makeLayout() -> UICollectionViewCompositionalLayout {
        let configuration = UICollectionViewCompositionalLayoutConfiguration()
        configuration.interSectionSpacing = 0
        return UICollectionViewCompositionalLayout(sectionProvider: { [weak self] index, environment in
            guard let self, let id = self.dataSource?.sectionIdentifier(for: index) else { return nil }
            let width = environment.container.effectiveContentSize.width
            return self.layoutSection(for: id, index: index, width: width)
        }, configuration: configuration)
    }

    private func inset(for width: CGFloat) -> CGFloat {
        AdaptiveLayout.homeIsWide(contentWidth: width) ? Self.wideInset : Self.compactInset
    }

    private func layoutSection(for id: HomeSectionID, index: Int, width: CGFloat) -> NSCollectionLayoutSection {
        let wide = AdaptiveLayout.homeIsWide(contentWidth: width)
        let pageInset = inset(for: width)
        switch id {
        case .banners: return bannerSection()
        case .hero: return heroSection(pageInset: pageInset)
        case .promoNote: return promoNoteSection(pageInset: pageInset)
        case .promoCard: return promoCardSection(pageInset: pageInset)
        case .heroWithJump:
            let count = dataSource.snapshot().numberOfItems(inSection: id)
            return heroWithJumpSection(itemCount: count, pageInset: pageInset)
        case .jumpBackIn: return jumpSection(columns: wide ? AdaptiveLayout.homeWideJumpColumns : 2, pageInset: pageInset)
        case .madeForYou:
            return shelfSection(width: HomeMixCardCell.artSide, height: HomeMixCardCell.artSide + 66, pageInset: pageInset)
        case .recentlyAdded:
            return shelfSection(width: HomeAlbumCardCell.artSide, height: HomeAlbumCardCell.artSide + 56, pageInset: pageInset)
        case .onThisDay, .thisWeek: return glanceSection(columns: 1, pageInset: pageInset)
        case .pair: return glanceSection(columns: 2, pageInset: pageInset)
        case .footer: return footerSection(pageInset: pageInset)
        }
    }

    private func bannerSection() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(34))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
        return NSCollectionLayoutSection(group: group)
    }

    private func heroSection(pageInset: CGFloat) -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(300))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: pageInset, bottom: heroBottomInset, trailing: pageInset)
        return section
    }

    /// A line under the hero sits close to it; anything else leaves the usual gap.
    private var heroBottomInset: CGFloat {
        dataSource.snapshot().sectionIdentifiers.contains(.promoNote) ? 8 : 22
    }

    private func promoNoteSection(pageInset: CGFloat) -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(34))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: pageInset, bottom: 22, trailing: pageInset)
        return section
    }

    private func promoCardSection(pageInset: CGFloat) -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(280))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: pageInset, bottom: 22, trailing: pageInset)
        return section
    }

    /// The wide arrangement's first row: the hero on the leading half, Jump
    /// Back In (its title and two columns of tiles) on the trailing half.
    private func heroWithJumpSection(itemCount: Int, pageInset: CGFloat) -> NSCollectionLayoutSection {
        let half = Self.columnGap / 2
        let heroItem = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(0.5), heightDimension: .estimated(300)
        ))
        heroItem.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: half)

        let tileCount = max(itemCount - 2, 0)
        let rows = (tileCount + 1) / 2
        let titleHeight: CGFloat = 40
        let columnHeight = titleHeight + CGFloat(rows) * HomeJumpTileCell.height + CGFloat(max(rows - 1, 0)) * Self.gridSpacing

        let titleItem = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1), heightDimension: .absolute(titleHeight)
        ))
        let tile = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(0.5), heightDimension: .absolute(HomeJumpTileCell.height)
        ))
        let rowSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(HomeJumpTileCell.height))
        let rowGroups = (0..<rows).map { _ -> NSCollectionLayoutGroup in
            let row = NSCollectionLayoutGroup.horizontal(layoutSize: rowSize, repeatingSubitem: tile, count: 2)
            row.interItemSpacing = .fixed(Self.gridSpacing)
            return row
        }
        let column = NSCollectionLayoutGroup.vertical(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(0.5), heightDimension: .absolute(columnHeight)),
            subitems: [titleItem] + rowGroups
        )
        column.interItemSpacing = .fixed(Self.gridSpacing)
        column.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: half, bottom: 0, trailing: 0)

        let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(300))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [heroItem, column])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: pageInset, bottom: heroBottomInset, trailing: pageInset)
        return section
    }

    private func header() -> NSCollectionLayoutBoundarySupplementaryItem {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(36))
        return NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: size, elementKind: HomeSectionHeaderView.kind, alignment: .top
        )
    }

    private func jumpSection(columns: Int, pageInset: CGFloat) -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1 / CGFloat(columns)), heightDimension: .estimated(HomeJumpTileCell.height)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1), heightDimension: .estimated(HomeJumpTileCell.height)
        )
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, repeatingSubitem: item, count: columns)
        group.interItemSpacing = .fixed(Self.gridSpacing)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = Self.gridSpacing
        section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: pageInset, bottom: 20, trailing: pageInset)
        section.boundarySupplementaryItems = [header()]
        return section
    }

    private func shelfSection(width: CGFloat, height: CGFloat, pageInset: CGFloat) -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .absolute(width), heightDimension: .estimated(height))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuousGroupLeadingBoundary
        section.interGroupSpacing = 12
        section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: pageInset, bottom: 20, trailing: pageInset)
        section.boundarySupplementaryItems = [header()]
        return section
    }

    private func glanceSection(columns: Int, pageInset: CGFloat) -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1 / CGFloat(columns)), heightDimension: .fractionalHeight(1)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(180))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, repeatingSubitem: item, count: columns)
        group.interItemSpacing = .fixed(12)
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: pageInset, bottom: 20, trailing: pageInset)
        return section
    }

    private func footerSection(pageInset: CGFloat) -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(72))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: pageInset, bottom: 24, trailing: pageInset)
        return section
    }
}
