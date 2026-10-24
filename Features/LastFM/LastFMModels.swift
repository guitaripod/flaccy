import AuthenticationServices
import MidgarCore
import Foundation
import os
import Security

nonisolated enum ChartPeriod: String, CaseIterable, Sendable {
    case week = "7day"
    case month = "1month"
    case threeMonths = "3month"
    case sixMonths = "6month"
    case year = "12month"
    case allTime = "overall"

    var displayName: String {
        switch self {
        case .week: String(localized: "7 Days")
        case .month: String(localized: "1 Month")
        case .threeMonths: String(localized: "3 Months")
        case .sixMonths: String(localized: "6 Months")
        case .year: String(localized: "1 Year")
        case .allTime: String(localized: "All Time")
        }
    }

    var shortName: String {
        switch self {
        case .week: String(localized: "7D")
        case .month: String(localized: "1M")
        case .threeMonths: String(localized: "3M")
        case .sixMonths: String(localized: "6M")
        case .year: String(localized: "1Y")
        case .allTime: String(localized: "All")
        }
    }
}

nonisolated struct ChartTrack: Sendable {
    let rank: Int
    let name: String
    let artistName: String
    let playCount: Int
}

nonisolated struct AlbumInfo: Sendable {
    let title: String
    let artist: String
    let imageURL: String?
    let summary: String?
    let musicBrainzID: String?
    var userPlayCount: Int?
}

nonisolated struct LovedTrack: Sendable {
    let name: String
    let artist: String
    let uts: Int
}

nonisolated struct LastFMUserInfo: Sendable {
    let name: String
    let realName: String?
    let playcount: Int
    let artistCount: Int
    let trackCount: Int
    let albumCount: Int
    let registeredUts: Int
    let imageURL: String?
    let country: String?
}

nonisolated struct RecentTrack: Sendable {
    let name: String
    let artist: String
    let album: String
    let uts: Int?
    let nowPlaying: Bool
}

nonisolated struct ChartArtist: Sendable {
    let rank: Int
    let name: String
    let playCount: Int
}

nonisolated struct ChartAlbum: Sendable {
    let rank: Int
    let name: String
    let artistName: String
    let playCount: Int
    let imageURL: String?
}

nonisolated struct LastFMTrackInfo: Sendable {
    let name: String
    let artist: String
    let album: String?
    let duration: Int?
    let playCount: Int?
    let userPlayCount: Int?
    let userLoved: Bool
    let tags: [String]
}

actor RequestThrottle {
    let minInterval: TimeInterval
    var nextAvailable: Date = .distantPast

    init(minInterval: TimeInterval) { self.minInterval = minInterval }

    func acquire() async {
        let now = Date()
        let slot = max(now, nextAvailable)
        nextAvailable = slot.addingTimeInterval(minInterval)
        let delay = slot.timeIntervalSince(now)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}

nonisolated struct ArtistInfo: Sendable {
    let name: String
    let bio: String?
    let imageURL: String?
    let musicBrainzID: String?
}
