import Foundation

/// How a metric moved against the window of equal length just before it, as
/// the chip on a Stats tile reads it. `up` is capped at 999 and `down` at 100
/// so a tiny baseline never prints an absurd figure. Mirrored in Rust as
/// `linux/shared/src/period_delta.rs`.
public enum PeriodDelta: Equatable, Sendable {
    case none
    case up(Int)
    case down(Int)
    case even
    case new

    public static let maximumIncrease = 999
    public static let maximumDecrease = 100

    public static func compare(current: Int, previous: Int) -> PeriodDelta {
        guard previous != 0 else { return current == 0 ? .none : .new }
        let change = (Double(current - previous) / Double(previous) * 100).rounded(.toNearestOrAwayFromZero)
        guard current != previous, change != 0 else { return .even }
        return current > previous
            ? .up(min(Int(change), maximumIncrease))
            : .down(min(Int(abs(change)), maximumDecrease))
    }
}
