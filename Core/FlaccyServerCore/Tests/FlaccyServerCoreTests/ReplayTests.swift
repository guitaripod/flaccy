import Foundation
import Testing

@testable import FlaccyServerCore

struct ReplayCase: Decodable, Sendable, CustomTestStringConvertible {
    let name: String
    let function: String
    let input: JSONValue
    let expected: JSONValue

    var testDescription: String { "\(function): \(name)" }

    static let all: [ReplayCase] = {
        guard
            let url = Bundle.module.url(forResource: "cases", withExtension: "json", subdirectory: "Resources"),
            let data = try? Data(contentsOf: url),
            let cases = try? JSONDecoder().decode([ReplayCase].self, from: data)
        else { return [] }
        return cases
    }()
}

struct ReplayTests {
    @Test func casesAreLoaded() {
        #expect(ReplayCase.all.count >= 25)
    }

    @Test(arguments: ReplayCase.all)
    func replayMatchesTheRustCore(_ replay: ReplayCase) throws {
        if case .object(let fields) = replay.expected, case .string(let message)? = fields["error"] {
            #expect(throws: ServerCoreError.core(message)) { try run(replay) }
        } else {
            let expected = try CanonicalJSON.string(encoding: replay.expected)
            #expect(try CanonicalJSON.string(from: run(replay)) == expected)
        }
    }

    private func run(_ replay: ReplayCase) throws -> Data {
        let input = try JSONEncoder().encode(replay.input)
        let encoder = JSONEncoder()
        switch replay.function {
        case "applyPlaylist":
            let request = try JSONDecoder().decode(ApplyPlaylistRequest.self, from: input)
            let result = try ServerCore.applyPlaylist(
                doc: request.doc, mutation: request.mutation, caller: request.caller, stamp: request.stamp)
            return try encoder.encode(result)
        case "applyScalar":
            let request = try JSONDecoder().decode(ApplyScalarRequest.self, from: input)
            let result = try ServerCore.applyScalar(
                scalar: request.scalar, mutation: request.mutation, caller: request.caller, stamp: request.stamp)
            return try encoder.encode(result)
        case "rebasePlaylist":
            let request = try JSONDecoder().decode(RebasePlaylistRequest.self, from: input)
            let doc = try ServerCore.rebasePlaylist(
                id: request.playlistId, base: request.base, caller: request.caller, pending: request.pending)
            return try encoder.encode(DocAnswer(doc: doc))
        case "rebaseLove":
            let request = try JSONDecoder().decode(RebaseLoveRequest.self, from: input)
            let love = try ServerCore.rebaseLove(
                songKey: request.songKey, base: request.base, caller: request.caller, pending: request.pending)
            return try encoder.encode(LoveAnswer(love: love))
        case "rebaseRating":
            let request = try JSONDecoder().decode(RebaseRatingRequest.self, from: input)
            let rating = try ServerCore.rebaseRating(
                songKey: request.songKey, base: request.base, caller: request.caller, pending: request.pending)
            return try encoder.encode(RatingAnswer(rating: rating))
        case "rebaseScalar":
            let request = try JSONDecoder().decode(RebaseScalarRequest.self, from: input)
            let scalar = try ServerCore.rebaseScalar(
                key: request.key, base: request.base, caller: request.caller, pending: request.pending)
            return try encoder.encode(ScalarAnswer(scalar: scalar))
        case "rebaseSession":
            let request = try JSONDecoder().decode(RebaseSessionRequest.self, from: input)
            let session = try ServerCore.rebaseSession(
                device: request.device, base: request.base, caller: request.caller, pending: request.pending)
            return try encoder.encode(SessionAnswer(session: session))
        case "between":
            let request = try JSONDecoder().decode(BetweenRequest.self, from: input)
            return try encoder.encode(PositionAnswer(pos: ServerCore.between(request.a, request.b)))
        case "songKey":
            let request = try JSONDecoder().decode(SongKeyRequest.self, from: input)
            let key = try ServerCore.songKey(artistKey: request.artistKey, titleKey: request.titleKey)
            return try encoder.encode(SongKeyAnswer(songKey: key))
        case "songKeys":
            let request = try JSONDecoder().decode(SongKeysRequest.self, from: input)
            let keys = try ServerCore.songKeys(request.pairs.map { ($0.artistKey, $0.titleKey) })
            return try encoder.encode(SongKeysAnswer(songKeys: keys))
        case "normalizePlaylistName":
            let request = try JSONDecoder().decode(NormalizePlaylistNameRequest.self, from: input)
            return try encoder.encode(NameAnswer(name: ServerCore.normalizePlaylistName(request.name)))
        case "playlistId":
            let request = try JSONDecoder().decode(PlaylistIdRequest.self, from: input)
            let id = try ServerCore.playlistId(name: request.name, occurrence: request.occurrence)
            return try encoder.encode(PlaylistIdAnswer(playlistId: id))
        case "entryId":
            let request = try JSONDecoder().decode(EntryIdRequest.self, from: input)
            let id = try ServerCore.entryId(
                playlistId: request.playlistId, songKey: request.songKey, occurrence: request.occurrence)
            return try encoder.encode(EntryIdAnswer(entryId: id))
        case "eventIdRec":
            let request = try JSONDecoder().decode(EventIdRecRequest.self, from: input)
            let id = try ServerCore.eventIdRec(
                deviceId: request.deviceId, instance: request.instance, counter: request.counter)
            return try encoder.encode(EventIdAnswer(eventId: id))
        case "eventIdsMig":
            let request = try JSONDecoder().decode(EventIdsMigRequest.self, from: input)
            let ids = try ServerCore.eventIdsMig(request.plays.map { ($0.ts, $0.titleKey, $0.artistKey) })
            return try encoder.encode(EventIdsAnswer(eventIds: ids))
        case "chunkReseed":
            let request = try JSONDecoder().decode(ChunkReseedRequest.self, from: input)
            return try encoder.encode(ChunkReseedAnswer(chunks: ServerCore.chunkReseed(request.entities)))
        case "suppressedFlags":
            let request = try JSONDecoder().decode(SuppressedFlagsRequest.self, from: input)
            return try encoder.encode(FlagsAnswer(flags: ServerCore.suppressedFlags(request.events)))
        case "nextStamp":
            let request = try JSONDecoder().decode(NextStampRequest.self, from: input)
            let stamp = try ServerCore.nextStamp(last: request.last, offsetMs: request.offsetMs, nowMs: request.nowMs)
            return try encoder.encode(StampAnswer(stamp: stamp))
        default:
            throw ReplayError.unknownFunction(replay.function)
        }
    }
}

enum ReplayError: Error {
    case unknownFunction(String)
}
