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
