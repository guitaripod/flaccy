import ActivityKit
import Foundation

struct FlaccyActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let title: String
        let artist: String
        let albumTitle: String
        let isPlaying: Bool
        let elapsed: Double
        let duration: Double
    }

    let artworkData: Data?
}
