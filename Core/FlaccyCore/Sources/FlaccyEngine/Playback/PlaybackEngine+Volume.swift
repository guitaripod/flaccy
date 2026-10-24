import AVFoundation
import MidgarCore
import FlaccyCore

extension PlaybackEngine {

    #if os(macOS)
    static let volumeDefaultsKey = "flaccy.mac.volume"

    public static let volumeDidChange = Notification.Name("PlayerVolumeDidChange")

    /// App-level output volume driving `AVQueuePlayer.volume`, persisted across
    /// launches; the desktop convention, leaving hardware volume untouched.
    public var volume: Float {
        get {
            guard UserDefaults.standard.object(forKey: Self.volumeDefaultsKey) != nil else { return 0.8 }
            return min(1, max(0, UserDefaults.standard.float(forKey: Self.volumeDefaultsKey)))
        }
        set {
            let clamped = min(1, max(0, newValue))
            UserDefaults.standard.set(clamped, forKey: Self.volumeDefaultsKey)
            player?.volume = clamped
            postOnMain(Self.volumeDidChange)
        }
    }
    #endif
}
