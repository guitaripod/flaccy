import ActivityKit
import Foundation

struct FlaccyActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let title: String
        let artist: String
        let albumTitle: String
        let isPlaying: Bool
        let playbackStartDate: Date
        let pausedElapsed: Double
        let duration: Double

        var playbackEndDate: Date { playbackStartDate.addingTimeInterval(duration) }
        var progressFraction: Double {
            duration > 0 ? min(1, max(0, pausedElapsed / duration)) : 0
        }
    }

    let artworkData: Data?
}
