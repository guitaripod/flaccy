import Foundation

/// What the AI proxy's HTTP answer means for the job, read from the status and
/// the `error` code in the body — the contract with `flaccy-api`'s `/v1/metadata`.
///
/// Each verdict asks for a different response, which is why a bare "it failed"
/// is not enough: a spent daily allowance must stop the pass until the reset
/// instead of retrying for a minute, and an upstream that is merely busy must
/// not be reported as a missing connection.
public enum AIProxyReply: Equatable, Sendable {
    case answer

    /// The upstream model is momentarily rate limited: back off and ask again.
    case busy

    /// The device, IP or global allowance for the UTC day is spent.
    case quotaReached(resetsAt: Date)

    case payloadTooLarge

    /// Any other error status: the proxy answered, with nothing useful.
    case unavailable

    public static let dailyLimitSuffix = "_daily_limit_reached"

    /// The longest `Retry-After` believed: a day, plus an hour for the cushion.
    private static let longestWait: TimeInterval = 25 * 3600

    public static func classify(
        status: Int, errorCode: String?, retryAfter: TimeInterval?, now: Date
    ) -> AIProxyReply {
        switch status {
        case 200...299:
            return .answer
        case 413:
            return .payloadTooLarge
        case 429:
            guard let errorCode, errorCode.hasSuffix(dailyLimitSuffix) else { return .busy }
            return .quotaReached(resetsAt: resetDate(retryAfter: retryAfter, now: now))
        default:
            return .unavailable
        }
    }

    /// The proxy's own `Retry-After` wins over the local calendar: it is counted
    /// from the clock that decides the allowance, so a device whose clock is a
    /// minute fast cannot resume early, hit the limit again and sleep a whole
    /// extra day.
    private static func resetDate(retryAfter: TimeInterval?, now: Date) -> Date {
        guard let retryAfter, retryAfter.isFinite, retryAfter > 0 else {
            return EnrichmentPolicy.nextQuotaReset(after: now)
        }
        return now.addingTimeInterval(min(retryAfter, longestWait))
    }
}
