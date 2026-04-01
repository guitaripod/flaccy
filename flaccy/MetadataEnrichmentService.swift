import Foundation

nonisolated struct EnrichmentResult: Sendable {
    let coverArtData: Data?
    let coverArtURL: String?
    let musicBrainzID: String?
    let year: String?
    let genre: String?
    let artistBio: String?
    let artistImageURL: String?
    let artistMusicBrainzID: String?
}

final class MetadataEnrichmentService {

    static let shared = MetadataEnrichmentService()

    private let session: URLSession
    private let musicBrainzThrottle = MusicBrainzThrottle()
    private let generalThrottle = GeneralThrottle()

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = [
            "User-Agent": "flaccy/1.0 (https://github.com/guitaripod/flaccy)"
        ]
        session = URLSession(configuration: config)
    }

    func enrichAlbum(title: String, artist: String) async -> EnrichmentResult {
        var coverArtData: Data?
        var coverArtURL: String?
        var musicBrainzID: String?
        var year: String?
        var genre: String?
        var artistBio: String?
        var artistImageURL: String?
        var artistMusicBrainzID: String?

        await generalThrottle.throttle()
        let albumInfo = await LastFMService.shared.fetchAlbumInfo(artist: artist, album: title)
        if let albumInfo {
            coverArtURL = albumInfo.imageURL
            musicBrainzID = albumInfo.musicBrainzID
        }

        if let artURL = coverArtURL {
            coverArtData = await downloadImageData(from: artURL)
        }

        if coverArtData == nil {
            let itunesResult = await fetchiTunesArtwork(artist: artist, album: title)
            if let result = itunesResult {
                coverArtData = result.data
                coverArtURL = result.url
            }
        }

        await generalThrottle.throttle()
        let artistInfo = await LastFMService.shared.fetchArtistInfo(artist: artist)
        if let artistInfo {
            artistBio = artistInfo.bio
            artistImageURL = artistInfo.imageURL
            artistMusicBrainzID = artistInfo.musicBrainzID
        }

        return EnrichmentResult(
            coverArtData: coverArtData,
            coverArtURL: coverArtURL,
            musicBrainzID: musicBrainzID,
            year: year,
            genre: genre,
            artistBio: artistBio,
            artistImageURL: artistImageURL,
            artistMusicBrainzID: artistMusicBrainzID
        )
    }

    private struct MusicBrainzRelease {
        let id: String
        let year: String?
        let genre: String?
    }

    private func fetchMusicBrainzRelease(artist: String, album: String) async -> MusicBrainzRelease? {
        await musicBrainzThrottle.throttle()

        guard let encodedQuery = "release:\(album) AND artist:\(artist)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else {
            return nil
        }

        let urlString = "https://musicbrainz.org/ws/2/release/?query=\(encodedQuery)&limit=1&fmt=json"
        guard let url = URL(string: urlString) else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let releases = json?["releases"] as? [[String: Any]]
            guard let release = releases?.first,
                  let id = release["id"] as? String
            else {
                return nil
            }

            let date = release["date"] as? String
            let year = date.flatMap { String($0.prefix(4)) }

            let tags = release["tags"] as? [[String: Any]]
            let genre = tags?.max(by: {
                ($0["count"] as? Int ?? 0) < ($1["count"] as? Int ?? 0)
            })?["name"] as? String

            return MusicBrainzRelease(id: id, year: year, genre: genre)
        } catch {
            AppLogger.error("MusicBrainz lookup failed: \(error.localizedDescription)", category: .content)
            return nil
        }
    }

    private struct ITunesArtworkResult {
        let data: Data
        let url: String
    }

    private func fetchiTunesArtwork(artist: String, album: String) async -> ITunesArtworkResult? {
        await generalThrottle.throttle()

        guard let encodedTerm = "\(artist) \(album)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else {
            return nil
        }

        let urlString = "https://itunes.apple.com/search?term=\(encodedTerm)&entity=album&limit=1"
        guard let url = URL(string: urlString) else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let results = json?["results"] as? [[String: Any]]

            guard let artworkUrl100 = results?.first?["artworkUrl100"] as? String else {
                return nil
            }

            let highResURL = artworkUrl100.replacingOccurrences(of: "100x100", with: "600x600")
            guard let imageData = await downloadImageData(from: highResURL) else {
                return nil
            }

            return ITunesArtworkResult(data: imageData, url: highResURL)
        } catch {
            AppLogger.error("iTunes lookup failed: \(error.localizedDescription)", category: .content)
            return nil
        }
    }

    private func downloadImageData(from urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return data
        } catch {
            AppLogger.error("Image download failed for \(urlString): \(error.localizedDescription)", category: .content)
            return nil
        }
    }
}

private actor MusicBrainzThrottle {
    private var lastRequest: Date = .distantPast

    func throttle() async {
        let elapsed = Date().timeIntervalSince(lastRequest)
        if elapsed < 1.0 {
            try? await Task.sleep(for: .milliseconds(Int((1.0 - elapsed) * 1000)))
        }
        lastRequest = Date()
    }
}

private actor GeneralThrottle {
    private var lastRequest: Date = .distantPast

    func throttle() async {
        let elapsed = Date().timeIntervalSince(lastRequest)
        if elapsed < 0.2 {
            try? await Task.sleep(for: .milliseconds(Int((0.2 - elapsed) * 1000)))
        }
        lastRequest = Date()
    }
}
