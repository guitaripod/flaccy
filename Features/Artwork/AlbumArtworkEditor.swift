import CoreGraphics
import MidgarCore
import FlaccyCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Saving and clearing a person-chosen cover. The cover is stored under every
/// key a surface can ask for the release by, because tracks look their art up
/// by their own album title and performing artist while album cards use the
/// grouped title and artist.
nonisolated enum AlbumArtworkEditor {

    static let outputPixelSize: CGFloat = 1600
    static let maximumSourcePixels: CGFloat = 3200
    private static let jpegQuality: CGFloat = 0.9

    static func keys(for album: Album) -> [(title: String, artist: String)] {
        var seen = Set<String>()
        var keys: [(title: String, artist: String)] = []
        let candidates = [(album.title, album.artist)] + album.tracks.map { ($0.albumTitle, $0.artist) }
        for (title, artist) in candidates where !title.isEmpty {
            guard seen.insert("\(title)\0\(artist)").inserted else { continue }
            keys.append((title, artist))
        }
        return keys
    }

    static func hasCustomCover(_ album: Album) -> Bool {
        DatabaseManager.shared.hasCustomCover(forKeys: keys(for: album))
    }

    static func hasCustomCover(_ subject: ArtworkSubject) -> Bool {
        switch subject.kind {
        case .album: hasCustomCover(subject.album)
        case .playlist(let id): DatabaseManager.shared.hasPlaylistCover(id: id)
        }
    }

    static func encode(_ image: PlatformImage) -> Data? {
        image.jpegData(compressionQuality: jpegQuality)
    }

    /// Decodes picked or downloaded bytes at no more than the source ceiling,
    /// so a 12000-pixel scan never becomes a 500 MB bitmap.
    static func decodeSource(_ data: Data) -> CGImage? {
        AlbumArtworkCache.decode(data, maxPixelSize: maximumSourcePixels)?.cgImage
    }

    /// The square the person framed, resampled straight from the source with
    /// high-quality filtering and encoded as the JPEG the database stores. The
    /// side never exceeds what the source can supply for that framing.
    static func render(_ image: CGImage, framing: ArtworkFraming) -> Data? {
        let side = framing.outputPixels(limit: Int(outputPixelSize))
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.draw(image, in: drawRect(for: framing, side: Double(side)))
        guard let output = context.makeImage() else { return nil }
        return jpegData(from: output)
    }

    /// Where the whole source lands in the output square. Core Graphics counts
    /// y from the bottom while the framing counts it from the top, so the
    /// source's top edge sits `visibleY` scaled pixels above the output's.
    static func drawRect(for framing: ArtworkFraming, side: Double) -> CGRect {
        let scale = side / framing.visibleSide
        let width = framing.imageWidth * scale
        let height = framing.imageHeight * scale
        return CGRect(
            x: -framing.visibleX * scale,
            y: side + framing.visibleY * scale - height,
            width: width,
            height: height
        )
    }

    private static func jpegData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
        ] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func save(_ data: Data, for subject: ArtworkSubject) throws {
        switch subject.kind {
        case .album:
            try save(data, for: subject.album)
        case .playlist(let id):
            try DatabaseManager.shared.savePlaylistCover(data, id: id)
            AlbumArtworkCache.shared.invalidate(keys: [(subject.cacheTitle, subject.cacheArtist)])
            MidgarLog.info("Custom cover saved for playlist \(subject.title) (\(data.count / 1024) KB)", category: .content)
        }
    }

    static func reset(_ subject: ArtworkSubject) throws {
        switch subject.kind {
        case .album:
            try reset(subject.album)
        case .playlist(let id):
            try DatabaseManager.shared.clearPlaylistCover(id: id)
            AlbumArtworkCache.shared.invalidate(keys: [(subject.cacheTitle, subject.cacheArtist)])
            MidgarLog.info("Custom cover cleared for playlist \(subject.title)", category: .content)
        }
    }

    static func save(_ data: Data, for album: Album) throws {
        let keys = keys(for: album)
        try DatabaseManager.shared.saveCustomCover(data, forKeys: keys)
        refreshSurfaces(for: keys)
        MidgarLog.info("Custom cover saved for \(album.title) (\(data.count / 1024) KB)", category: .content)
    }

    static func reset(_ album: Album) throws {
        let keys = keys(for: album)
        try DatabaseManager.shared.clearCustomCover(forKeys: keys)
        refreshSurfaces(for: keys)
        MidgarLog.info("Custom cover cleared for \(album.title)", category: .content)
    }

    private static func refreshSurfaces(for keys: [(title: String, artist: String)]) {
        for key in keys {
            ArtworkPaletteExtractor.invalidate(title: key.title, artist: key.artist)
        }
        AlbumArtworkCache.shared.invalidate(keys: keys)
    }
}

/// What the artwork editor is choosing a cover for: a release, or a playlist.
/// A playlist is addressed in the artwork cache by the reserved key
/// `PlaylistCover` defines, and carries a stand-in `Album` holding its tracks so
/// the folder and tag finders can read their files like a release's.
nonisolated struct ArtworkSubject: Sendable {

    enum Kind: Sendable {
        case album
        case playlist(id: Int64)
    }

    let kind: Kind
    let title: String
    let credit: String
    let album: Album

    init(album: Album) {
        kind = .album
        title = album.title
        credit = album.artist
        self.album = album
    }

    init(playlistId: Int64, name: String, tracks: [Track]) {
        kind = .playlist(id: playlistId)
        title = name
        credit = ""
        album = Album(title: name, artist: "", artwork: nil, tracks: tracks, year: nil, genre: nil)
    }

    var isPlaylist: Bool {
        if case .playlist = kind { return true }
        return false
    }

    var tracks: [Track] { album.tracks }

    var cacheTitle: String {
        if case .playlist(let id) = kind { return PlaylistCover.title(forPlaylist: id) }
        return title
    }

    var cacheArtist: String { isPlaylist ? PlaylistCover.artist : credit }

    /// The line under the sheet's title: the artist for a release, the track
    /// count for a playlist.
    var subtitle: String {
        isPlaylist ? String(localized: "Playlist · \(tracks.count) tracks") : "\(title) · \(credit)"
    }

    /// What the online search starts with. A playlist's name matches no
    /// catalog entry, so its search starts empty and waits for the person.
    var defaultQuery: String {
        isPlaylist ? "" : OnlineArtworkSearch.defaultQuery(title: title, artist: credit)
    }
}

nonisolated struct ArtworkCandidate: Sendable, Hashable, Identifiable {
    let id: String
    let source: String
    let title: String
    let artist: String
    let thumbnailURL: URL
    let fullURL: URL
    let score: Double
}

nonisolated struct ArtworkSearchResult: Sendable {
    let candidates: [ArtworkCandidate]
    let reachedAnyProvider: Bool
}

/// Finds higher-resolution covers for a release from the three catalogs that
/// serve square artwork without a key. Results are scored on how closely the
/// catalog's title and artist match the release so the right cover leads.
nonisolated enum OnlineArtworkSearch {

    static let userAgent = "flaccy/1.0 (https://github.com/guitaripod/flaccy)"
    static let maximumBodyBytes = 25 * 1024 * 1024
    static let resultCap = 18
    static let confidentScore = 0.5
    static let confidentMinimum = 3

    private static let fetcher = BoundedHTTPSFetcher(maximumBytes: maximumBodyBytes)

    /// What the search field starts with: the artist and the title, without a
    /// credit no catalog could match.
    static func defaultQuery(title: String, artist: String) -> String {
        "\(creditedArtist(artist)) \(title)".trimmingCharacters(in: .whitespaces)
    }

    static func search(title: String, artist: String) async -> [ArtworkCandidate] {
        await lookup(query: defaultQuery(title: title, artist: artist), title: title, artist: artist).candidates
    }

    /// Runs one search across every provider. `query` is what the person typed;
    /// while it is still the default the providers are asked field by field and
    /// the weak matches are dropped, and once it has been edited they are asked
    /// for exactly those words and everything they return is kept.
    static func lookup(query: String, title: String, artist: String) async -> ArtworkSearchResult {
        let credit = creditedArtist(artist)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let edited = trimmed != defaultQuery(title: title, artist: artist)
        async let apple = appleCandidates(term: trimmed, title: title, artist: credit)
        async let deezer = deezerCandidates(query: edited ? trimmed : nil, title: title, artist: credit)
        async let archive = coverArchiveCandidates(query: edited ? trimmed : nil, title: title, artist: credit)
        let answers = await [apple, deezer, archive]
        let merged = answers.flatMap { $0 ?? [] }
        return ArtworkSearchResult(
            candidates: rank(merged, keepOnlyConfident: !edited),
            reachedAnyProvider: answers.contains { $0 != nil }
        )
    }

    static func download(_ url: URL) async throws -> PlatformImage {
        let data = try await fetcher.fetch(url)
        guard let image = AlbumArtworkCache.decode(data, maxPixelSize: AlbumArtworkEditor.maximumSourcePixels)
        else { throw URLError(.cannotDecodeContentData) }
        return image
    }

    /// The raw bytes of a picture from an address a person pasted or dragged
    /// in, under the same HTTPS-only, time and size limits as the catalogs.
    static func fetchData(from url: URL) async throws -> Data {
        try await fetcher.fetch(url)
    }

    static func downloadThumbnail(_ url: URL) async -> PlatformImage? {
        guard let data = try? await fetcher.fetch(url) else { return nil }
        return AlbumArtworkCache.decode(data, maxPixelSize: 360)
    }

    /// Duplicates by full-size URL collapse to the first, the best score leads,
    /// and a field-by-field search keeps only confident matches when there are
    /// enough of them to fill a shelf.
    static func rank(_ merged: [ArtworkCandidate], keepOnlyConfident: Bool) -> [ArtworkCandidate] {
        var seen = Set<URL>()
        let unique = merged.filter { seen.insert($0.fullURL).inserted }
        let ranked = unique.enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element)
        let confident = ranked.filter { $0.score >= confidentScore }
        let kept = keepOnlyConfident && confident.count >= confidentMinimum ? confident : ranked
        return Array(kept.prefix(resultCap))
    }

    private static func creditedArtist(_ artist: String) -> String {
        artist.caseInsensitiveCompare("Various Artists") == .orderedSame ? "" : artist
    }

    private static func appleCandidates(term: String, title: String, artist: String) async -> [ArtworkCandidate]? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "20"),
        ]
        guard let url = components?.url, let data = try? await fetcher.fetch(url) else { return nil }
        return appleCandidates(from: data, title: title, artist: artist)
    }

    private static func deezerCandidates(query: String?, title: String, artist: String) async -> [ArtworkCandidate]? {
        var components = URLComponents(string: "https://api.deezer.com/search/album")
        let fielded = artist.isEmpty ? title : "artist:\"\(artist)\" album:\"\(title)\""
        components?.queryItems = [
            URLQueryItem(name: "q", value: query ?? fielded),
            URLQueryItem(name: "limit", value: "12"),
        ]
        guard let url = components?.url, let data = try? await fetcher.fetch(url) else { return nil }
        return deezerCandidates(from: data, title: title, artist: artist)
    }

    private static func coverArchiveCandidates(query: String?, title: String, artist: String) async -> [ArtworkCandidate]? {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release-group/")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query.map(escapedLucene) ?? musicBrainzQuery(title: title, artist: artist)),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "8"),
        ]
        guard let url = components?.url,
              let data = try? await fetcher.fetch(url, headers: ["User-Agent": userAgent, "Accept": "application/json"])
        else { return nil }
        return coverArchiveCandidates(from: data, title: title, artist: artist)
    }

    /// The release-group search as MusicBrainz's Lucene syntax wants it, with
    /// the quote and escape characters in the names neutralised.
    static func musicBrainzQuery(title: String, artist: String) -> String {
        let group = "releasegroup:\"\(escapedQuoted(title))\""
        guard !artist.isEmpty else { return group }
        return "\(group) AND artist:\"\(escapedQuoted(artist))\""
    }

    private static func escapedQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func escapedLucene(_ value: String) -> String {
        let special = Set("+-&|!(){}[]^\"~*?:\\/")
        return value.map { special.contains($0) ? "\\\($0)" : String($0) }.joined()
    }

    static func appleCandidates(from data: Data, title: String, artist: String) -> [ArtworkCandidate] {
        guard let response = try? JSONDecoder().decode(AppleResponse.self, from: data) else { return [] }
        return response.results.compactMap { item in
            guard let small = item.artworkUrl100,
                  let thumbnail = URL(string: small.replacingOccurrences(of: "100x100bb", with: "360x360bb")),
                  let full = URL(string: small.replacingOccurrences(of: "100x100bb", with: "3000x3000bb"))
            else { return nil }
            return ArtworkCandidate(
                id: "apple-\(item.collectionId ?? 0)",
                source: "Apple Music",
                title: item.collectionName ?? "",
                artist: item.artistName ?? "",
                thumbnailURL: thumbnail,
                fullURL: full,
                score: score(candidateTitle: item.collectionName ?? "", candidateArtist: item.artistName ?? "", title: title, artist: artist)
            )
        }
    }

    static func deezerCandidates(from data: Data, title: String, artist: String) -> [ArtworkCandidate] {
        guard let response = try? JSONDecoder().decode(DeezerResponse.self, from: data) else { return [] }
        return response.data.compactMap { item in
            guard let thumbnail = item.cover_medium.flatMap(URL.init(string:)),
                  let full = (item.cover_xl ?? item.cover_big).flatMap(URL.init(string:))
            else { return nil }
            return ArtworkCandidate(
                id: "deezer-\(item.id)",
                source: "Deezer",
                title: item.title,
                artist: item.artist?.name ?? "",
                thumbnailURL: thumbnail,
                fullURL: full,
                score: score(candidateTitle: item.title, candidateArtist: item.artist?.name ?? "", title: title, artist: artist)
            )
        }
    }

    /// Many release groups have no front cover, so their thumbnails 404 and the
    /// shelf drops the tile; the ones that do have one answer at both sizes.
    static func coverArchiveCandidates(from data: Data, title: String, artist: String) -> [ArtworkCandidate] {
        guard let response = try? JSONDecoder().decode(MusicBrainzResponse.self, from: data) else { return [] }
        return response.releaseGroups.compactMap { group in
            guard let thumbnail = URL(string: "https://coverartarchive.org/release-group/\(group.id)/front-250"),
                  let full = URL(string: "https://coverartarchive.org/release-group/\(group.id)/front-1200")
            else { return nil }
            let credit = group.credit
            return ArtworkCandidate(
                id: "caa-\(group.id)",
                source: "Cover Art Archive",
                title: group.title,
                artist: credit,
                thumbnailURL: thumbnail,
                fullURL: full,
                score: score(candidateTitle: group.title, candidateArtist: credit, title: title, artist: artist)
            )
        }
    }

    /// Title carries most of the weight; an exact edition-folded title match is
    /// worth far more than a substring, and the artist breaks ties between
    /// different records that share a name.
    static func score(candidateTitle: String, candidateArtist: String, title: String, artist: String) -> Double {
        let wanted = LibraryHygiene.baseTitle(title)
        let found = LibraryHygiene.baseTitle(candidateTitle)
        var titleScore = 0.0
        if wanted == found {
            titleScore = 0.7
        } else if !wanted.isEmpty, !found.isEmpty, found.contains(wanted) || wanted.contains(found) {
            titleScore = 0.4
        }
        let artistScore: Double
        if artist.isEmpty {
            artistScore = 0.15
        } else {
            artistScore = LibraryHygiene.artistKey(candidateArtist) == LibraryHygiene.artistKey(artist) ? 0.3 : 0
        }
        return titleScore + artistScore
    }

    private struct AppleResponse: Decodable {
        struct Item: Decodable {
            let collectionId: Int?
            let collectionName: String?
            let artistName: String?
            let artworkUrl100: String?
        }
        let results: [Item]
    }

    private struct DeezerResponse: Decodable {
        struct Artist: Decodable { let name: String }
        struct Item: Decodable {
            let id: Int
            let title: String
            let artist: Artist?
            let cover_medium: String?
            let cover_big: String?
            let cover_xl: String?
        }
        let data: [Item]
    }

    private struct MusicBrainzResponse: Decodable {
        struct Credit: Decodable {
            let name: String?
            let joinphrase: String?
            let artist: Artist?
            struct Artist: Decodable { let name: String? }
        }
        struct Group: Decodable {
            let id: String
            let title: String
            let artistCredit: [Credit]?

            enum CodingKeys: String, CodingKey {
                case id, title
                case artistCredit = "artist-credit"
            }

            var credit: String {
                (artistCredit ?? []).map { ($0.name ?? $0.artist?.name ?? "") + ($0.joinphrase ?? "") }.joined()
            }
        }
        let releaseGroups: [Group]

        enum CodingKeys: String, CodingKey {
            case releaseGroups = "release-groups"
        }
    }
}

/// Fetches over HTTPS only, refuses a redirect to anything else, gives up on a
/// body past the cap while it is still arriving, and treats every status but
/// 200 as a failure. One session serves every request; per-request state is
/// kept by task identifier.
nonisolated final class BoundedHTTPSFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    enum Failure: Error {
        case insecure
        case badStatus(Int)
        case tooLarge
    }

    private struct Pending {
        var data = Data()
        var failure: Failure?
        let continuation: CheckedContinuation<Data, Error>
    }

    private let maximumBytes: Int
    private let lock = NSLock()
    private var pending = [Int: Pending]()
    private var session: URLSession!

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func fetch(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw Failure.insecure }
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                pending[task.taskIdentifier] = Pending(continuation: continuation)
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            fail(dataTask, with: .badStatus(status))
            completionHandler(.cancel)
        } else if response.expectedContentLength > Int64(maximumBytes) {
            fail(dataTask, with: .tooLarge)
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        pending[dataTask.taskIdentifier]?.data.append(data)
        let size = pending[dataTask.taskIdentifier]?.data.count ?? 0
        lock.unlock()
        if size > maximumBytes {
            fail(dataTask, with: .tooLarge)
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if request.url?.scheme?.lowercased() == "https" {
            completionHandler(request)
        } else {
            fail(task, with: .insecure)
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let finished = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let finished else { return }
        if let failure = finished.failure {
            finished.continuation.resume(throwing: failure)
        } else if let error {
            finished.continuation.resume(throwing: error)
        } else {
            finished.continuation.resume(returning: finished.data)
        }
    }

    private func fail(_ task: URLSessionTask, with failure: Failure) {
        lock.lock()
        if pending[task.taskIdentifier]?.failure == nil {
            pending[task.taskIdentifier]?.failure = failure
        }
        lock.unlock()
    }
}
