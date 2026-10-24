import Foundation
import WatchConnectivity

extension WatchSyncService {

    /// Why a watch that has Flaccy installed is not taking music yet.
    enum WaitReason: Equatable {
        case activating
        case unreachable
        case answering
    }

    /// The one answer to "can this phone send music to a watch right now", read
    /// by the status card, the album rows, the menus and every tap.
    enum Readiness: Equatable {
        case ready
        case notSupported
        case notPaired
        case notInstalled
        case waitingForWatch(WaitReason)

        var isReady: Bool { self == .ready }

        /// Whether a request for music can be accepted now: either it starts at
        /// once or it is held until the watch answers.
        var canQueue: Bool {
            switch self {
            case .ready, .waitingForWatch(.unreachable), .waitingForWatch(.answering): true
            case .notSupported, .notPaired, .notInstalled, .waitingForWatch(.activating): false
            }
        }

        /// The states that need the person to do something on the phone or watch.
        var needsSetup: Bool {
            switch self {
            case .notSupported, .notPaired, .notInstalled: true
            case .ready, .waitingForWatch: false
            }
        }

        static func make(link: WatchSyncLink) -> Readiness {
            if !link.isSupported { return .notSupported }
            if !link.isActivated { return .waitingForWatch(.activating) }
            if !link.isPaired { return .notPaired }
            if !link.isInstalled { return .notInstalled }
            if !link.hasAnswered { return .waitingForWatch(link.isReachable ? .answering : .unreachable) }
            return .ready
        }
    }

    /// What `sync(tracks:)` did with a request, so a caller never has to guess
    /// whether anything happened.
    enum SendResult: Equatable {
        case started(Int)
        case nothingToSend
        case notReady(Readiness)
    }

    var readiness: Readiness { Readiness.make(link: WatchSyncLink.current(for: self)) }

    /// Mirrors the gate in `pump()`: a watch that has already spoken, or has
    /// never had anything to say, does not hold the pipeline back.
    var hasWatchAnswered: Bool {
        hasHeartbeat || (wcSession?.receivedApplicationContext.isEmpty ?? true)
    }
}
