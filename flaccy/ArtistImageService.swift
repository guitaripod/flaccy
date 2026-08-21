import FlaccyCore
import UIKit

/// Resolves a representative artist photo with the chain: memory/disk cache →
/// the photo URL the library already holds → Apple Music catalog artwork →
/// Last.fm / Deezer (rejecting Last.fm's star placeholder) → nil.
///
/// A miss is durable. It used to live in an `NSCache` with a 30-minute TTL,
/// which meant every launch re-issued an Apple Music search *and* an
/// `artist.getInfo` for every artist in the library that has no photo anywhere.
/// The answer now goes into `enrichmentState` under `EnrichmentScope.artist`,
/// so an artist nobody has a picture of is asked about four times in total
/// rather than four times a day — and a failure that never reached a source
/// costs nothing, because the classification comes from
/// `MetadataEnrichmentService` rather than from an optional being nil.
final class ArtistImageService {

    static let shared = ArtistImageService()

    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    nonisolated private static let downloadSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    private init() {}

    func image(for artist: String) async -> UIImage? {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = cacheKey(for: trimmed)

        if let cached = ImageCache.shared.image(forKey: key) {
            return cached
        }
        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task { await Self.resolve(artist: trimmed) }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil

        if let image {
            ImageCache.shared.store(image, forKey: key)
        }
        return image
    }

    private func cacheKey(for artist: String) -> String {
        "artist-photo|\(artist.lowercased())"
    }

    nonisolated private static func resolve(artist: String) async -> UIImage? {
        let db = DatabaseManager.shared
        let key = EnrichmentKey.artist(artist)
        let record = try? db.fetchEnrichmentRecord(scope: .artist, key: key)

        if let stored = try? db.fetchArtist(name: artist)?.imageURL,
           let image = await download(stored) {
            return image
        }
        guard !isSettledMiss(record, now: Date()) else {
            AppLogger.debug("Artist photo settled as missing for \(artist)", category: .content)
            return nil
        }
        return await lookUp(artist: artist, key: key, record: record)
    }

    /// True when the job has already asked every source and either has not
    /// earned another attempt yet or has burned all of them. Only ever consulted
    /// for a record that carries no `.artistImage`: a record that *does* means a
    /// photo exists and is worth fetching again, however empty the disk cache is.
    nonisolated private static func isSettledMiss(_ record: EnrichmentRecord?, now: Date) -> Bool {
        guard let record, !record.fields.contains(.artistImage) else { return false }
        return !EnrichmentPolicy.isDue(record, scope: .artist, now: now)
    }

    /// One attempt across every source, persisted as one attempt. Apple Music is
    /// asked first because its portraits are the best of the three, and it
    /// answers with bytes rather than a URL — so a hit there resolves
    /// `.artistImage` without anything to write into `artists.imageURL`.
    nonisolated private static func lookUp(
        artist: String, key: String, record: EnrichmentRecord?
    ) async -> UIImage? {
        var state = record ?? EnrichmentRecord(scope: .artist, key: key)
        let present = state.fields
        var image: UIImage?

        if await isAppleMusicUsable(), let data = await MusicKitService.shared.fetchArtistImage(artist: artist) {
            image = UIImage(data: data)
        }

        let (fields, failure, values) = await MetadataEnrichmentService.shared.enrichArtist(
            name: artist, resolved: present
        )
        if image == nil, let url = values.imageURL {
            image = await download(url)
        }

        let resolved = image == nil ? fields : fields.union(.artistImage)
        EnrichmentPolicy.apply(
            to: &state, scope: .artist, resolved: resolved,
            failure: image == nil ? failure : nil, now: Date()
        )

        do {
            try DatabaseManager.shared.applyArtistEnrichment(
                name: artist, bio: values.bio, imageURL: values.imageURL,
                musicBrainzID: values.musicBrainzID, record: state
            )
        } catch {
            AppLogger.error("Artist photo state not saved: \(error.localizedDescription)", category: .database)
        }

        if image != nil {
            AppLogger.debug("Artist photo resolved for \(artist)", category: .content)
        } else {
            AppLogger.debug("No artist photo found for \(artist)", category: .content)
        }
        return image
    }

    /// Apple Music is asked only once somebody has opted in and the system has
    /// already granted access. Calling `fetchArtistImage` without this gate would
    /// raise `MusicAuthorization.request()` out of a scrolling artist list.
    nonisolated private static func isAppleMusicUsable() async -> Bool {
        guard AppleMusicArtworkSetting.isEnabled else { return false }
        return await MusicKitService.isAlreadyAuthorized()
    }

    nonisolated private static func download(_ urlString: String) async -> UIImage? {
        guard !isPlaceholder(urlString), let url = URL(string: urlString) else { return nil }
        do {
            let (data, response) = try await downloadSession.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return UIImage(data: data)
        } catch {
            AppLogger.error("Artist image download failed: \(error.localizedDescription)", category: .content)
            return nil
        }
    }

    /// Last.fm serves a generic white-star image for artists without real
    /// photos; its URL always carries this content hash.
    nonisolated private static func isPlaceholder(_ urlString: String) -> Bool {
        urlString.contains(lastFMPlaceholderHash)
    }

    nonisolated private static let lastFMPlaceholderHash = "2a96cbd8b46e442fc41c2b86b821562f"
}
