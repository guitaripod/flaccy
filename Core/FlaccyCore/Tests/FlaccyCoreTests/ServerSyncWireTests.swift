import XCTest
@testable import FlaccyCore

final class ServerSyncWireTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testHelloReadsTheProtocolListUnderItsReservedWord() throws {
        let hello = try decode(ServerHello.self, """
            {"protocol":[1],"server":{"name":"arch","version":"1.0.0","schema":1},"features":["sync","live"],
             "mode":"easy","serverTimeMs":1790000000000,"incarnation":"abc","caller":{"user":"u","role":"member","device":null},"extra":1}
            """)
        XCTAssertEqual(hello.protocols, [1])
        XCTAssertEqual(hello.server.name, "arch")
        XCTAssertEqual(hello.caller?.role, .member)
        XCTAssertNil(hello.caller?.device)
        let again = try JSONDecoder().decode(ServerHello.self, from: JSONEncoder().encode(hello))
        XCTAssertEqual(again, hello)
    }

    func testAPullResponseKeepsEveryChangeAndSkipsKindsItDoesNotKnow() throws {
        let pull = try decode(ServerPullResponse.self, """
            {"head":9,"incarnation":"i","lastMutationId":3,"more":true,"serverTimeMs":5,"changes":[
              {"seq":1,"kind":"love","id":"k","deleted":false,"value":{"songKey":"00000000000000000000000000000000","ref":{"songKey":"00000000000000000000000000000000","title":"T","artist":"A"},"loved":true,"stamp":7}},
              {"seq":2,"kind":"hologram","id":"x","deleted":true,"value":{}}]}
            """)
        XCTAssertEqual(pull.changes.count, 2)
        XCTAssertTrue(pull.more)
        XCTAssertEqual(pull.lastMutationId, 3)
        XCTAssertEqual(pull.changes[1].kind, .unknown("hologram"))
        XCTAssertNil(ServerEntityValue(kind: pull.changes[1].kind, value: pull.changes[1].value))
        guard case .love(let love)? = ServerEntityValue(kind: pull.changes[0].kind, value: pull.changes[0].value) else {
            return XCTFail("not a love")
        }
        XCTAssertTrue(love.loved)
        XCTAssertEqual(love.ref.album, "")
        XCTAssertEqual(love.ref.durationMs, 0)
    }

    func testEveryEntityKindDecodesFromItsProtocolShape() throws {
        let ref = #"{"songKey":"00000000000000000000000000000000","title":"T","artist":"A","album":"B","durationMs":1000,"fp":null,"mbid":null,"albumKey":"b","relPath":"a/b.flac"}"#
        let cases: [(String, String)] = [
            ("playlist", #"{"id":"p","owner":"u","name":"Mix","coverBlob":null,"visibility":"private","alive":true,"createdAt":5,"stamps":{"name":1,"cover":1,"visibility":1,"alive":1}}"#),
            ("playlist_entry", #"{"id":"e","playlist":"p","ref":\#(ref),"pos":"V","alive":true,"stamps":{"ref":1,"pos":1,"alive":1}}"#),
            ("scalar", #"{"key":"pref/x","value":{"a":[1,2.5,"s",null,true]},"deleted":false,"stamp":4}"#),
            ("session", #"{"device":"d","session":{"queue":[]},"stamp":4}"#),
            ("listen", #"{"eventId":"000000000000000000000001","ts":9,"ref":\#(ref),"playedS":30,"source":"lastfm","recorded":false,"device":null,"suppressed":true}"#),
        ]
        for (kind, json) in cases {
            let value = try decode(ServerJSON.self, json)
            XCTAssertNotNil(ServerEntityValue(kind: try decode(ServerEntityKind.self, "\"\(kind)\""), value: value), kind)
        }
        guard case .listen(let listen)? = ServerEntityValue(kind: .listen, value: try decode(ServerJSON.self, cases[4].1)) else {
            return XCTFail("not a listen")
        }
        XCTAssertEqual(listen.source, .lastfm)
        XCTAssertTrue(listen.suppressed)
        XCTAssertNil(listen.device)
    }

    func testAListensPageReadsItsItemsWithTheirSequenceNumbers() throws {
        let page = try decode(ServerListensPage.self, """
            {"listens":[{"seq":4,"eventId":"000000000000000000000001","ts":9,"ref":{"songKey":"00000000000000000000000000000000","title":"T","artist":"A"},"playedS":30,"source":"flaccy","recorded":true,"device":"d","suppressed":false}],
             "more":false,"head":4}
            """)
        XCTAssertEqual(page.listens.first?.seq, 4)
        XCTAssertEqual(page.head, 4)
        XCTAssertFalse(page.more)
    }

    func testAMutationRoundTripsWithItsNestedArguments() throws {
        let mutation = ServerMutation(
            id: 7, name: "entry.insert", stamp: Int64.max / 2,
            args: ["id": "e", "place": ["kind": "after", "id": "x"], "count": 3, "ratio": 0.25, "nothing": .null]
        )
        let data = try JSONEncoder().encode(ServerPushRequest(device: "d", instance: "i", mutations: [mutation]))
        let back = try JSONDecoder().decode(ServerPushRequest.self, from: data)
        XCTAssertEqual(back.mutations, [mutation])
        XCTAssertEqual(back.mutations.first?.args["count"]?.int, 3)
    }

    func testPushResultsKeepTheirCodeAndUnknownStatusesCountAsUnsupported() throws {
        let response = try decode(ServerPushResponse.self, """
            {"results":[{"id":1,"status":"applied"},{"id":2,"status":"invalid","code":"unknown_anchor"},{"id":3,"status":"mystery"}],"serverTimeMs":1}
            """)
        XCTAssertEqual(response.results.map(\.status), [.applied, .invalid, .unsupported])
        XCTAssertEqual(response.results[1].code, "unknown_anchor")
        XCTAssertTrue(response.results[2].status.isRefusal)
        XCTAssertFalse(response.results[0].status.isRefusal)
    }

    func testDevicesTolerateMissingOptionalFields() throws {
        let reply = try decode(ServerDevicesReply.self, #"{"devices":[{"id":"d","userId":"u","name":"Phone","platform":"ios","createdAt":1,"lastSeenAt":null,"revokedAt":null,"current":true},{"id":"e","name":"Mac"}]}"#)
        XCTAssertEqual(reply.devices.count, 2)
        XCTAssertTrue(reply.devices[0].current)
        XCTAssertFalse(reply.devices[1].current)
    }

    func testTheEnrollReplyNeverPrintsTheToken() {
        let reply = ServerEnrollReply(
            device: "d", token: "SECRET-TOKEN", user: ServerUser(id: "u", name: "n", role: .member), serverTimeMs: 1, incarnation: "i"
        )
        XCTAssertFalse("\(reply)".contains("SECRET-TOKEN"))
        XCTAssertFalse(String(describing: reply).contains("SECRET-TOKEN"))
    }
}

final class ServerSyncErrorTests: XCTestCase {

    private func body(_ code: String, incarnation: String? = nil, have: Int64? = nil) -> ServerErrorBody {
        ServerErrorBody(error: .init(code: code, message: nil, hint: nil, incarnation: incarnation, have: have), incarnation: nil, have: nil)
    }

    func testStatusAndCodeMapToTheTypedFailure() {
        XCTAssertEqual(ServerSyncError.from(status: 401, body: body("enroll_invalid"), retryAfterSeconds: nil), .enrollInvalid)
        XCTAssertEqual(ServerSyncError.from(status: 401, body: body("unauthorized"), retryAfterSeconds: nil), .unauthorized)
        XCTAssertEqual(ServerSyncError.from(status: 409, body: body("incarnation_changed", incarnation: "new"), retryAfterSeconds: nil), .incarnationChanged("new"))
        XCTAssertEqual(ServerSyncError.from(status: 409, body: body("cookie_ahead", incarnation: "new"), retryAfterSeconds: nil), .cookieAhead("new"))
        XCTAssertEqual(ServerSyncError.from(status: 409, body: body("instance_conflict"), retryAfterSeconds: nil), .instanceConflict)
        XCTAssertEqual(ServerSyncError.from(status: 409, body: body("mutation_gap", have: 12), retryAfterSeconds: nil), .mutationGap(have: 12))
        XCTAssertEqual(ServerSyncError.from(status: 503, body: body("clock_behind"), retryAfterSeconds: nil), .clockBehind)
        XCTAssertEqual(ServerSyncError.from(status: 429, body: body("rate_limited"), retryAfterSeconds: 9), .rateLimited(retryAfterSeconds: 9))
        XCTAssertEqual(ServerSyncError.from(status: 502, body: nil, retryAfterSeconds: nil), .serverFailure(status: 502))
        XCTAssertEqual(ServerSyncError.from(status: 403, body: body("browser_refused"), retryAfterSeconds: nil), .refused(status: 403, code: "browser_refused"))
    }

    func testTheGapCountMayArriveAtTheTopLevelToo() {
        let top = ServerErrorBody(error: .init(code: "mutation_gap", message: nil, hint: nil, incarnation: nil, have: nil), incarnation: nil, have: 4)
        XCTAssertEqual(ServerSyncError.from(status: 409, body: top, retryAfterSeconds: nil), .mutationGap(have: 4))
    }

    func testOnlyFailuresThatMayPassAreTransient() {
        let transient: [ServerSyncError] = [.noNetwork, .offline("x"), .timedOut, .serverFailure(status: 500), .rateLimited(retryAfterSeconds: nil)]
        XCTAssertTrue(transient.allSatisfy(\.isTransient))
        let lasting: [ServerSyncError] = [.unauthorized, .enrollInvalid, .instanceConflict, .mutationGap(have: 1), .clockBehind, .appTooOld]
        XCTAssertTrue(lasting.allSatisfy { !$0.isTransient })
    }

    func testEachFailureLandsOnItsRowOfTheUXFailureTable() {
        XCTAssertEqual(ServerSyncError.timedOut.kind, .unreachable)
        XCTAssertEqual(ServerSyncError.nameNotFound.kind, .nameNotFound)
        XCTAssertEqual(ServerSyncError.enrollInvalid.kind, .codeRefused)
        XCTAssertEqual(ServerSyncError.rateLimited(retryAfterSeconds: 3).kind, .tooManyTries)
        XCTAssertEqual(ServerSyncError.notAFlaccyServer.kind, .notAFlaccyServer)
        XCTAssertEqual(ServerSyncError.serverTooOld.kind, .serverTooOld)
        XCTAssertEqual(ServerSyncError.appTooOld.kind, .appTooOld)
        XCTAssertEqual(ServerSyncError.clockBehind.kind, .serverClockWrong)
        XCTAssertEqual(ServerSyncError.diskFull.kind, .diskFull)
    }

    func testTheStatusAFailureLeavesBehind() {
        XCTAssertEqual(SyncStatus.after(failure: .noNetwork, server: "arch", pending: 4), .offline(server: "arch", pending: 4))
        XCTAssertEqual(SyncStatus.after(failure: .timedOut, server: "arch", pending: 4), .unreachable(server: "arch"))
        XCTAssertEqual(SyncStatus.after(failure: .appTooOld, server: "arch", pending: 0), .appNeedsUpdate)
        XCTAssertEqual(SyncStatus.after(failure: .serverTooOld, server: "arch", pending: 0), .serverNeedsUpdate)
        XCTAssertEqual(SyncStatus.after(failure: .diskFull, server: "arch", pending: 0), .serverDiskFull(server: "arch"))
        XCTAssertEqual(SyncStatus.after(failure: .clockBehind, server: "arch", pending: 0), .serverClockWrong(server: "arch"))
        XCTAssertEqual(SyncStatus.after(failure: .unauthorized, server: "arch", pending: 0), .deviceRemoved(server: "arch"))
        XCTAssertEqual(SyncStatus.readOnly(role: .guest, server: "arch"), .listenOnly(server: "arch"))
        XCTAssertEqual(SyncStatus.readOnly(role: .pending, server: "arch"), .awaitingApproval(server: "arch"))
        XCTAssertNil(SyncStatus.readOnly(role: .member, server: "arch"))
        XCTAssertNil(SyncStatus.readOnly(role: .admin, server: "arch"))
        XCTAssertTrue(SyncStatus.listenOnly(server: "arch").needsPerson)
        XCTAssertTrue(SyncStatus.awaitingApproval(server: "arch").needsPerson)
        XCTAssertTrue(ServerRole.member.canWrite && ServerRole.admin.canWrite)
        XCTAssertFalse(ServerRole.guest.canWrite || ServerRole.pending.canWrite)
        XCTAssertTrue(SyncStatus.notPro.needsPerson)
        XCTAssertFalse(SyncStatus.unreachable(server: "arch").needsPerson)
    }
}

final class ServerSyncBackoffTests: XCTestCase {

    func testThePauseDoublesFromHalfItsCeilingUpToTheCeiling() {
        let backoff = ServerSyncBackoff.standard
        XCTAssertEqual(backoff.pause(attempt: 0, jitter: 0), 0.25)
        XCTAssertEqual(backoff.pause(attempt: 0, jitter: 1), 0.5)
        XCTAssertEqual(backoff.pause(attempt: 1, jitter: 0), 0.5)
        XCTAssertEqual(backoff.pause(attempt: 3, jitter: 1), 4)
        XCTAssertEqual(backoff.pause(attempt: 9, jitter: 1), 8)
        XCTAssertEqual(backoff.pause(attempt: 40, jitter: 0), 4)
    }

    func testJitterOutsideTheUnitIntervalIsClamped() {
        let backoff = ServerSyncBackoff.standard
        XCTAssertEqual(backoff.pause(attempt: 2, jitter: -3), backoff.pause(attempt: 2, jitter: 0))
        XCTAssertEqual(backoff.pause(attempt: 2, jitter: 7), backoff.pause(attempt: 2, jitter: 1))
    }

    func testNoBackoffNeverWaitsAndTriesOnce() {
        XCTAssertEqual(ServerSyncBackoff.none.attempts, 1)
        XCTAssertEqual(ServerSyncBackoff.none.pause(attempt: 3, jitter: 0.9), 0)
    }
}
