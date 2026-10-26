import FlaccyServerCoreBindings
import Foundation

public enum ServerCore {
    public static var version: String {
        FlaccyServerCoreBindings.version()
    }

    public static func applyPlaylist(
        doc: PlaylistDoc?,
        mutation: Mutation,
        caller: Caller,
        stamp: Stamp? = nil
    ) throws -> ApplyPlaylistResult {
        let request = ApplyPlaylistRequest(doc: doc, mutation: mutation, caller: caller, stamp: stamp)
        return try call(FlaccyServerCoreBindings.applyPlaylist, request)
    }

    public static func applyScalar(
        scalar: Scalar?,
        mutation: Mutation,
        caller: Caller,
        stamp: Stamp? = nil
    ) throws -> ApplyScalarResult {
        let request = ApplyScalarRequest(scalar: scalar, mutation: mutation, caller: caller, stamp: stamp)
        return try call(FlaccyServerCoreBindings.applyScalar, request)
    }

    public static func rebasePlaylist(
        id: String,
        base: PlaylistDoc?,
        caller: Caller,
        pending: [PendingMutation]
    ) throws -> PlaylistDoc? {
        let request = RebasePlaylistRequest(playlistId: id, base: base, caller: caller, pending: pending)
        return try call(FlaccyServerCoreBindings.rebasePlaylist, request, as: DocAnswer.self).doc
    }

    public static func rebaseLove(
        songKey: String,
        base: Love?,
        caller: Caller,
        pending: [PendingMutation]
    ) throws -> Love? {
        let request = RebaseLoveRequest(songKey: songKey, base: base, caller: caller, pending: pending)
        return try call(FlaccyServerCoreBindings.rebaseLove, request, as: LoveAnswer.self).love
    }

    public static func rebaseRating(
        songKey: String,
        base: Rating?,
        caller: Caller,
        pending: [PendingMutation]
    ) throws -> Rating? {
        let request = RebaseRatingRequest(songKey: songKey, base: base, caller: caller, pending: pending)
        return try call(FlaccyServerCoreBindings.rebaseRating, request, as: RatingAnswer.self).rating
    }

    public static func rebaseScalar(
        key: String,
        base: Scalar?,
        caller: Caller,
        pending: [PendingMutation]
    ) throws -> Scalar? {
        let request = RebaseScalarRequest(key: key, base: base, caller: caller, pending: pending)
        return try call(FlaccyServerCoreBindings.rebaseScalar, request, as: ScalarAnswer.self).scalar
    }

    public static func rebaseSession(
        device: String,
        base: SessionDoc?,
        caller: Caller,
        pending: [PendingMutation]
    ) throws -> SessionDoc? {
        let request = RebaseSessionRequest(device: device, base: base, caller: caller, pending: pending)
        return try call(FlaccyServerCoreBindings.rebaseSession, request, as: SessionAnswer.self).session
    }

    public static func between(_ lower: String?, _ upper: String?) throws -> String {
        let request = BetweenRequest(a: lower, b: upper)
        return try call(FlaccyServerCoreBindings.between, request, as: PositionAnswer.self).pos
    }

    public static func songKey(artistKey: String, titleKey: String) throws -> String {
        let request = SongKeyRequest(artistKey: artistKey, titleKey: titleKey)
        return try call(FlaccyServerCoreBindings.songKey, request, as: SongKeyAnswer.self).songKey
    }

    public static func suppressedFlags(_ events: [SecondEvent]) throws -> [Bool] {
        let request = SuppressedFlagsRequest(events: events)
        return try call(FlaccyServerCoreBindings.suppressedFlags, request, as: FlagsAnswer.self).flags
    }

    public static func nextStamp(last: Stamp, offsetMs: Int64, nowMs: Int64) throws -> Stamp {
        let request = NextStampRequest(last: last, offsetMs: offsetMs, nowMs: nowMs)
        return try call(FlaccyServerCoreBindings.nextStamp, request, as: StampAnswer.self).stamp
    }

    private static func call<Request: Encodable, Response: Decodable>(
        _ function: (String) throws -> String,
        _ request: Request,
        as type: Response.Type = Response.self
    ) throws -> Response {
        let output = try invoke(function, input: try encode(request))
        return try decode(type, from: output)
    }

    private static func encode<Request: Encodable>(_ request: Request) throws -> String {
        do {
            return String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        } catch {
            throw ServerCoreError.internalFailure("encoding the request failed: \(error)")
        }
    }

    private static func invoke(_ function: (String) throws -> String, input: String) throws -> String {
        do {
            return try function(input)
        } catch let FlaccyServerCoreBindings.ServerCoreFfiError.Message(message) {
            throw ServerCoreError.core(message)
        } catch {
            throw ServerCoreError.internalFailure(String(describing: error))
        }
    }

    private static func decode<Response: Decodable>(_ type: Response.Type, from output: String) throws -> Response {
        do {
            return try JSONDecoder().decode(type, from: Data(output.utf8))
        } catch {
            throw ServerCoreError.malformedResponse(String(describing: error))
        }
    }
}
