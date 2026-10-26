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

struct FlagsAnswer: Codable {
    var flags: [Bool]
}

struct StampAnswer: Codable {
    var stamp: Stamp
}
