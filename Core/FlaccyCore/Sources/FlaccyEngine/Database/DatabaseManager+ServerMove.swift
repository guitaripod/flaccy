import FlaccyCore
import Foundation
import GRDB

/// What the library knows about one song on this device that a server may also hold.
public struct ServerMoveLocalSong: Sendable, Equatable {
    public let path: String
    /// The size the scan recorded, nil for a row scanned before sizes were kept.
    public let bytes: Int64?
    public let loved: Bool
    public let playCount: Int
}

/// The songs on this device and on one server, keyed for `ServerMovePlan`.
public struct ServerMoveInventory: Sendable {
    public let local: [ServerMovePlan.Song]
    public let server: [ServerMovePlan.Song]
    public let localSongs: [String: ServerMoveLocalSong]
    /// Songs on this device kept out of the move because an earlier mix is kept beside them.
    public let heldBack: Int
}

/// One change `applyServerMove` makes: a song on this device becomes the server's song, or a
/// further copy of it folds into the song that already did.
public enum ServerMoveStep: Sendable, Equatable {
    case pair(local: String, server: String, keepOnDevice: Bool)
    case duplicate(local: String, server: String)
}

/// A song whose row now plays from a server while its file still has to leave the library folder:
/// kept as the server song's download, or deleted.
public struct ServerMoveRecord: Sendable, Equatable {
    public let localPath: String
    public let remotePath: String
    public let keepOnDevice: Bool
    /// The size of the file when it moved, so a different file put at the same path later is never taken for it.
    public let fileSize: Int64?
    /// Whether the person loves the song while the server does not know it yet.
    public let starOnServer: Bool

    public init(localPath: String, remotePath: String, keepOnDevice: Bool, fileSize: Int64? = nil, starOnServer: Bool = false) {
        self.localPath = localPath
        self.remotePath = remotePath
        self.keepOnDevice = keepOnDevice
        self.fileSize = fileSize
        self.starOnServer = starOnServer
    }
}

extension DatabaseManager {

    /// Every song in the library folder except `excluded` ones and those with an earlier mix kept, and every song of
    /// the server, with the keys the plan pairs them by. `rank` says how much the person uses a song on this device.
    public func serverMoveInventory(
        serverID: String,
        excluded: (String) -> Bool = { _ in false },
        rank: (ServerMoveLocalSong) -> Int
    ) throws -> ServerMoveInventory {
        let (localRows, serverRows, versioned) = try dbQueue.read { db in
            (
                try Row.fetchAll(db, sql: """
                    SELECT fileURL, title, artist, albumTitle, trackNumber, duration, audioFingerprint, fileSize, loved, playCount
                    FROM tracks WHERE remoteServer IS NULL
                    """),
                try Row.fetchAll(db, sql: """
                    SELECT fileURL, title, artist, albumTitle, trackNumber, duration, audioFingerprint
                    FROM tracks WHERE remoteServer = ?
                    """, arguments: [serverID]),
                Set(try String.fetchAll(db, sql: "SELECT trackFileURL FROM previousVersions"))
            )
        }
        var memo = ListenKeyMemo()
        let considered = localRows.filter { !excluded($0["fileURL"]) }
        let eligible = considered.filter { !versioned.contains($0["fileURL"]) }
        let heldBack = considered.count - eligible.count
        var localSongs: [String: ServerMoveLocalSong] = [:]
        for row in eligible {
            let path: String = row["fileURL"]
            localSongs[path] = ServerMoveLocalSong(path: path, bytes: row["fileSize"], loved: row["loved"], playCount: row["playCount"])
        }
        let local = try Self.planSongs(eligible, memo: &memo) { path in localSongs[path].map(rank) ?? 0 }
        let server = try Self.planSongs(serverRows, memo: &memo) { _ in 0 }
        return ServerMoveInventory(local: local, server: server, localSongs: localSongs, heldBack: heldBack)
    }

    /// Makes each song on this device the server's song in one transaction: the row keeps its id, plays, love and
    /// playlist places and takes the server's path and tags, the server's own row folds into it, and a further copy
    /// folds in the same way. Steps whose rows changed since the plan are skipped. Returns the files that must leave
    /// the library folder, also written to the journal that `pendingServerMoves` reads after a crash.
    public func applyServerMove(_ steps: [ServerMoveStep], now: Date) throws -> [ServerMoveRecord] {
        try dbQueue.write { db in
            var records: [ServerMoveRecord] = []
            for step in steps {
                switch step {
                case .pair(let local, let server, let keep):
                    if let record = try Self.movePair(local: local, server: server, keepOnDevice: keep, now: now, in: db) {
                        records.append(record)
                    }
                case .duplicate(let local, let server):
                    if let record = try Self.foldDuplicate(local: local, server: server, now: now, in: db) {
                        records.append(record)
                    }
                }
            }
            return records
        }
    }

    /// The files of moved songs that have not left the library folder yet.
    public func pendingServerMoves() throws -> [ServerMoveRecord] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db, sql: "SELECT localPath, remotePath, keepOnDevice, fileSize FROM serverMoves WHERE done = 0 ORDER BY localPath"
            ).map {
                ServerMoveRecord(
                    localPath: $0["localPath"], remotePath: $0["remotePath"], keepOnDevice: $0["keepOnDevice"], fileSize: $0["fileSize"]
                )
            }
        }
    }

    /// The paths in the library folder whose song already plays from a server, which a scan must not add again.
    public func pendingServerMoveLocalPaths() throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT localPath FROM serverMoves WHERE done = 0"))
        }
    }

    /// Records that these files left the library folder.
    public func finishServerMoves(localPaths: [String]) throws {
        guard !localPaths.isEmpty else { return }
        try dbQueue.write { db in
            for path in localPaths {
                try db.execute(sql: "UPDATE serverMoves SET done = 1 WHERE localPath = ?", arguments: [path])
            }
        }
    }

    /// Forgets a move whose server song left the library before its file was handled, so the file stays and the
    /// next scan lists it again as a song on this device.
    public func abandonServerMove(localPath: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM serverMoves WHERE localPath = ?", arguments: [localPath])
        }
    }

    /// Whether a moved song's server row is still in the library.
    public func hasRemoteRow(path: String) throws -> Bool {
        try dbQueue.read { db in
            try Bool.fetchOne(db, sql: "SELECT 1 FROM tracks WHERE fileURL = ? AND remoteServer IS NOT NULL", arguments: [path]) ?? false
        }
    }

    /// The path each moved song had in the library folder, by its server path, for the ones still in the library.
    public func serverMoveFormerPaths() throws -> [String: String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.remotePath, m.localPath FROM serverMoves m
                JOIN tracks t ON t.fileURL = m.remotePath
                WHERE m.isPair = 1
                """)
            return Dictionary(rows.map { ($0["remotePath"], $0["localPath"]) }, uniquingKeysWith: { first, _ in first })
        }
    }

    private static func planSongs(
        _ rows: [Row], memo: inout ListenKeyMemo, rank: (String) -> Int
    ) throws -> [ServerMovePlan.Song] {
        let keyed = rows.map { row -> (row: Row, keys: (title: String, artist: String, album: String)) in
            (row, memo.keys(title: row["title"], artist: row["artist"], album: row["albumTitle"]))
        }
        let songKeys = try ServerCoreBridge.songKeys(keyed.map { (artistKey: $0.keys.artist, titleKey: $0.keys.title) })
        return zip(keyed, songKeys).map { item, songKey in
            let path: String = item.row["fileURL"]
            let duration: Double = item.row["duration"]
            let artistless = item.keys.artist.isEmpty || item.keys.title.isEmpty
            return ServerMovePlan.Song(
                path: path,
                songKey: artistless ? "" : songKey,
                albumKey: item.keys.album,
                track: item.row["trackNumber"],
                durationMs: Int64((duration * 1000).rounded()),
                fingerprint: item.row["audioFingerprint"],
                rank: rank(path)
            )
        }
    }

    private static func movePair(
        local: String, server: String, keepOnDevice: Bool, now: Date, in db: Database
    ) throws -> ServerMoveRecord? {
        guard var song = try TrackRecord.filter(Column("fileURL") == local && Column("remoteServer") == nil).fetchOne(db),
              let remote = try TrackRecord.filter(Column("fileURL") == server && Column("remoteServer") != nil).fetchOne(db),
              try !hasPreviousVersion(local, in: db)
        else { return nil }
        let former = song
        song.fileURL = remote.fileURL
        song.title = remote.title
        song.artist = remote.artist
        song.albumTitle = remote.albumTitle
        song.albumArtist = remote.albumArtist
        song.trackNumber = remote.trackNumber
        song.duration = remote.duration
        song.codec = remote.codec
        song.bitDepth = remote.bitDepth
        song.sampleRate = remote.sampleRate
        song.channels = remote.channels
        song.fileSize = remote.fileSize
        song.fileModifiedMs = nil
        song.audioFingerprint = remote.audioFingerprint
        song.revision = remote.revision
        song.revisedAt = remote.revisedAt
        song.remoteServer = remote.remoteServer
        song.remoteSuffix = remote.remoteSuffix
        song.remoteSize = remote.remoteSize
        song.remoteCoverArt = remote.remoteCoverArt
        song.remoteAlbumId = remote.remoteAlbumId
        song.pinned = keepOnDevice || remote.pinned
        song.loved = former.loved || remote.loved
        song.lovedPendingOp = former.lovedPendingOp ?? remote.lovedPendingOp
        song.playCount = max(former.playCount, remote.playCount)
        song.lastPlayed = later(former.lastPlayed, remote.lastPlayed)
        song.dateAdded = min(former.dateAdded, remote.dateAdded)
        song.aiAnalyzed = true
        song.musicBrainzID = former.musicBrainzID ?? remote.musicBrainzID
        song.albumMusicBrainzID = former.albumMusicBrainzID ?? remote.albumMusicBrainzID
        if let remoteID = remote.id {
            try db.execute(sql: "DELETE FROM sync_song_keys WHERE trackId = ?", arguments: [remoteID])
        }
        _ = try remote.delete(db)
        try db.execute(sql: "UPDATE playlistTracks SET trackFileURL = ? WHERE trackFileURL = ?", arguments: [server, local])
        try song.update(db)
        try carryLyrics(from: former, to: song, in: db)
        try carryCustomCover(from: former, to: song, in: db)
        try journal(local: local, remote: server, keepOnDevice: keepOnDevice, isPair: true, fileSize: former.fileSize, now: now, in: db)
        return ServerMoveRecord(
            localPath: local, remotePath: server, keepOnDevice: keepOnDevice, fileSize: former.fileSize,
            starOnServer: song.loved && !remote.loved
        )
    }

    private static func foldDuplicate(local: String, server: String, now: Date, in db: Database) throws -> ServerMoveRecord? {
        guard let copy = try TrackRecord.filter(Column("fileURL") == local && Column("remoteServer") == nil).fetchOne(db),
              var keeper = try TrackRecord.filter(Column("fileURL") == server && Column("remoteServer") != nil).fetchOne(db),
              try !hasPreviousVersion(local, in: db)
        else { return nil }
        let wasLoved = keeper.loved
        keeper.loved = keeper.loved || copy.loved
        keeper.lovedPendingOp = keeper.lovedPendingOp ?? copy.lovedPendingOp
        keeper.playCount += copy.playCount
        keeper.lastPlayed = later(keeper.lastPlayed, copy.lastPlayed)
        keeper.dateAdded = min(keeper.dateAdded, copy.dateAdded)
        if let copyID = copy.id {
            try db.execute(sql: "DELETE FROM sync_song_keys WHERE trackId = ?", arguments: [copyID])
        }
        _ = try copy.delete(db)
        try db.execute(sql: "UPDATE playlistTracks SET trackFileURL = ? WHERE trackFileURL = ?", arguments: [server, local])
        try keeper.update(db)
        try carryLyrics(from: copy, to: keeper, in: db)
        try carryCustomCover(from: copy, to: keeper, in: db)
        try journal(local: local, remote: server, keepOnDevice: false, isPair: false, fileSize: copy.fileSize, now: now, in: db)
        return ServerMoveRecord(
            localPath: local, remotePath: server, keepOnDevice: false, fileSize: copy.fileSize, starOnServer: keeper.loved && !wasLoved
        )
    }

    private static func hasPreviousVersion(_ path: String, in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT 1 FROM previousVersions WHERE trackFileURL = ?", arguments: [path]) ?? false
    }

    private static func later(_ a: Date?, _ b: Date?) -> Date? {
        guard let a else { return b }
        guard let b else { return a }
        return max(a, b)
    }

    /// Keeps the lyrics and their timing offset of a song whose title or artist is spelled differently on the server. Lyrics
    /// already stored under the server's spelling stay, except that an offset the person set wins over none.
    private static func carryLyrics(from former: TrackRecord, to song: TrackRecord, in db: Database) throws {
        guard former.title != song.title || former.artist != song.artist else { return }
        let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(lyrics)")
            .map { $0["name"] as String }
            .filter { !["id", "trackTitle", "artist"].contains($0) }
        let list = columns.map { "\"\($0)\"" }.joined(separator: ", ")
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO lyrics (trackTitle, artist, \(list))
                SELECT ?, ?, \(list) FROM lyrics WHERE trackTitle = ? AND artist = ?
                """,
            arguments: [song.title, song.artist, former.title, former.artist]
        )
        try db.execute(
            sql: """
                UPDATE lyrics SET offsetMs = (SELECT offsetMs FROM lyrics WHERE trackTitle = ? AND artist = ?)
                WHERE trackTitle = ? AND artist = ? AND offsetMs = 0
                  AND COALESCE((SELECT offsetMs FROM lyrics WHERE trackTitle = ? AND artist = ?), 0) <> 0
                """,
            arguments: [former.title, former.artist, song.title, song.artist, former.title, former.artist]
        )
    }

    /// Keeps a cover the person chose for the album when the server spells the album or its artist differently.
    private static func carryCustomCover(from former: TrackRecord, to song: TrackRecord, in db: Database) throws {
        let pairs = [
            ((former.albumTitle, former.albumArtist ?? former.artist), (song.albumTitle, song.albumArtist ?? song.artist)),
            ((former.albumTitle, former.artist), (song.albumTitle, song.artist)),
        ]
        for (old, new) in pairs where old != new {
            guard let cover = try Data.fetchOne(
                db,
                sql: "SELECT customCoverData FROM albumInfo WHERE title = ? AND artist = ? AND customCoverData IS NOT NULL",
                arguments: [old.0, old.1]
            ) else { continue }
            try db.execute(sql: "INSERT OR IGNORE INTO albumInfo (title, artist) VALUES (?, ?)", arguments: [new.0, new.1])
            try db.execute(
                sql: "UPDATE albumInfo SET customCoverData = COALESCE(customCoverData, ?) WHERE title = ? AND artist = ?",
                arguments: [cover, new.0, new.1]
            )
        }
    }

    private static func journal(
        local: String, remote: String, keepOnDevice: Bool, isPair: Bool, fileSize: Int64?, now: Date, in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT OR REPLACE INTO serverMoves (localPath, remotePath, keepOnDevice, isPair, done, fileSize, movedAt)
                VALUES (?, ?, ?, ?, 0, ?, ?)
                """,
            arguments: [local, remote, keepOnDevice, isPair, fileSize, now]
        )
    }
}
