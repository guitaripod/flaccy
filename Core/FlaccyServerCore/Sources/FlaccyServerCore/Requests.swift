struct ApplyPlaylistRequest: Codable {
    var doc: PlaylistDoc?
    var mutation: Mutation
    var caller: Caller
    var stamp: Stamp?
}

struct ApplyScalarRequest: Codable {
    var scalar: Scalar?
    var mutation: Mutation
    var caller: Caller
    var stamp: Stamp?
}

struct RebasePlaylistRequest: Codable {
    var playlistId: String
    var base: PlaylistDoc?
    var caller: Caller
    var pending: [PendingMutation]
}

struct RebaseLoveRequest: Codable {
    var songKey: String
    var base: Love?
    var caller: Caller
    var pending: [PendingMutation]
}

struct RebaseRatingRequest: Codable {
    var songKey: String
    var base: Rating?
    var caller: Caller
    var pending: [PendingMutation]
}

struct RebaseScalarRequest: Codable {
    var key: String
    var base: Scalar?
    var caller: Caller
    var pending: [PendingMutation]
}

struct RebaseSessionRequest: Codable {
    var device: String
    var base: SessionDoc?
    var caller: Caller
    var pending: [PendingMutation]
}

struct BetweenRequest: Codable {
    var a: String?
    var b: String?
}

struct SongKeyRequest: Codable {
    var artistKey: String
    var titleKey: String
}

struct SongKeysRequest: Codable {
    var pairs: [SongKeyRequest]
}

struct NormalizePlaylistNameRequest: Codable {
    var name: String
}

struct PlaylistIdRequest: Codable {
    var name: String
    var occurrence: UInt32
}

struct EntryIdRequest: Codable {
    var playlistId: String
    var songKey: String
    var occurrence: UInt32
}

struct EventIdRecRequest: Codable {
    var deviceId: String
    var instance: String
    var counter: UInt64
}

struct MigratedPlayRequest: Codable {
    var ts: Int64
    var titleKey: String
    var artistKey: String
}

struct EventIdsMigRequest: Codable {
    var plays: [MigratedPlayRequest]
}

struct ChunkReseedRequest: Codable {
    var entities: [Entity]
}

struct ChunkReseedAnswer: Codable {
    var chunks: [[Entity]]
}

struct SuppressedFlagsRequest: Codable {
    var events: [SecondEvent]
}

struct NextStampRequest: Codable {
    var last: Stamp
    var offsetMs: Int64
    var nowMs: Int64
}

struct DocAnswer: Codable {
    var doc: PlaylistDoc?
}

struct LoveAnswer: Codable {
    var love: Love?
}

struct RatingAnswer: Codable {
    var rating: Rating?
}

struct ScalarAnswer: Codable {
    var scalar: Scalar?
}

struct SessionAnswer: Codable {
    var session: SessionDoc?
}

struct PositionAnswer: Codable {
    var pos: String
}

struct SongKeyAnswer: Codable {
    var songKey: String
}

struct SongKeysAnswer: Codable {
    var songKeys: [String]
}

struct NameAnswer: Codable {
    var name: String
}

struct PlaylistIdAnswer: Codable {
    var playlistId: String
}

struct EntryIdAnswer: Codable {
    var entryId: String
}

struct EventIdAnswer: Codable {
    var eventId: String
}

struct EventIdsAnswer: Codable {
    var eventIds: [String]
}

struct FlagsAnswer: Codable {
    var flags: [Bool]
}

struct StampAnswer: Codable {
    var stamp: Stamp
}
