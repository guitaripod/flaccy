import Foundation

/// How the album carousel is proportioned and where each cover sits: the
/// cover in the middle at full size, its neighbours smaller, and a fixed gap
/// between any two wherever the carousel is stopped. Pure, so every client
/// lays it out the same way. Mirrored in Rust as
/// `linux/shared/src/flow_geometry.rs`.
public struct FlowGeometry: Equatable, Sendable {
    public var side: Double
    public var neighbourScale: Double
    public var gap: Double

    public static let neighbourOpacity = 0.62
    public static let smallestSide = 132.0
    public static let largestSide = 560.0
    public static let widthShare = 0.4
    public static let verticalMargin = 20.0

    /// Where one cover of the carousel is drawn.
    public struct Slot: Equatable, Sendable {
        public var index: Int
        public var x: Double
        public var y: Double
        public var side: Double
        public var opacity: Double
    }

    public init(side: Double, neighbourScale: Double, gap: Double) {
        self.side = side
        self.neighbourScale = neighbourScale
        self.gap = gap
    }

    /// The proportions for a carousel of this size: the middle cover as tall
    /// as the room allows without taking more than its share of the width.
    public static func fitting(width: Double, height: Double) -> FlowGeometry {
        let side = min(max(min(height - 2.0 * verticalMargin, width * widthShare), smallestSide), largestSide)
            .rounded()
        return FlowGeometry(side: side, neighbourScale: 0.6, gap: (side * 0.09).rounded())
    }

    var neighbourSide: Double { side * neighbourScale }

    /// The edge of a cover `distance` places from the middle.
    public func side(at distance: Double) -> Double {
        side - (side - neighbourSide) * min(abs(distance), 1.0)
    }

    /// How far the centre of a cover `distance` places from the middle sits
    /// from the centre of the carousel. The first place covers the growing
    /// distance between the big cover and a small one; every further place is
    /// one small cover and one gap.
    public func offset(at distance: Double) -> Double {
        let first = side / 2.0 + gap + neighbourSide / 2.0
        let reach = abs(distance)
        let offset = reach <= 1.0 ? reach * first : first + (reach - 1.0) * (neighbourSide + gap)
        return distance < 0 ? -offset : offset
    }

    /// The points one place takes away from the middle, for turning a drag
    /// into places.
    public var pitch: Double { neighbourSide + gap }

    /// Every cover that shows at all when the carousel rests at `position`
    /// (a fractional index) in a room of `width` by `height`, nearest the
    /// middle last so it is the one on top.
    public func slots(width: Double, height: Double, position: Double, count: Int) -> [Slot] {
        guard count > 0, width > 0 else { return [] }
        let reach = Int(((width / 2.0) / pitch).rounded(.up)) + 2
        let middle = Int(position.rounded())
        var slots: [Slot] = []
        for index in (middle - reach)...(middle + reach) where index >= 0 && index < count {
            let distance = Double(index) - position
            let side = side(at: distance)
            let x = width / 2.0 + offset(at: distance) - side / 2.0
            if x + side <= 0 || x >= width { continue }
            slots.append(
                Slot(
                    index: index,
                    x: x,
                    y: (height - side) / 2.0,
                    side: side,
                    opacity: 1.0 - (1.0 - FlowGeometry.neighbourOpacity) * min(abs(distance), 1.0)
                )
            )
        }
        return slots.sorted { first, second in
            let (far, near) = (abs(Double(first.index) - position), abs(Double(second.index) - position))
            return far == near ? first.index < second.index : far > near
        }
    }

    /// The place a carousel of `count` covers may be sent to, kept on the shelf.
    public static func clamped(_ place: Double, count: Int) -> Double {
        min(max(place, 0), Double(max(count - 1, 0)))
    }
}

/// A critically damped spring: the carousel's position chasing the place it
/// was sent to, quick without overshooting.
public struct FlowGlide: Equatable, Sendable {
    public var position: Double
    public var velocity: Double

    public static let stiffness = 170.0
    public static let restDistance = 0.0008
    public static let restSpeed = 0.01

    public init(position: Double = 0, velocity: Double = 0) {
        self.position = position
        self.velocity = velocity
    }

    /// Moves one frame of `seconds` towards `target`. Returns false once it
    /// has arrived and come to rest, with the position set exactly on target.
    public mutating func step(toward target: Double, seconds: Double) -> Bool {
        let damping = 2.0 * FlowGlide.stiffness.squareRoot()
        let acceleration = FlowGlide.stiffness * (target - position) - damping * velocity
        velocity += acceleration * seconds
        position += velocity * seconds
        if abs(target - position) < FlowGlide.restDistance, abs(velocity) < FlowGlide.restSpeed {
            position = target
            velocity = 0
            return false
        }
        return true
    }
}
