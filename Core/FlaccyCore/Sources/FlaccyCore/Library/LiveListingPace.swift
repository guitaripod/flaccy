import Foundation

/// When a scan that started from an empty library shows the songs it has read
/// so far: once the first `firstListing` has passed, so a small library still
/// arrives whole and the Debut gets its moment, then no more often than every
/// `between`, so redrawing every screen stays a small share of the scan.
/// Mirrored by `linux/shared/src/live_listing.rs`.
public struct LiveListingPace: Sendable, Equatable {

    public static let firstListing: Duration = .seconds(3)
    public static let between: Duration = .seconds(5)

    private let began: ContinuousClock.Instant
    private var lastListed: ContinuousClock.Instant?

    public init(began: ContinuousClock.Instant) {
        self.began = began
    }

    public func isDue(at now: ContinuousClock.Instant) -> Bool {
        if let lastListed { return now - lastListed >= Self.between }
        return now - began >= Self.firstListing
    }

    public mutating func noteListed(at now: ContinuousClock.Instant) {
        lastListed = now
    }
}
