#if DEBUG
import Foundation

/// Launch arguments that let a simulator rehearse the sample download's
/// unhappy paths without a real network fault. `--sample-base-url <url>`
/// points the service at another server (an unreachable one fails every
/// attempt), `--sample-fail-once-after <n>` drops the connection once after
/// n files have landed so Retry can be watched finishing the rest, and
/// `--sample-route cellular|lowdata` makes the route check report a metered
/// link or Low Data Mode. `--sample-drive guide|sample` taps the guide row or
/// the sample button a few seconds after launch, since no UI driver is
/// installed on this machine.
enum SampleDebugHooks {

    enum ForcedRoute {
        case cellular
        case lowDataMode

        var value: SampleDownloadPolicy.Confirmation {
            switch self {
            case .cellular: .cellular
            case .lowDataMode: .lowDataMode
            }
        }
    }

    private static let failOnceLock = NSLock()
    nonisolated(unsafe) private static var failOnceSpent = false

    static var drive: String? {
        argument("--sample-drive")
    }

    static var retryDelay: Double {
        argument("--sample-retry-delay").flatMap(Double.init) ?? 40
    }

    static var baseURL: URL? {
        argument("--sample-base-url").flatMap(URL.init(string:))
    }

    static var forcedConfirmation: ForcedRoute? {
        switch argument("--sample-route") {
        case "cellular": .cellular
        case "lowdata": .lowDataMode
        default: nil
        }
    }

    static func failOnceIfRequested(landedFiles: Int) throws {
        guard let threshold = argument("--sample-fail-once-after").flatMap(Int.init),
              landedFiles >= threshold else { return }
        let shouldFail = failOnceLock.withLock {
            defer { failOnceSpent = true }
            return !failOnceSpent
        }
        if shouldFail {
            AppLogger.info("Sample debug: dropping the connection after \(landedFiles) files", category: .content)
            throw URLError(.networkConnectionLost)
        }
    }

    private static func argument(_ name: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
#endif
