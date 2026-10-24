import Foundation
import MidgarCore
import FlaccyCore
import GRDB

extension DatabaseManager {

    /// Settles `tracks.albumArtist` for every release in the library, which is
    /// the step that lets a compilation exist at all.
    ///
    /// A credit cannot be decided one file at a time — "eleven of thirty-one
    /// tracks" is only a fact about a whole release — so the scan stores the
    /// `ALBUMARTIST` tag and nothing else, and this pass fills in the rest once
    /// every track is on the table. Releases cluster by normalized album title
    /// within their containing folder, so `Album/CD1` and `Album/CD2` resolve
    /// separately and then group back together under one credit, while two
    /// unrelated "Greatest Hits" loose at the library root stay apart
    /// (`AlbumCredit.releaseScope` is nil there and the performing artist scopes
    /// the cluster instead, which is the behaviour that predates this pass).
    ///
    /// Mirrors `Db::resolve_album_credits` in the Linux client. Returns how many
    /// rows changed credit; idempotent over an unchanged library.
    @discardableResult
    public func resolveAlbumCredits() throws -> Int {
        try dbQueue.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT fileURL, albumTitle, artist, albumArtist FROM tracks")

            var stored: [String: String] = [:]
            var resolverRows: [AlbumCredit.Row<String>] = []
            resolverRows.reserveCapacity(rows.count)
            for row in rows {
                let fileURL: String = row["fileURL"]
                let albumTitle: String = row["albumTitle"]
                let artist: String = row["artist"]
                let tag: String? = row["albumArtist"]
                if let tag { stored[fileURL] = tag }
                resolverRows.append(AlbumCredit.Row(
                    id: fileURL,
                    albumTitleKey: LibraryHygiene.normalize(albumTitle),
                    relativePath: fileURL,
                    member: AlbumCredit.Member(
                        albumArtistTag: tag,
                        artistDisplay: artist,
                        artistKey: LibraryHygiene.artistKey(artist)
                    )
                ))
            }

            var changed = 0
            for (fileURL, credit) in AlbumCredit.resolve(resolverRows) where stored[fileURL] != credit {
                try db.execute(
                    sql: "UPDATE tracks SET albumArtist = ? WHERE fileURL = ?",
                    arguments: [credit, fileURL]
                )
                changed += 1
            }

            try db.execute(sql: Self.adoptCoversForCreditedReleasesSQL)
            return changed
        }
    }

    /// Gives a credited release its own `albumInfo` row, seeded with the cover a
    /// member track already hoisted.
    ///
    /// Covers are hoisted per track as the scan commits, long before anything
    /// knows the release is a compilation, so they land under the performing
    /// artist. The album surface asks by *credit*, and a soundtrack credited to
    /// Various Artists would otherwise show a blank tile above thirty-one tracks
    /// whose art is already on disk. Run unconditionally rather than only when a
    /// credit changed: a release settles its credit on the first pass, while the
    /// cover it adopts may only be fetched by enrichment several reloads later.
    ///
    /// Year and genre need no equivalent — `Library.albumMetadata` resolves
    /// those field by field across the release's rows, and enrichment
    /// deliberately keeps asking under the performing artist, which is the name
    /// a metadata provider can answer.
    private static let adoptCoversForCreditedReleasesSQL = """
        INSERT INTO albumInfo (title, artist, coverArtData)
        SELECT t.albumTitle, t.albumArtist, MIN(ai.coverArtData)
        FROM tracks t
        JOIN albumInfo ai ON ai.title = t.albumTitle AND ai.artist = t.artist
        WHERE t.albumArtist IS NOT NULL
          AND t.albumArtist <> ''
          AND t.albumArtist <> t.artist
          AND ai.coverArtData IS NOT NULL
        GROUP BY t.albumTitle, t.albumArtist
        ON CONFLICT(title, artist) DO UPDATE SET coverArtData = excluded.coverArtData
        WHERE albumInfo.coverArtData IS NULL
        """
}
