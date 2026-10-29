import FlaccyCore
import XCTest
@testable import flaccy

nonisolated final class AddFlaccyServerViewModelTests: XCTestCase {

    private actor FakeGateway: ServerSetupGateway {
        var helloResult: Result<ServerHello, ServerSyncError> = .success(FakeGateway.hello)
        var connectResult: Result<ServerSetupConnection, ServerSyncError> = .success(
            ServerSetupConnection(serverName: "arch", baseURL: URL(string: "http://arch:4545")!)
        )
        private(set) var helloCalls = 0
        private(set) var connectCalls = 0
        private(set) var enrolledCode: String?

        static let hello = ServerHello(
            protocols: [1], server: ServerInfo(name: "arch", version: "1.0.0", schema: 1), features: ["sync", "live"],
            mode: "easy", serverTimeMs: 1, incarnation: "i"
        )

        func failHello(with error: ServerSyncError) { helloResult = .failure(error) }
        func failConnect(with error: ServerSyncError) { connectResult = .failure(error) }

        func hello(baseURL: URL) async throws -> ServerHello {
            helloCalls += 1
            return try helloResult.get()
        }

        func connect(link: FlaccyServerLink, deviceName: String) async throws -> ServerSetupConnection {
            connectCalls += 1
            enrolledCode = link.enrollmentCode
            return try connectResult.get()
        }
    }

    @MainActor private final class FakeFollowUp: ServerSetupFollowUp {
        var finished = 0
        var libraryAdded = true

        func finish(_ connection: ServerSetupConnection) async -> Bool {
            finished += 1
            return libraryAdded
        }
    }

    @MainActor private func makeModel(_ gateway: FakeGateway = FakeGateway(), followUp: FakeFollowUp = FakeFollowUp()) -> AddFlaccyServerViewModel {
        AddFlaccyServerViewModel(gateway: gateway, followUp: followUp, deviceName: "iPhone")
    }

    @MainActor func testALinkFillsTheFieldsAndNeverConnects() async throws {
        let gateway = FakeGateway()
        let model = makeModel(gateway)
        let link = try XCTUnwrap(FlaccyServerLink(text: "flaccy://server?url=http%3A%2F%2Farch%3A4545&enroll=abcdefghjkmn&name=arch"))

        model.apply(link: link)

        XCTAssertEqual(model.address, "http://arch:4545")
        XCTAssertEqual(model.code, "ABCD-EFGH-JKMN")
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(model.canConnect)
        let hellos = await gateway.helloCalls
        let connects = await gateway.connectCalls
        XCTAssertEqual(hellos, 0)
        XCTAssertEqual(connects, 0)
    }

    @MainActor func testTheCodeGroupsAsItIsTypedAndReadsLookAlikes() {
        let model = makeModel()
        model.code = "abco"
        XCTAssertEqual(model.code, "ABC0")
        model.code = "abc0 il"
        XCTAssertEqual(model.code, "ABC0-11")
    }

    @MainActor func testConnectNeedsAnAddressAndACode() {
        let model = makeModel()
        XCTAssertFalse(model.canConnect)
        model.address = "arch"
        XCTAssertFalse(model.canConnect)
        model.code = "ABCD"
        XCTAssertTrue(model.canConnect)
        model.address = "ftp://arch"
        XCTAssertFalse(model.canConnect)
    }

    @MainActor func testConnectingEnrollsWithTheNormalisedCodeAndReportsTheServer() async {
        let gateway = FakeGateway()
        let followUp = FakeFollowUp()
        let model = makeModel(gateway, followUp: followUp)
        model.address = "arch"
        model.code = "abcd-efgh"

        await model.connect()

        XCTAssertEqual(model.state, .connected(.init(serverName: "arch", libraryAdded: true)))
        let code = await gateway.enrolledCode
        XCTAssertEqual(code, "ABCDEFGH")
        XCTAssertEqual(followUp.finished, 1)
    }

    @MainActor func testAMusicLibraryThatCouldNotBeAddedIsReportedNotHidden() async {
        let followUp = FakeFollowUp()
        followUp.libraryAdded = false
        let model = makeModel(followUp: followUp)
        model.address = "arch"
        model.code = "ABCD"

        await model.connect()

        XCTAssertEqual(model.state, .connected(.init(serverName: "arch", libraryAdded: false)))
    }

    @MainActor func testEveryRowOfTheFailureTableReachesTheSheet() async {
        let table: [(ServerSyncError, ServerSetupFailure)] = [
            (.timedOut, .unreachable(server: "arch")),
            (.nameNotFound, .nameNotFound(server: "arch")),
            (.enrollInvalid, .codeRefused(server: "arch")),
            (.rateLimited(retryAfterSeconds: nil), .tooManyTries),
            (.notAFlaccyServer, .notAFlaccyServer(server: "arch")),
            (.serverTooOld, .serverTooOld),
            (.appTooOld, .appTooOld(server: "arch")),
            (.clockBehind, .serverClockWrong(server: "arch")),
        ]
        for (error, failure) in table {
            for probing in [true, false] {
                let gateway = FakeGateway()
                if probing { await gateway.failHello(with: error) } else { await gateway.failConnect(with: error) }
                let followUp = FakeFollowUp()
                let model = makeModel(gateway, followUp: followUp)
                model.address = "arch"
                model.code = "ABCD"

                await model.connect()

                XCTAssertEqual(model.state, .failed(FailureCopy(failure)), "\(error), probing: \(probing)")
                XCTAssertEqual(followUp.finished, 0)
            }
        }
    }

    @MainActor func testEditingAfterAFailureReturnsToIdle() async {
        let gateway = FakeGateway()
        await gateway.failConnect(with: .enrollInvalid)
        let model = makeModel(gateway)
        model.address = "arch"
        model.code = "ABCD"
        await model.connect()
        guard case .failed = model.state else { return XCTFail("expected a failure") }

        model.code = "ABCDE"

        XCTAssertEqual(model.state, .idle)
    }

    @MainActor func testTheViewIsToldWhenTheFieldsChangeSoConnectCanEnable() {
        let model = makeModel()
        var changes = 0
        model.onChange = { changes += 1 }
        model.address = "arch"
        model.code = "A"
        XCTAssertEqual(changes, 2)
    }

    @MainActor func testTheProbeNeverSpendsTheCodeOnAServerThatIsNotFlaccy() async {
        let gateway = FakeGateway()
        await gateway.failHello(with: .notAFlaccyServer)
        let model = makeModel(gateway)
        model.address = "navidrome"
        model.code = "ABCD"

        await model.connect()

        let connects = await gateway.connectCalls
        XCTAssertEqual(connects, 0)
        guard case .failed(let copy) = model.state else { return XCTFail("expected a failure") }
        XCTAssertEqual(copy.buttons.map(\.action), [.addAsRegularServer, .cancel])
    }
}
