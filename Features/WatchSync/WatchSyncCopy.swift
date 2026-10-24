import FlaccyCore
import UIKit

enum SyncFormat {
    private static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()

    static func size(_ value: Int64) -> String { bytes.string(fromByteCount: max(0, value)) }

    static func approximateSize(_ value: Int64) -> String { String(localized: "≈\u{00A0}\(size(value))") }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return String(localized: "measuring…") }
        return String(localized: "\(bytes.string(fromByteCount: Int64(bytesPerSecond)))/s")
    }

    static func eta(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return String(localized: "estimating time…") }
        if seconds < 60 { return String(localized: "less than a minute left") }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return String(localized: "about \(minutes) min left") }
        return String(localized: "about \(minutes / 60)h \(minutes % 60)m left")
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }
}

extension WatchAudioProfile {

    var displayName: String {
        switch self {
        case .original: String(localized: "Original")
        case .high: String(localized: "High")
        case .balanced: String(localized: "Balanced")
        case .compact: String(localized: "Compact")
        }
    }

    var formatName: String {
        guard let bitRate else { return String(localized: "Lossless") }
        return String(localized: "AAC \(bitRate / 1_000) kbps")
    }

    var caption: String {
        switch self {
        case .original: String(localized: "Files are sent untouched. The biggest by far, and no better over Bluetooth.")
        case .high: String(localized: "Great sound over Bluetooth for nearly everyone. The default.")
        case .balanced: String(localized: "A good middle: noticeably more music in the same space.")
        case .compact: String(localized: "The smallest files. Fits the most music for long trips.")
        }
    }

    func libraryHint(albumCount: Int, bytes: Int64) -> String {
        let size = SyncFormat.size(bytes)
        if albumCount == 1 { return String(localized: "Your album ≈ \(size) at this quality") }
        return String(localized: "Your \(albumCount) albums ≈ \(size) at this quality")
    }
}

/// Where the sync stands, in the one sentence the status card leads with.
enum WatchConnectionState: Equatable {

    case notSupported, notPaired, notInstalled, waiting(WatchSyncService.WaitReason)
    case full, syncing, stalled, pending, synced, ready

    init(service: WatchSyncService, link: WatchSyncLink) {
        switch WatchSyncService.Readiness.make(link: link) {
        case .notSupported: self = .notSupported
        case .notPaired: self = .notPaired
        case .notInstalled: self = .notInstalled
        case let .waitingForWatch(reason): self = .waiting(reason)
        case .ready: self = Self.readyState(service: service)
        }
    }

    private static func readyState(service: WatchSyncService) -> WatchConnectionState {
        if service.isSyncing { return .syncing }
        if service.watchIsFull || service.diskFullCount > 0 { return .full }
        if service.stuckCount > 0 { return .stalled }
        if service.unconfirmedCount > 0 { return .pending }
        if service.syncedCount > 0 { return .synced }
        return .ready
    }

    var color: UIColor {
        switch self {
        case .synced, .ready: .systemGreen
        case .syncing: .systemBlue
        case .pending, .notInstalled, .stalled, .waiting: .systemOrange
        case .full: .systemRed
        case .notSupported, .notPaired: .systemGray
        }
    }

    var symbol: String {
        switch self {
        case .syncing: "arrow.triangle.2.circlepath"
        case .synced: "checkmark"
        case .pending: "clock.fill"
        case .full: "externaldrive.fill.trianglebadge.exclamationmark"
        case .stalled: "exclamationmark.triangle.fill"
        case .notInstalled: "arrow.down.app.fill"
        case .ready: "applewatch"
        case .waiting: "applewatch.radiowaves.left.and.right"
        case .notSupported, .notPaired: "applewatch.slash"
        }
    }

    var title: String {
        switch self {
        case .notSupported: String(localized: "Not Available")
        case .notPaired: String(localized: "No Apple Watch Paired")
        case .notInstalled: String(localized: "Flaccy Isn’t on Your Watch")
        case .waiting(.activating): String(localized: "Connecting to Your Watch")
        case .waiting: String(localized: "Waiting for Your Apple Watch")
        case .full: String(localized: "Apple Watch is Full")
        case .syncing: String(localized: "Syncing…")
        case .stalled: String(localized: "Some Songs Couldn’t Be Sent")
        case .pending: String(localized: "Finishing Up")
        case .synced: String(localized: "Up to Date")
        case .ready: String(localized: "Connected")
        }
    }

    var isWaiting: Bool {
        if case .waiting = self { true } else { false }
    }

    var offersSetupHelp: Bool { self == .notInstalled || self == .notPaired }

    var offersRecheck: Bool { offersSetupHelp || isWaiting }

    /// The card's second line. `showsFreeSpace` is off while the storage meter is
    /// on screen, since the meter already says how much room is left.
    func subtitle(service: WatchSyncService, showsFreeSpace: Bool) -> String {
        let freeSpaceText = showsFreeSpace && service.watchFreeBytes > 0
            ? String(localized: " · \(SyncFormat.size(service.watchFreeBytes)) free")
            : ""
        switch self {
        case .notSupported: return String(localized: "Watch sync isn’t available on this device.")
        case .notPaired: return String(localized: "Pair an Apple Watch with this iPhone to send it music.")
        case .notInstalled: return String(localized: "Music plays from the Flaccy app on your Watch, and it isn’t installed there yet.")
        case let .waiting(reason): return waitingSubtitle(reason, queued: service.ledger.queuedCount)
        case .full:
            let n = service.diskFullCount
            return String(localized: "\(n) tracks didn’t fit\(freeSpaceText). Remove music to make room.")
        case .syncing:
            let n = service.activeTransferCount
            return String(localized: "\(n) tracks transferring in the background\(freeSpaceText).")
        case .stalled:
            let n = service.stuckCount
            return String(localized: "\(n) songs stopped after repeated attempts. Retry to send them again.")
        case .pending:
            let n = service.unconfirmedCount
            return String(localized: "\(n) tracks left — retrying automatically\(freeSpaceText).")
        case .synced:
            let n = service.syncedCount
            return String(localized: "\(n) tracks on your Apple Watch\(freeSpaceText).")
        case .ready:
            return String(localized: "Ready to sync — choose an album below.\(freeSpaceText.isEmpty ? "" : " Watch has\(freeSpaceText).")")
        }
    }

    private func waitingSubtitle(_ reason: WatchSyncService.WaitReason, queued: Int) -> String {
        let cause: String = switch reason {
        case .activating: String(localized: "Getting in touch with your Apple Watch…")
        case .unreachable: String(localized: "Your Watch isn’t nearby, is asleep, or Flaccy isn’t open on it. Raise your wrist or open Flaccy on the Watch.")
        case .answering: String(localized: "Your Watch hasn’t answered yet. Open Flaccy on the Watch to wake it up.")
        }
        guard queued > 0 else { return cause }
        return String(localized: "\(cause) \(queued) songs are queued and will send on their own.")
    }

    var footer: String? {
        switch self {
        case .notSupported, .notPaired, .notInstalled: nil
        default: String(localized: "Music transfers in the background — you can leave this screen or lock your phone. Each track is re-sent until your Apple Watch confirms it arrived.")
        }
    }
}

extension WatchSyncService.Readiness {

    /// The short reason a row or menu item cannot send yet.
    var unavailableReason: String {
        switch self {
        case .notPaired: String(localized: "Needs an Apple Watch")
        case .notSupported: String(localized: "Not available on this device")
        case .waitingForWatch: String(localized: "Connecting to your Watch…")
        case .notInstalled, .ready: String(localized: "Needs Flaccy on your Watch")
        }
    }

    /// What Check Again says when nothing changed.
    var stillNotReadyMessage: String {
        switch self {
        case .notInstalled: String(localized: "Flaccy still isn’t on your Watch. Installing can take a minute, so try again shortly.")
        case .notPaired: String(localized: "Still no Apple Watch paired with this iPhone.")
        case .notSupported: String(localized: "Watch sync isn’t available on this device.")
        case .waitingForWatch: String(localized: "Your Watch hasn’t answered yet. Raise your wrist or open Flaccy on it.")
        case .ready: String(localized: "Your Apple Watch is ready.")
        }
    }
}

/// How one album row reads: its status line, the colour of that line, what sits
/// at the trailing edge, and what VoiceOver says.
struct WatchAlbumPresentation {

    enum Accessory {
        case ring(Double)
        case spinner
        case icon(name: String, tint: UIColor)
        case pill(String)
    }

    let statusText: String
    let statusColor: UIColor
    let accessory: Accessory
    let voiceOverValue: String
    let voiceOverHint: String?
    let state: WatchSyncService.AlbumState
    let isDimmed: Bool

    init(
        statusText: String,
        statusColor: UIColor,
        accessory: Accessory,
        voiceOverValue: String,
        voiceOverHint: String? = nil,
        state: WatchSyncService.AlbumState,
        isDimmed: Bool = false
    ) {
        self.statusText = statusText
        self.statusColor = statusColor
        self.accessory = accessory
        self.voiceOverValue = voiceOverValue
        self.voiceOverHint = voiceOverHint
        self.state = state
        self.isDimmed = isDimmed
    }

    @MainActor
    static func make(album: Album, service: WatchSyncService) -> WatchAlbumPresentation {
        let state = service.state(of: album)
        let total = album.tracks.count
        let size = SyncFormat.approximateSize(WatchSyncSizing.totalBytes(in: album, profile: service.profile))
        let synced = service.syncedCount(in: album)
        let readiness = service.readiness

        switch state {
        case let .sending(fraction):
            return WatchAlbumPresentation(
                statusText: String(localized: "Sending \(SyncFormat.percent(fraction))  ·  \(size)"),
                statusColor: .systemBlue,
                accessory: .ring(fraction),
                voiceOverValue: String(localized: "Sending, \(SyncFormat.percent(fraction))"),
                state: state
            )
        case .preparing:
            return WatchAlbumPresentation(
                statusText: String(localized: "Preparing  ·  \(size)"),
                statusColor: .systemBlue,
                accessory: .spinner,
                voiceOverValue: String(localized: "Preparing"),
                state: state
            )
        case .synced:
            return WatchAlbumPresentation(
                statusText: String(localized: "On Apple Watch  ·  \(size)"),
                statusColor: .systemGreen,
                accessory: .icon(name: "checkmark.circle.fill", tint: .systemGreen),
                voiceOverValue: String(localized: "Synced"),
                voiceOverHint: String(localized: "Double-tap to remove from your Apple Watch"),
                state: state
            )
        case .failed:
            return WatchAlbumPresentation(
                statusText: String(localized: "Tap to retry  ·  \(size)"),
                statusColor: .systemRed,
                accessory: .icon(name: "exclamationmark.circle.fill", tint: .systemRed),
                voiceOverValue: String(localized: "Failed"),
                voiceOverHint: String(localized: "Double-tap to send the songs that failed again"),
                state: state
            )
        case .storageFull:
            return WatchAlbumPresentation(
                statusText: String(localized: "Not enough space on Watch  ·  \(size)"),
                statusColor: .systemOrange,
                accessory: .icon(name: "externaldrive.fill.trianglebadge.exclamationmark", tint: .systemOrange),
                voiceOverValue: String(localized: "Storage full"),
                state: state
            )
        case .waiting:
            return queued(state: state, readiness: readiness, size: size)
        case .partial, .notSynced:
            if !readiness.canQueue {
                return unavailable(state: state, readiness: readiness, size: size, synced: synced, total: total)
            }
            return idle(album: album, state: state, service: service, size: size, synced: synced, total: total)
        }
    }

    private static func queued(
        state: WatchSyncService.AlbumState,
        readiness: WatchSyncService.Readiness,
        size: String
    ) -> WatchAlbumPresentation {
        guard case .waitingForWatch = readiness else {
            return WatchAlbumPresentation(
                statusText: String(localized: "Waiting to send  ·  \(size)"),
                statusColor: .secondaryLabel,
                accessory: .spinner,
                voiceOverValue: String(localized: "Waiting"),
                voiceOverHint: String(localized: "Queued. It sends on its own."),
                state: state
            )
        }
        return WatchAlbumPresentation(
            statusText: String(localized: "Waiting to send  ·  starts when your Watch is nearby"),
            statusColor: .systemOrange,
            accessory: .spinner,
            voiceOverValue: String(localized: "Waiting for your Apple Watch"),
            voiceOverHint: String(localized: "Queued. It sends when your Watch is nearby."),
            state: state
        )
    }

    /// An album that cannot be sent yet looks it, and says why in the one place
    /// the person is already reading.
    private static func unavailable(
        state: WatchSyncService.AlbumState,
        readiness: WatchSyncService.Readiness,
        size: String,
        synced: Int,
        total: Int
    ) -> WatchAlbumPresentation {
        let reason = readiness.unavailableReason
        let hint = readiness == .notSupported
            ? String(localized: "Double-tap to learn why this isn’t available")
            : String(localized: "Double-tap to see how to set up your Apple Watch")
        return WatchAlbumPresentation(
            statusText: reason,
            statusColor: .secondaryLabel,
            accessory: .icon(name: "applewatch.slash", tint: .tertiaryLabel),
            voiceOverValue: reason,
            voiceOverHint: hint,
            state: state,
            isDimmed: true
        )
    }

    @MainActor
    private static func idle(
        album: Album,
        state: WatchSyncService.AlbumState,
        service: WatchSyncService,
        size: String,
        synced: Int,
        total: Int
    ) -> WatchAlbumPresentation {
        let isPartial = synced > 0
        let voiceOver = isPartial ? String(localized: "\(synced) of \(total) synced") : String(localized: "Not synced")
        if case let .tooLarge(needed, free) = service.fitResult(for: album) {
            return WatchAlbumPresentation(
                statusText: String(localized: "Needs \(SyncFormat.size(needed))  ·  \(SyncFormat.size(free)) free"),
                statusColor: .systemOrange,
                accessory: .icon(name: "exclamationmark.triangle.fill", tint: .systemOrange),
                voiceOverValue: String(localized: "Won’t fit, needs \(SyncFormat.size(needed))"),
                state: state
            )
        }
        let text = isPartial
            ? String(localized: "\(synced) of \(total) on Watch  ·  \(size)")
            : String(localized: "\(total) tracks  ·  \(size) on Watch")
        return WatchAlbumPresentation(
            statusText: text,
            statusColor: .secondaryLabel,
            accessory: .pill(String(localized: "Send")),
            voiceOverValue: voiceOver,
            voiceOverHint: String(localized: "Double-tap to send to your Apple Watch"),
            state: state
        )
    }
}
