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

    private var loadGeneration = 0

    var matchedCount: Int { items.filter { $0.matchedTrack != nil }.count }
    var totalCount: Int { items.count }

    var matchedTracks: [Track] {
        items.compactMap { $0.matchedTrack }
    }

    /// Loads the chart for the given period and matches it against the current
    /// library state. The library lookup is rebuilt on every call so imports,
    /// metadata cleanups, and pull-to-refresh always match fresh data. A
    /// generation counter ensures that when loads overlap (rapid period
    /// switches), only the most recently requested load publishes results.
    func loadChart(period: ChartPeriod) async {
        selectedPeriod = period
        loadGeneration += 1
        let generation = loadGeneration
        loadingPublisher.send(true)

        let chartTracks = await LastFMService.shared.fetchTopTracks(period: period)
        let displayItems = await Self.matchToLibrary(chartTracks: chartTracks)

        guard !Task.isCancelled, generation == loadGeneration else { return }

        items = displayItems
        itemsPublisher.send(displayItems)
        loadingPublisher.send(false)
    }

    /// Matches chart entries against the library on a background queue,
    /// decoding artwork only for albums that actually matched a chart row
    /// instead of retaining a decoded image for every album in the library.
    nonisolated private static func matchToLibrary(chartTracks: [ChartTrack]) async -> [ChartDisplayItem] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var trackLookup = [String: TrackRecord]()
                var coverData = [String: Data]()

                if let albumsWithTracks = try? DatabaseManager.shared.fetchAlbumsWithTracks() {
                    for (albumInfo, records) in albumsWithTracks {
                        if let first = records.first {
                            let artKey = "\(first.albumTitle)\0\(first.artist)"
                            if let data = albumInfo?.coverArtData ?? first.artworkData {
                                coverData[artKey] = data
                            }
                        }
                        for record in records {
                            let key = "\(record.title.lowercased())\0\(record.artist.lowercased())"
                            if trackLookup[key] == nil { trackLookup[key] = record }
                        }
                    }
                }

                var decodedArtwork = [String: UIImage]()
                let displayItems: [ChartDisplayItem] = chartTracks.map { entry in
                    let lookupKey = "\(entry.name.lowercased())\0\(entry.artistName.lowercased())"
                    let track: Track? = trackLookup[lookupKey].map { record in
                        let artKey = "\(record.albumTitle)\0\(record.artist)"
                        var artwork = decodedArtwork[artKey]
                        if artwork == nil, let data = coverData[artKey], let image = UIImage(data: data) {
                            decodedArtwork[artKey] = image
                            artwork = image
                        }
                        return Track.from(record: record, artwork: artwork)
                    }

                    return ChartDisplayItem(
                        rank: entry.rank,
                        trackName: entry.name,
                        artistName: entry.artistName,
                        playCount: entry.playCount,
                        matchedTrack: track
                    )
                }
                continuation.resume(returning: displayItems)
            }
        }
    }
}
