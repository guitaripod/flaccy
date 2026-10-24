import Foundation

/// How a person has framed a cover: which part of a source image shows through
/// a square window. Every desktop and mobile cropper drives this one value, so
/// the window can never leave the image, zoom stays in the same range, and the
/// same gesture lands on the same pixels everywhere. Mirrored in Rust as
/// `linux/shared/src/artwork_framing.rs`.
///
/// Units: the image is measured in source pixels, the window in whatever
/// points the toolkit lays out, and `zoom` is window points per source pixel.
/// Anchors and deltas are window points measured from the window's top-left.
public struct ArtworkFraming: Equatable, Sendable {

    /// How far past "fill the window" a person can zoom in.
    public static let maximumZoomMultiple = 5.0

    /// What a double click or double tap zooms to from the filled state.
    public static let doubleClickMultiple = 2.5

    /// Below this many window points per source pixel the zoom ceiling stops
    /// shrinking, so a small source still lets a person inspect single pixels.
    public static let zoomCeilingFloor = 1.0

    /// A cover showing fewer source pixels than this will look soft on a large
    /// display, which the editor says out loud.
    public static let softBelowPixels = 500.0

    public let imageWidth: Double
    public let imageHeight: Double
    public private(set) var frameSide: Double
    public private(set) var zoom: Double
    public private(set) var centerX: Double
    public private(set) var centerY: Double

    /// Framing a freshly loaded image: filled, centred. Nil when the image or
    /// the window has no usable size.
    public init?(imageWidth: Double, imageHeight: Double, frameSide: Double) {
        guard imageWidth.isFinite, imageHeight.isFinite, frameSide.isFinite,
              imageWidth > 0, imageHeight > 0, frameSide > 0
        else { return nil }
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.frameSide = frameSide
        self.zoom = frameSide / min(imageWidth, imageHeight)
        self.centerX = imageWidth / 2
        self.centerY = imageHeight / 2
    }

    /// The smallest zoom, at which the shorter edge exactly fills the window.
    public var fillZoom: Double { frameSide / min(imageWidth, imageHeight) }

    public var maxZoom: Double {
        max(fillZoom * Self.maximumZoomMultiple, Self.zoomCeilingFloor, fillZoom)
    }

    public var isAtFill: Bool { zoom <= fillZoom * 1.01 }

    public var isSoft: Bool { visibleSide < Self.softBelowPixels }

    /// Side of the source square currently showing, in source pixels.
    public var visibleSide: Double { frameSide / zoom }

    public var visibleX: Double { centerX - visibleSide / 2 }

    public var visibleY: Double { centerY - visibleSide / 2 }

    /// Where the zoom sits between filled (0) and fully in (1) on a log scale,
    /// which is what a slider should move along so equal drags feel equal.
    public var zoomFraction: Double {
        let span = log(maxZoom / fillZoom)
        guard span > 0 else { return 0 }
        return min(max(log(zoom / fillZoom) / span, 0), 1)
    }

    /// Side in pixels of the square to render for the current framing, never
    /// more than `limit` and never more than the source can supply.
    public func outputPixels(limit: Int) -> Int {
        max(1, min(limit, Int(visibleSide.rounded())))
    }

    /// The same framing after the window changed size: what showed stays
    /// showing, scaled to the new window.
    public func resized(frameSide newSide: Double) -> ArtworkFraming {
        guard newSide.isFinite, newSide > 0, newSide != frameSide else { return self }
        var next = self
        let ratio = zoom / fillZoom
        next.frameSide = newSide
        next.zoom = min(max(next.fillZoom * ratio, next.fillZoom), next.maxZoom)
        next.clampCenter()
        return next
    }

    /// The content following a drag of (`dx`, `dy`) window points.
    public func panned(dx: Double, dy: Double) -> ArtworkFraming {
        var next = self
        next.centerX -= dx / zoom
        next.centerY -= dy / zoom
        next.clampCenter()
        return next
    }

    /// Zooms to `target`, keeping the source point under the anchor where it
    /// is. The anchor defaults to the window's centre.
    public func zoomed(to target: Double, anchorX: Double? = nil, anchorY: Double? = nil) -> ArtworkFraming {
        guard target.isFinite, target > 0 else { return self }
        let ax = (anchorX ?? frameSide / 2) - frameSide / 2
        let ay = (anchorY ?? frameSide / 2) - frameSide / 2
        let pointX = centerX + ax / zoom
        let pointY = centerY + ay / zoom
        var next = self
        next.zoom = min(max(target, fillZoom), maxZoom)
        next.centerX = pointX - ax / next.zoom
        next.centerY = pointY - ay / next.zoom
        next.clampCenter()
        return next
    }

    public func zoomed(byFactor factor: Double, anchorX: Double? = nil, anchorY: Double? = nil) -> ArtworkFraming {
        guard factor.isFinite, factor > 0 else { return self }
        return zoomed(to: zoom * factor, anchorX: anchorX, anchorY: anchorY)
    }

    public func zoomed(toFraction fraction: Double) -> ArtworkFraming {
        let clamped = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        return zoomed(to: fillZoom * exp(clamped * log(maxZoom / fillZoom)))
    }

    /// Double click: in from the filled state around the pointer, back out to
    /// filled otherwise.
    public func toggled(anchorX: Double, anchorY: Double) -> ArtworkFraming {
        if isAtFill {
            return zoomed(to: min(maxZoom, fillZoom * Self.doubleClickMultiple), anchorX: anchorX, anchorY: anchorY)
        }
        return zoomed(to: fillZoom, anchorX: anchorX, anchorY: anchorY)
    }

    private mutating func clampCenter() {
        let half = visibleSide / 2
        centerX = min(max(centerX, half), max(imageWidth - half, half))
        centerY = min(max(centerY, half), max(imageHeight - half, half))
    }
}
