import Combine
import UIKit

nonisolated struct ChartDisplayItem: Hashable, Sendable {

    let rank: Int
    let trackName: String
    let artistName: String
    let playCount: Int
    let matchedTrack: Track?

    static func == (lhs: ChartDisplayItem, rhs: ChartDisplayItem) -> Bool {
        lhs.rank == rhs.rank && lhs.trackName == rhs.trackName && lhs.artistName == rhs.artistName
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(rank)
        hasher.combine(trackName)
        hasher.combine(artistName)
    }
}

final class ChartsViewModel {

    let itemsPublisher = PassthroughSubject<[ChartDisplayItem], Never>()
    let loadingPublisher = PassthroughSubject<Bool, Never>()

    private(set) var selectedPeriod: ChartPeriod = .week
    private(set) var items: [ChartDisplayItem] = []

    private var cachedArtworkMap: [String: UIImage]?

    var matchedCount: Int { items.filter { $0.matchedTrack != nil }.count }
    var totalCount: Int { items.count }

    var matchedTracks: [Track] {
        items.compactMap { $0.matchedTrack }
    }

    func loadChart(period: ChartPeriod) async {
        selectedPeriod = period
        loadingPublisher.send(true)

        let chartTracks = await LastFMService.shared.fetchTopTracks(period: period)

        if cachedArtworkMap == nil {
            cachedArtworkMap = await buildArtworkMap()
        }
        let artworkMap = cachedArtworkMap ?? [:]

        let displayItems: [ChartDisplayItem] = chartTracks.map { entry in
            let matched = try? DatabaseManager.shared.findTrack(title: entry.name, artist: entry.artistName)
            let track: Track? = matched.map { record in
                let key = "\(record.albumTitle)\0\(record.artist)"
                return Track.from(record: record, artwork: artworkMap[key])
            }

            return ChartDisplayItem(
                rank: entry.rank,
                trackName: entry.name,
                artistName: entry.artistName,
                playCount: entry.playCount,
                matchedTrack: track
            )
        }

        items = displayItems
        itemsPublisher.send(displayItems)
        loadingPublisher.send(false)
    }

    private func buildArtworkMap() async -> [String: UIImage] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let albumsWithTracks = try? DatabaseManager.shared.fetchAlbumsWithTracks() else {
                    continuation.resume(returning: [:])
                    return
                }

                var map = [String: UIImage]()
                for (albumInfo, tracks) in albumsWithTracks {
                    guard let first = tracks.first else { continue }
                    let key = "\(first.albumTitle)\0\(first.artist)"
                    if let data = albumInfo?.coverArtData, let img = UIImage(data: data) {
                        map[key] = img
                    } else if let data = first.artworkData, let img = UIImage(data: data) {
                        map[key] = img
                    }
                }
                continuation.resume(returning: map)
            }
        }
    }
}
