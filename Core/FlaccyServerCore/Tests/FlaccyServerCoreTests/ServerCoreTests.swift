import Foundation
import Testing

@testable import FlaccyServerCore

struct ServerCoreTests {
    private let alice = Caller(user: "alice", role: .member, device: "phone")

    @Test func versionIsReported() {
        #expect(ServerCore.version == "0.1.0")
    }

    @Test func songKeyMatchesTheReferenceDigest() throws {
        let key = try ServerCore.songKey(artistKey: "radiohead", titleKey: "karma police")
        #expect(key == "430bf734f6554175bc3bebf6e5adea05")
    }

    @Test func betweenAnswersPositionsInOrder() throws {
        #expect(try ServerCore.between(nil, nil) == "V")
        let middle = try ServerCore.between("a", "c")
        #expect("a" < middle && middle < "c")
    }

    @Test func createThenRenameThroughTheTypedApi() throws {
        let create = Mutation(id: 1, name: "playlist.create", stamp: 100, args: ["id": "p1", "name": "Mix"])
        let created = try ServerCore.applyPlaylist(doc: nil, mutation: create, caller: alice)
        #expect(created.status == .applied)
        let rename = Mutation(id: 2, name: "playlist.rename", stamp: 200, args: ["id": "p1", "name": "New"])
        let renamed = try ServerCore.applyPlaylist(doc: created.doc, mutation: rename, caller: alice)
        #expect(renamed.doc?.playlist.name == "New")
        #expect(renamed.doc?.playlist.stamps.name == 200)
    }

    @Test func invalidResultsCarryTheirCode() throws {
        let rename = Mutation(id: 1, name: "playlist.rename", stamp: 100, args: ["id": "ghost", "name": "x"])
        let result = try ServerCore.applyPlaylist(doc: nil, mutation: rename, caller: alice)
        #expect(result.status == .invalid)
        #expect(result.code == .unknownPlaylist)
    }

    @Test func rebaseSkipsFailedMutations() throws {
        let create = Mutation(id: 1, name: "playlist.create", stamp: 100, args: ["id": "p1", "name": "Mix"])
        let rename = Mutation(id: 2, name: "playlist.rename", stamp: 200, args: ["id": "p1", "name": "Refused"])
        let pending = [PendingMutation(mutation: create), PendingMutation(mutation: rename, failed: true)]
        let doc = try ServerCore.rebasePlaylist(id: "p1", base: nil, caller: alice, pending: pending)
        #expect(doc?.playlist.name == "Mix")
    }

    @Test func coreErrorsThrowTheCoreMessage() {
        let clear = Mutation(id: 1, name: "scalar.clear", stamp: 1, args: ["key": "pref/x"])
        #expect(throws: ServerCoreError.core("not a playlist mutation")) {
            try ServerCore.applyPlaylist(doc: nil, mutation: clear, caller: alice)
        }
    }

    @Test func largeStampsSurviveTheRoundTrip() throws {
        let last: Stamp = 1_788_000_000_000 << 16
        let next = try ServerCore.nextStamp(last: last, offsetMs: 0, nowMs: 1_000)
        #expect(next == last + 1)
    }

    @Test func jsonValueKeepsIntegersAndFractionsApart() throws {
        let value: JSONValue = ["whole": 7, "half": 0.5, "big": .int(Int64.max), "none": nil, "flag": true]
        let decoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
    }

    @Test func callsFromConcurrentTasksAreSafe() async throws {
        let keys = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<32 {
                group.addTask { try ServerCore.songKey(artistKey: "a\(index)", titleKey: "t") }
            }
            var all: Set<String> = []
            for try await key in group { all.insert(key) }
            return all
        }
        #expect(keys.count == 32)
    }
}
