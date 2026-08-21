import Foundation

nonisolated struct AlbumEnrichmentValues: Sendable {
    let coverArtURL: String?
    let coverArtData: Data?
    let musicBrainzID: String?
    let year: String?
    let genre: String?
}

nonisolated struct ArtistEnrichmentValues: Sendable {
    let bio: String?
    let imageURL: String?
    let musicBrainzID: String?

    static let empty = ArtistEnrichmentValues(bio: nil, imageURL: nil, musicBrainzID: nil)
}

/// Turns a thrown networking error into the enrichment vocabulary.
///
/// Everything that throws is `.transport`, deliberately: an attempt that never
/// reached a source must not count towards the four an album gets before it is
/// written off as `.exhausted`. The four codes the classification names —
/// `.notConnectedToInternet`, `.timedOut`, `.networkConnectionLost` and
/// `.cannotFindHost` — are logged by name so an offline pass is recognisable in
/// the log file rather than being a wall of identical lines.
nonisolated enum EnrichmentFailureClassifier {

    static func classify(_ error: Error) async -> EnrichmentFailure {
        guard let urlError = error as? URLError else { return .transport }
        await AppLogger.debug("Enrichment transport failure: \(describe(urlError))", category: .content)
        return .transport
    }

    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet: return "not connected to the internet"
        case .timedOut: return "timed out"
        case .networkConnectionLost: return "network connection lost"
        case .cannotFindHost: return "cannot find host"
        default: return "URLError \(error.code.rawValue)"
        }
    }
}

/// One source's answer. `.empty` is the source saying it has nothing, which may
/// cost the entity an attempt; `.failed` is the source not answering, which
/// never does. `EnrichmentFailure` is not an `Error`, so this is the vocabulary
/// rather than `Result`.
nonisolated enum EnrichmentSourceOutcome<Value: Sendable>: Sendable {
    case value(Value)
    case empty
    case failed(EnrichmentFailure)
}

nonisolated final class MetadataEnrichmentService: Sendable {

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

    /// Chases everything `resolved` does not already cover, returning the
    /// `(EnrichmentFields, EnrichmentFailure?)` pair `EnrichmentPolicy.apply`
    /// consumes together with the values the caller writes in its own single
    /// transaction. This service never touches the database.
    func enrichAlbum(
        title: String,
        artist: String,
        resolved: EnrichmentFields
    ) async -> (fields: EnrichmentFields, failure: EnrichmentFailure?, values: AlbumEnrichmentValues) {
        var report = FailureReport()
        var coverArtURL: String?
        var coverArtData: Data?
        var musicBrainzID: String?
        var year: String?
        var genre: String?

        let coverAlreadyStored = resolved.contains(.cover)

        await generalThrottle.throttle()
        switch await LastFMService.shared.classifiedAlbumInfo(artist: artist, album: title) {
        case .value(let info):
            coverArtURL = info.imageURL
            musicBrainzID = info.musicBrainzID
        case .empty:
            break
        case .failed(let failure):
            report.note(failure)
        }

        if !coverAlreadyStored, let url = coverArtURL {
            coverArtData = await download(from: url, into: &report)
        }

        var needsCover: Bool { !coverAlreadyStored && coverArtData == nil }

        let outstanding = Self.outstandingAlbumFields(
            resolved: resolved,
            hasCover: !needsCover,
            hasYear: year != nil,
            hasGenre: genre != nil,
            hasMBID: musicBrainzID != nil
        )

        if !outstanding.isEmpty {
            switch await fetchMusicBrainzRelease(artist: artist, album: title) {
            case .value(let release):
                if musicBrainzID == nil { musicBrainzID = release.id }
                year = release.year
                genre = release.genre
                if needsCover {
                    coverArtData = await coverArtArchiveImage(for: release, into: &report)
                }
            case .empty:
                break
            case .failed(let failure):
                report.note(failure)
            }
        }

        if needsCover {
            switch await fetchDeezerAlbumCoverURL(artist: artist, album: title) {
            case .value(let url):
                coverArtData = await download(from: url, into: &report)
            case .empty:
                break
            case .failed(let failure):
                report.note(failure)
            }
        }

        if needsCover, let data = await MusicKitService.shared.artworkForEnrichment(title: title, artist: artist) {
            coverArtData = data
        }

        var fields: EnrichmentFields = []
        if coverArtData != nil { fields.insert(.cover) }
        if year != nil { fields.insert(.year) }
        if genre != nil { fields.insert(.genre) }
        if musicBrainzID != nil { fields.insert(.mbid) }

        let satisfied = resolved.union(fields)
            .isSuperset(of: EnrichmentFields.required(for: .album))

        return (
            fields: fields,
            failure: report.verdict(satisfied: satisfied),
            values: AlbumEnrichmentValues(
                coverArtURL: coverArtURL,
                coverArtData: coverArtData,
                musicBrainzID: musicBrainzID,
                year: year,
                genre: genre
            )
        )
    }

    /// The artist entry point, split out so an artist is looked up once ever
    /// rather than once per album that happens to belong to them.
    func enrichArtist(
        name: String,
        resolved: EnrichmentFields
    ) async -> (fields: EnrichmentFields, failure: EnrichmentFailure?, values: ArtistEnrichmentValues) {
        guard !name.isEmpty else { return (fields: [], failure: nil, values: .empty) }

        var report = FailureReport()
        var bio: String?
        var imageURL: String?
        var musicBrainzID: String?

        await generalThrottle.throttle()
        switch await LastFMService.shared.classifiedArtistInfo(artist: name) {
        case .value(let info):
            bio = info.bio
            musicBrainzID = info.musicBrainzID
            imageURL = info.imageURL.flatMap { Self.isLastFMPlaceholder($0) ? nil : $0 }
        case .empty:
            break
        case .failed(let failure):
            report.note(failure)
        }

        switch await fetchDeezerArtistImageURL(name: name) {
        case .value(let url):
            imageURL = url
        case .empty:
            break
        case .failed(let failure):
            report.note(failure)
        }

        var fields: EnrichmentFields = []
        if bio != nil { fields.insert(.artistBio) }
        if imageURL != nil { fields.insert(.artistImage) }

        let satisfied = resolved.union(fields)
            .isSuperset(of: EnrichmentFields.required(for: .artist))

        return (
            fields: fields,
            failure: report.verdict(satisfied: satisfied),
            values: ArtistEnrichmentValues(bio: bio, imageURL: imageURL, musicBrainzID: musicBrainzID)
        )
    }

    /// MusicBrainz is the slowest source — a hard 1 rps — and the only one that
    /// answers year and genre, so it is asked whenever any of the four things it
    /// can contribute is still missing and skipped entirely when none is.
    private static func outstandingAlbumFields(
        resolved: EnrichmentFields,
        hasCover: Bool,
        hasYear: Bool,
        hasGenre: Bool,
        hasMBID: Bool
    ) -> EnrichmentFields {
        var have = resolved
        if hasCover { have.insert(.cover) }
        if hasYear { have.insert(.year) }
        if hasGenre { have.insert(.genre) }
        if hasMBID { have.insert(.mbid) }
        return EnrichmentFields([.cover, .year, .genre, .mbid]).subtracting(have)
    }

    /// Accumulates what went wrong across the sources one attempt consults, so
    /// the entity is charged for exactly one outcome. Order matters: a rate
    /// limit defers, a transport failure costs nothing, and only a run in which
    /// every source genuinely answered may report `.notFound` and burn an
    /// attempt.
    private struct FailureReport {
        private var rateLimited = false
        private var transport = false
        private var unauthorized = false

        mutating func note(_ failure: EnrichmentFailure) {
            switch failure {
            case .rateLimited: rateLimited = true
            case .transport: transport = true
            case .unauthorized: unauthorized = true
            case .notFound: break
            }
        }

        func verdict(satisfied: Bool) -> EnrichmentFailure? {
            if satisfied { return nil }
            if rateLimited { return .rateLimited }
            if transport { return .transport }
            if unauthorized { return .unauthorized }
            return .notFound
        }
    }

    private struct MusicBrainzRelease: Sendable {
        let id: String
        let releaseGroupID: String?
        let year: String?
        let genre: String?
    }

    private func fetchMusicBrainzRelease(
        artist: String, album: String
    ) async -> EnrichmentSourceOutcome<MusicBrainzRelease> {
        await musicBrainzThrottle.throttle()

        let query = "release:\(album) AND artist:\(artist)"
        guard let url = URL(
            string: "https://musicbrainz.org/ws/2/release/?query=\(Self.percentEncode(query))&limit=1&fmt=json"
        ) else { return .empty }

        return await fetchJSON(from: url) { json in
            guard let release = (json["releases"] as? [[String: Any]])?.first,
                  let id = release["id"] as? String
            else { return nil }

            let date = release["date"] as? String
            let tags = release["tags"] as? [[String: Any]]
            return MusicBrainzRelease(
                id: id,
                releaseGroupID: (release["release-group"] as? [String: Any])?["id"] as? String,
                year: date.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil },
                genre: tags?.max(by: {
                    ($0["count"] as? Int ?? 0) < ($1["count"] as? Int ?? 0)
                })?["name"] as? String
            )
        }
    }

    /// Cover Art Archive front cover, release-group first because it is the
    /// edition-independent artwork and a library rarely holds the exact release
    /// MusicBrainz ranked first.
    private func coverArtArchiveImage(
        for release: MusicBrainzRelease, into report: inout FailureReport
    ) async -> Data? {
        if let group = release.releaseGroupID,
           let data = await download(
               from: "https://coverartarchive.org/release-group/\(group)/front-500", into: &report
           ) {
            return data
        }
        return await download(
            from: "https://coverartarchive.org/release/\(release.id)/front-500", into: &report
        )
    }

    /// Deezer's keyless album search — a broad streaming catalogue that covers
    /// many releases MusicBrainz and Cover Art Archive do not.
    private func fetchDeezerAlbumCoverURL(artist: String, album: String) async -> EnrichmentSourceOutcome<String> {
        await generalThrottle.throttle()

        let query = "artist:\"\(artist)\" album:\"\(album)\""
        guard let url = URL(
            string: "https://api.deezer.com/search/album?q=\(Self.percentEncode(query))&limit=1"
        ) else { return .empty }

        return await fetchJSON(from: url) { json in
            guard let first = (json["data"] as? [[String: Any]])?.first else { return nil }
            return Self.nonEmptyString(first["cover_xl"]) ?? Self.nonEmptyString(first["cover_big"])
        }
    }

    /// Deezer's keyless artist search — a real portrait source, unlike Last.fm,
    /// which now serves the same star placeholder for every artist.
    private func fetchDeezerArtistImageURL(name: String) async -> EnrichmentSourceOutcome<String> {
        await generalThrottle.throttle()

        guard let url = URL(
            string: "https://api.deezer.com/search/artist?q=\(Self.percentEncode(name))&limit=1"
        ) else { return .empty }

        return await fetchJSON(from: url) { json in
            guard let first = (json["data"] as? [[String: Any]])?.first else { return nil }
            return Self.nonEmptyString(first["picture_xl"]) ?? Self.nonEmptyString(first["picture_big"])
        }
    }

    private func download(from urlString: String, into report: inout FailureReport) async -> Data? {
        switch await downloadImage(from: urlString) {
        case .value(let data): return data
        case .empty: return nil
        case .failed(let failure):
            report.note(failure)
            return nil
        }
    }

    private func downloadImage(from urlString: String) async -> EnrichmentSourceOutcome<Data> {
        guard let url = URL(string: urlString) else { return .empty }
        await generalThrottle.throttle()

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { return .failed(.transport) }
            switch http.statusCode {
            case 200...299: return data.isEmpty ? .empty : .value(data)
            case 404, 410: return .empty
            case 429: return .failed(.rateLimited)
            default: return .failed(.transport)
            }
        } catch {
            return .failed(await EnrichmentFailureClassifier.classify(error))
        }
    }

    /// Fetches and decodes one JSON source. `parse` runs on the decoded body
    /// inside this call so the untyped dictionary never leaves the function, and
    /// a body that will not decode is `.failed(.transport)` rather than an
    /// answer — an HTML login page must never write an album off.
    private func fetchJSON<Value: Sendable>(
        from url: URL,
        parse: @Sendable ([String: Any]) -> Value?
    ) async -> EnrichmentSourceOutcome<Value> {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { return .failed(.transport) }
            switch http.statusCode {
            case 200...299: break
            case 404, 410: return .empty
            case 429: return .failed(.rateLimited)
            default: return .failed(.transport)
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failed(.transport)
            }
            guard let value = parse(json) else { return .empty }
            return .value(value)
        } catch {
            return .failed(await EnrichmentFailureClassifier.classify(error))
        }
    }

    /// Last.fm serves a generic white-star image for artists without real
    /// photos; its URL always carries this content hash.
    private static let lastFMPlaceholderHash = "2a96cbd8b46e442fc41c2b86b821562f"

    private static func isLastFMPlaceholder(_ urlString: String) -> Bool {
        urlString.contains(lastFMPlaceholderHash)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    /// `.urlQueryAllowed` leaves `&`, `+` and `=` untouched, which silently
    /// truncates the query for every album or artist whose name contains one —
    /// "Simon & Garfunkel" being the obvious case.
    private static let queryAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#")
        return allowed
    }()

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? value
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
