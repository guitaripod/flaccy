import UIKit

/// A collection view whose grids are laid out around a fold that runs down
/// it. The system reports the fold only after a first layout pass, and again
/// as the window moves between an iPhone Duo's displays, so the layout is
/// invalidated whenever the fold this view reports changes.
final class FoldAwareCollectionView: UICollectionView {

    private(set) var foldSpan: ClosedRange<CGFloat>?

    override func layoutSubviews() {
        let span = verticalFoldSpan
        if span != foldSpan {
            foldSpan = span
            collectionViewLayout.invalidateLayout()
        }
        super.layoutSubviews()
    }

    /// The trailing inset that keeps a section whose content keeps `leading`
    /// and `trailing` from the safe area on the page before a fold running
    /// down this view, so its controls never sit on the hinge; `trailing`
    /// itself when no fold runs through.
    func leadingPageTrailingInset(leading: CGFloat, trailing: CGFloat, minimum: CGFloat = 300) -> CGFloat {
        guard let content = contentSpan(leading: leading, trailing: trailing),
              let halves = AdaptiveLayout.foldHalves(content: content, fold: foldSpan, leadingMinimum: minimum, trailingMinimum: 0)
        else { return trailing }
        return trailing + halves.gap + halves.trailing
    }

    /// The fold grid for a section whose content keeps `leading` and
    /// `trailing` from the safe area, or nil when no fold runs through it.
    func foldGrid(
        leading: CGFloat, trailing: CGFloat, columnsForSide: @MainActor (CGFloat) -> Int = AdaptiveLayout.gridColumns(forWidth:)
    ) -> AdaptiveLayout.FoldGrid? {
        guard let content = contentSpan(leading: leading, trailing: trailing) else { return nil }
        return AdaptiveLayout.foldGrid(content: content, fold: foldSpan, columnsForSide: columnsForSide)
    }

    /// The x range a section keeping `leading` and `trailing` from the safe
    /// area spans, in this view's own space; nil when nothing is left.
    private func contentSpan(leading: CGFloat, trailing: CGFloat) -> ClosedRange<CGFloat>? {
        let usable = bounds.inset(by: safeAreaInsets)
        let start = usable.minX + leading
        let end = usable.maxX - trailing
        return end > start ? start...end : nil
    }
}

extension NSCollectionLayoutGroup {

    /// One row of a fold grid: `grid.columnsPerSide` items on each side of the
    /// fold, `spacing` apart, with the fold between the two halves.
    static func foldGridRow(
        _ grid: AdaptiveLayout.FoldGrid, spacing: CGFloat, height: NSCollectionLayoutDimension
    ) -> NSCollectionLayoutGroup {
        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1 / CGFloat(grid.columnsPerSide)), heightDimension: height
        ))
        let sideSize = NSCollectionLayoutSize(widthDimension: .absolute(grid.sideWidth), heightDimension: height)
        let halves = (0..<2).map { _ -> NSCollectionLayoutGroup in
            let side = NSCollectionLayoutGroup.horizontal(layoutSize: sideSize, repeatingSubitem: item, count: grid.columnsPerSide)
            side.interItemSpacing = .fixed(spacing)
            return side
        }
        let rowSize = NSCollectionLayoutSize(widthDimension: .absolute(grid.sideWidth * 2 + grid.gap), heightDimension: height)
        let row = NSCollectionLayoutGroup.horizontal(layoutSize: rowSize, subitems: halves)
        row.interItemSpacing = .fixed(grid.gap)
        return row
    }
}

extension NSCollectionLayoutSection {

    /// A cover wall laid out as a fold grid, with the section's usual
    /// `insets` widened by what the grid needs to meet the fold.
    static func foldGrid(
        _ grid: AdaptiveLayout.FoldGrid, spacing: CGFloat, rowSpacing: CGFloat,
        height: NSCollectionLayoutDimension, insets: NSDirectionalEdgeInsets
    ) -> NSCollectionLayoutSection {
        let section = NSCollectionLayoutSection(group: .foldGridRow(grid, spacing: spacing, height: height))
        section.interGroupSpacing = rowSpacing
        section.contentInsetsReference = .safeArea
        section.contentInsets = NSDirectionalEdgeInsets(
            top: insets.top, leading: insets.leading + grid.extraLeading,
            bottom: insets.bottom, trailing: insets.trailing + grid.extraTrailing
        )
        return section
    }
}
