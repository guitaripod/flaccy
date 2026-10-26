import Foundation
import Testing

@testable import FlaccyServerCore

struct ServerCoreTests {
    @Test func versionIsReported() {
        #expect(ServerCore.version == "0.1.0")
    }

    @Test func songKeyMatchesReferenceDigest() {
        #expect(ServerCore.songKey(artistKey: "radiohead", titleKey: "karma police") == "430bf734f6554175bc3bebf6e5adea05")
    }

    @Test func betweenReturnsKeyInsideTheRange() throws {
        let key = try ServerCore.between("a", "c")
        #expect("a" < key && key < "c")
        let open = try ServerCore.between("", "")
        #expect(!open.isEmpty)
    }

    @Test func betweenRejectsReversedRange() {
        #expect(throws: ServerCoreError.core("a must sort before b")) {
            try ServerCore.between("c", "a")
        }
    }

    @Test func applyJsonAppendsAndBumpsRevision() throws {
        let first = try ServerCore.apply(state: "{}", mutation: #"{"op":"append","value":"x"}"#)
        let second = try ServerCore.apply(state: first, mutation: #"{"op":"append","value":2}"#)
        let object = try #require(JSONSerialization.jsonObject(with: Data(second.utf8)) as? [String: Any])
        #expect(object["rev"] as? Int == 2)
        #expect((object["items"] as? [Any])?.count == 2)
    }

    @Test func applyJsonReportsBadInput() {
        #expect(throws: ServerCoreError.self) {
            try ServerCore.apply(state: "nope", mutation: "{}")
        }
    }

    @Test func callsFromConcurrentTasksAreSafe() async {
        let keys = await withTaskGroup(of: String.self) { group in
            for index in 0..<32 { group.addTask { ServerCore.songKey(artistKey: "a\(index)", titleKey: "t") } }
            var all: [String] = []
            for await key in group { all.append(key) }
            return all
        }
        #expect(Set(keys).count == 32)
    }
}
