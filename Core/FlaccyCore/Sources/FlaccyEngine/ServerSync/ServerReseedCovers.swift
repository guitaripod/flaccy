import FlaccyCore
import Foundation
import GRDB

/// The cover images a `state.reseed` names. The server accepts a reseeded cover only when this device uploaded the image, so
/// the engine uploads before it pushes, and sends no cover it could not upload.
enum ReseedCovers {

    static func hashes(in mutation: ServerMutation) -> [String] {
        guard mutation.name == SyncPending.reseed else { return [] }
        return (mutation.args["entities"]?.array ?? []).compactMap(coverHash(of:))
    }

    static func coverHash(of entity: ServerJSON) -> String? {
        guard entity["kind"]?.string == SyncBase.playlist else { return nil }
        return entity["value"]?["coverBlob"]?.string
    }

    /// The mutation with the covers named in `hashes` (all of them when nil) taken out of its playlists.
    static func removing(_ hashes: Set<String>?, from mutation: ServerMutation) -> ServerMutation {
        guard mutation.name == SyncPending.reseed, let entities = mutation.args["entities"]?.array else { return mutation }
        var changed = mutation
        changed.args = ["entities": .array(entities.map { removing(hashes, fromEntity: $0) })]
        return changed
    }

    static func removing(_ hashes: Set<String>?, fromEntity entity: ServerJSON) -> ServerJSON {
        guard let hash = coverHash(of: entity), hashes?.contains(hash) ?? true,
              case .object(var fields) = entity, case .object(var value)? = fields["value"]
        else { return entity }
        value["coverBlob"] = .null
        fields["value"] = .object(value)
        return .object(fields)
    }

    /// Keeps a reseeded cover only when its image is on this device, putting it in `sync_blobs` so it can be uploaded again.
    static func prepared(_ db: Database, _ entities: [ServerJSON]) throws -> [ServerJSON] {
        try entities.map { entity in
            guard let hash = coverHash(of: entity), let playlist = entity["id"]?.string else { return entity }
            let stored = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM sync_blobs WHERE hash = ?)", arguments: [hash]) ?? false
            if stored { return entity }
            let local = try Data.fetchOne(
                db, sql: "SELECT customCoverData FROM playlists WHERE syncId = ? AND customCoverData IS NOT NULL", arguments: [playlist]
            )
            guard let local, SyncMaterializer.hexDigest(local) == hash else { return removing([hash], fromEntity: entity) }
            try db.execute(sql: "INSERT OR IGNORE INTO sync_blobs (hash, data) VALUES (?, ?)", arguments: [hash, local])
            return entity
        }
    }
}
