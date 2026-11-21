import AppKit
import FlaccyCore

/// The Albums carousel: one cover large in the middle, its neighbours smaller
/// to either side, scrolled sideways. Where every cover sits comes from
/// `FlowGeometry`, the same proportions the Linux carousel is drawn with.
final class AlbumCarouselLayout: NSCollectionViewLayout {

    /// The room under each cover for its title and artist.
    static let captionHeight: CGFloat = 46

    private var count = 0
    private var room = NSSize.zero
    private var geometry = FlowGeometry.fitting(width: 0, height: 0)

    private var clip: NSClipView? { collectionView?.enclosingScrollView?.contentView }

    private var pitch: CGFloat { CGFloat(geometry.pitch) }

    /// The place, as a fractional index, the carousel is scrolled to.
    var position: Double {
        guard let clip, pitch > 0 else { return 0 }
        return FlowGeometry.clamped(Double(clip.bounds.minX / pitch), count: count)
    }

    /// Where the carousel is scrolled to when it rests on the cover at `index`.
    func offset(restingAt index: Int) -> CGFloat {
        CGFloat(FlowGeometry.clamped(Double(index), count: count)) * pitch
    }

    override func prepare() {
        super.prepare()
        guard let collectionView, let scroll = collectionView.enclosingScrollView else { return }
        count = collectionView.numberOfSections > 0 ? collectionView.numberOfItems(inSection: 0) : 0
        let insets = scroll.contentInsets
        let bounds = scroll.contentView.bounds
        room = NSSize(width: bounds.width, height: max(bounds.height - insets.top - insets.bottom, 0))
        geometry = FlowGeometry.fitting(
            width: Double(room.width), height: Double(room.height - AlbumCarouselLayout.captionHeight)
        )
    }

    override var collectionViewContentSize: NSSize {
        NSSize(width: room.width + CGFloat(max(count - 1, 0)) * pitch, height: room.height)
    }

    private func attributes(for slot: FlowGeometry.Slot, order: Int, origin: CGFloat) -> NSCollectionViewLayoutAttributes {
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: slot.index, section: 0))
        attributes.frame = NSRect(
            x: origin + CGFloat(slot.x), y: CGFloat(slot.y), width: CGFloat(slot.side),
            height: CGFloat(slot.side) + AlbumCarouselLayout.captionHeight
        )
        attributes.alpha = CGFloat(slot.opacity)
        attributes.zIndex = order
        return attributes
    }

    private func slots() -> [FlowGeometry.Slot] {
        geometry.slots(
            width: Double(room.width), height: Double(room.height - AlbumCarouselLayout.captionHeight),
            position: position, count: count
        )
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        let origin = clip?.bounds.minX ?? 0
        return slots().enumerated().map { order, slot in attributes(for: slot, order: order, origin: origin) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        let origin = clip?.bounds.minX ?? 0
        if let shown = slots().enumerated().first(where: { $0.element.index == indexPath.item }) {
            return attributes(for: shown.element, order: shown.offset, origin: origin)
        }
        let distance = Double(indexPath.item) - position
        let side = CGFloat(geometry.side(at: distance))
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        attributes.frame = NSRect(
            x: origin + room.width / 2 + CGFloat(geometry.offset(at: distance)) - side / 2,
            y: (room.height - AlbumCarouselLayout.captionHeight - side) / 2, width: side,
            height: side + AlbumCarouselLayout.captionHeight
        )
        attributes.alpha = CGFloat(FlowGeometry.neighbourOpacity)
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { true }

    override func targetContentOffset(
        forProposedContentOffset proposedContentOffset: NSPoint, withScrollingVelocity velocity: NSPoint
    ) -> NSPoint {
        guard pitch > 0 else { return proposedContentOffset }
        let place = (proposedContentOffset.x / pitch).rounded()
        return NSPoint(x: offset(restingAt: Int(place)), y: proposedContentOffset.y)
    }
}
