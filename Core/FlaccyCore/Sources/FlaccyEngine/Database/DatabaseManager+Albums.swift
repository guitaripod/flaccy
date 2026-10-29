import Foundation
import MidgarCore
import FlaccyCore
import GRDB

extension DatabaseManager {

    /// Normalizes album+lead-artist into a grouping key so tracks whose titles
    /// differ only by case/punctuation, or whose ARTIST tags carry per-track
    /// featuring credits ("50 Cent Feat. Eminem"), still collapse into one album.
    /// Groups on the release *credit*, not the performing artist, so a
    /// compilation is one album rather than one per performer. `credit` is the
    /// settled `albumArtist`; a row `resolveAlbumCredits()` has not reached yet
    /// falls back to its own artist, which is the grouping that predates
    /// compilations.
    /// An album's metadata row, resolved field by field rather than row by row.
    ///
    /// A compilation is credited to someone no metadata provider has ever heard
    /// of ("Various Artists"), so enrichment keeps asking under the performing
    /// artists and the answers land on *their* rows. The credited release still
    /// gets a row of its own — it is where the adopted cover lives — and taking
    /// that row whole would hand the album a nil year while the real one sits
    /// one row over, which is exactly how a soundtrack lost its 2007 the moment
    /// it gained its cover.
    private static func albumInfo(
        title: String,
        credit: String,
        tracks: [LightTrackRecord],
        rows: [String: AlbumInfoRecord]
    ) -> AlbumInfoRecord? {
        let keys = ["\(title)\0\(credit)"] + tracks.map { "\($0.albumTitle)\0\($0.artist)" }
        var resolved: AlbumInfoRecord?
        for key in keys {
            guard let row = rows[key] else { continue }
            guard var merged = resolved else {
                resolved = row
                continue
            }
            if merged.year == nil { merged.year = row.year }
            if merged.genre == nil { merged.genre = row.genre }
            if merged.coverArtURL == nil { merged.coverArtURL = row.coverArtURL }
            if merged.musicBrainzID == nil { merged.musicBrainzID = row.musicBrainzID }
            resolved = merged
            if merged.year != nil, merged.genre != nil, merged.coverArtURL != nil { break }
        }
        return resolved
    }

    static func albumGroupingKey(albumTitle: String, credit: String) -> String {
        func norm(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        return "\(norm(albumTitle))\u{0}\(LibraryHygiene.artistKey(credit))"
    }

    /// Loads every album as a raw pressings-level group (exact album title +
    /// artist). Edition folding happens in `LibraryHygiene.consolidateAlbums`
    /// after these light records become `Track`s, so quality ranking and
    /// `duplicateKey` dedupe stay in one place shared with Linux.
    ///
    /// The album details come from `albumInfo_on_title_artist_details` alone.
    /// The table stores each cover ahead of the year and genre, so reading them
    /// from the rows walks every cover's overflow pages, about 150 MB for a
    /// thousand albums on a cold launch.
    public func fetchAlbumsWithTracksLightweight() throws -> [(album: AlbumInfoRecord?, tracks: [LightTrackRecord])] {
        try dbQueue.read { db in
            let columns: [Column] = [
                Column("id"), Column("fileURL"), Column("title"), Column("artist"),
                Column("albumTitle"), Column("albumArtist"), Column("trackNumber"), Column("duration"),
                Column("dateAdded"), Column("lastPlayed"), Column("playCount"),
                Column("loved"), Column("codec"), Column("bitDepth"),
                Column("sampleRate"), Column("channels"),
                Column("fileModifiedMs"), Column("revision"), Column("revisedAt"),
            ]

            let allTracks = try LightTrackRecord.fetchAll(db,
                TrackRecord.select(columns)
                    .order(Column("albumTitle").collating(.localizedCaseInsensitiveCompare).asc,
                           Column("artist").collating(.localizedCaseInsensitiveCompare).asc,
                           Column("trackNumber").asc,
                           Column("title").collating(.localizedCaseInsensitiveCompare).asc)
            )

            let allAlbumInfos = try Row.fetchAll(db, sql: """
                SELECT id, title, artist, coverArtURL, musicBrainzID, year, genre, lastFetched
                FROM albumInfo
            """)
            var albumInfoByKey = [String: AlbumInfoRecord]()
            for row in allAlbumInfos {
                let info = AlbumInfoRecord(
                    id: row["id"],
                    title: row["title"],
                    artist: row["artist"],
                    coverArtURL: row["coverArtURL"],
                    coverArtData: nil,
                    musicBrainzID: row["musicBrainzID"],
                    year: row["year"],
                    genre: row["genre"],
                    lastFetched: row["lastFetched"]
                )
                let key = "\(info.title)\0\(info.artist)"
                albumInfoByKey[key] = info
            }

            var groupKeys: [String: String] = [:]
            var order: [String] = []
            var map: [String: [LightTrackRecord]] = [:]
            for track in allTracks {
                let spelling = track.albumTitle + "\u{0}" + track.credit
                let groupKey = groupKeys[spelling] ?? Self.albumGroupingKey(albumTitle: track.albumTitle, credit: track.credit)
                groupKeys[spelling] = groupKey
                if map[groupKey] == nil { order.append(groupKey) }
                map[groupKey, default: []].append(track)
            }

            var leads: [String: String] = [:]
            func lead(_ credit: String) -> String {
                if let known = leads[credit] { return known }
                let primary = LibraryHygiene.primaryArtist(credit)
                leads[credit] = primary
                return primary
            }

            return order.compactMap { groupKey in
                guard let tracks = map[groupKey], !tracks.isEmpty else { return nil }
                let displayTitle = Self.majorityValue(tracks.map(\.albumTitle))
                let displayArtist = Self.majorityValue(tracks.map { lead($0.credit) })
                let orderedTracks = TrackOrdering.ordered(
                    tracks,
                    number: { $0.trackNumber },
                    path: { $0.fileURL },
                    title: { $0.title }
                )
                let albumInfo = Self.albumInfo(
                    title: displayTitle, credit: displayArtist, tracks: tracks, rows: albumInfoByKey
                )
                return (album: albumInfo, tracks: orderedTracks)
            }
        }
    }

    private static func majorityValue(_ values: [String]) -> String {
        var counts: [String: Int] = [:]
        for value in values {
            counts[value, default: 0] += 1
        }
        return counts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key.count > rhs.key.count
        }?.key ?? values[0]
    }

    /// Returns the larger of the enrichment cover and the embedded file artwork,
    /// since either source can be the low-resolution one for a given album.
    /// When the exact title misses (common after edition grouping folds a
    /// remaster into a deluxe card), falls back to the largest art among any
    /// album that shares the consolidation key.
    public func fetchAlbumArtwork(title: String, artist: String) throws -> Data? {
        if let playlistId = PlaylistCover.playlistId(title: title, artist: artist) {
            return try playlistCover(id: playlistId)
        }
        return try dbQueue.read { db in
            if let chosen = try Self.customCover(db: db, title: title, artist: artist) {
                return chosen
            }
            if let exact = try Self.artworkPair(db: db, title: title, artist: artist) {
                return exact
            }
            let targetKey = LibraryHygiene.consolidationKey(title: title, artist: artist)
            let titles = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT albumTitle FROM tracks WHERE artist = ?",
                arguments: [artist]
            )
            var best: Data?
            for variantTitle in titles {
                guard LibraryHygiene.consolidationKey(title: variantTitle, artist: artist) == targetKey else {
                    continue
                }
                if let chosen = try Self.customCover(db: db, title: variantTitle, artist: artist) {
                    return chosen
                }
                guard let candidate = try Self.artworkPair(db: db, title: variantTitle, artist: artist) else {
                    continue
                }
                if best.map({ candidate.count > $0.count }) ?? true {
                    best = candidate
                }
            }
            return best
        }
    }

    /// The cover the person chose themselves, which outranks every embedded
    /// and downloaded one and is never written by enrichment.
    private static func customCover(db: Database, title: String, artist: String) throws -> Data? {
        try Row.fetchOne(
            db,
            sql: "SELECT customCoverData FROM albumInfo WHERE title = ? AND artist = ? AND customCoverData IS NOT NULL",
            arguments: [title, artist]
        )?["customCoverData"]
    }

    /// Stores a person-chosen cover under every key a surface can ask for this
    /// release by: tracks look their art up by their own album title and
    /// performing artist, album cards by the grouped title and artist.
    public func saveCustomCover(_ data: Data, forKeys keys: [(title: String, artist: String)]) throws {
        try dbQueue.write { db in
            for key in keys {
                try db.execute(sql: """
                    INSERT INTO albumInfo (title, artist, customCoverData) VALUES (?, ?, ?)
                    ON CONFLICT(title, artist) DO UPDATE SET customCoverData = excluded.customCoverData
                    """, arguments: [key.title, key.artist, data])
            }
        }
    }

    public func clearCustomCover(forKeys keys: [(title: String, artist: String)]) throws {
        try dbQueue.write { db in
            for key in keys {
                try db.execute(
                    sql: "UPDATE albumInfo SET customCoverData = NULL WHERE title = ? AND artist = ?",
                    arguments: [key.title, key.artist]
                )
            }
        }
    }

    public func hasCustomCover(forKeys keys: [(title: String, artist: String)]) -> Bool {
        (try? dbQueue.read { db in
            for key in keys where try Self.customCover(db: db, title: key.title, artist: key.artist) != nil {
                return true
            }
            return false
        }) ?? false
    }

    private static func artworkPair(db: Database, title: String, artist: String) throws -> Data? {
        let cover: Data? = try Row.fetchOne(
            db,
            sql: "SELECT coverArtData FROM albumInfo WHERE title = ? AND artist = ? AND coverArtData IS NOT NULL",
            arguments: [title, artist]
        )?["coverArtData"]
        let embedded: Data? = try Row.fetchOne(
            db,
            sql: """
                SELECT artworkData FROM tracks
                WHERE albumTitle = ? AND artist = ? AND artworkData IS NOT NULL
                ORDER BY LENGTH(artworkData) DESC LIMIT 1
                """,
            arguments: [title, artist]
        )?["artworkData"]
        switch (cover, embedded) {
        case let (c?, e?): return e.count > c.count ? e : c
        case let (c?, nil): return c
        case let (nil, e?): return e
        default: return nil
        }
    }

    func fetchAlbumsWithTracks() throws -> [(album: AlbumInfoRecord?, tracks: [TrackRecord])] {
        try dbQueue.read { db in
            let allTracks = try TrackRecord
                .order(Column("albumTitle").collating(.localizedCaseInsensitiveCompare).asc,
                       Column("artist").collating(.localizedCaseInsensitiveCompare).asc,
                       Column("trackNumber").asc,
                       Column("title").collating(.localizedCaseInsensitiveCompare).asc)
                .fetchAll(db)

            let allAlbumInfos = try AlbumInfoRecord.fetchAll(db)
            var albumInfoByKey = [String: AlbumInfoRecord]()
            for info in allAlbumInfos {
                albumInfoByKey["\(info.title)\0\(info.artist)"] = info
            }

            let grouped: [(key: String, tracks: [TrackRecord])] = {
                var order: [String] = []
                var map: [String: [TrackRecord]] = [:]
                for track in allTracks {
                    let key = "\(track.albumTitle)\0\(track.artist)"
                    if map[key] == nil {
                        order.append(key)
                    }
                    map[key, default: []].append(track)
                }
                return order.map { (key: $0, tracks: map[$0]!) }
            }()

            return grouped.compactMap { group in
                guard group.tracks.first != nil else { return nil }
                return (album: albumInfoByKey[group.key], tracks: group.tracks)
            }
        }
    }
}
