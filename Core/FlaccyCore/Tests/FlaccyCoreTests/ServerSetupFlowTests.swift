import XCTest
@testable import FlaccyCore

final class ServerSetupFlowTests: XCTestCase {

    private actor FakeGateway: ServerSetupGateway {
        let helloResult: Result<ServerHello, ServerSyncError>
        let connectResult: Result<ServerSetupConnection, ServerSyncError>
        private(set) var connectedWith: FlaccyServerLink?
        private(set) var connectCalls = 0

        init(
            hello: Result<ServerHello, ServerSyncError> = .success(.fixture()),
            connect: Result<ServerSetupConnection, ServerSyncError> = .success(.fixture)
        ) {
            helloResult = hello
            connectResult = connect
        }

        func hello(baseURL: URL) async throws -> ServerHello { try helloResult.get() }

        func connect(link: FlaccyServerLink, deviceName: String) async throws -> ServerSetupConnection {
            connectCalls += 1
            connectedWith = link
            return try connectResult.get()
        }
    }

    private func run(
        _ gateway: FakeGateway, address: String = "arch", code: String = "abcd efgh", linkName: String? = nil
    ) async throws -> ServerSetupResult {
        let input = try XCTUnwrap(ServerAddressInput(address))
        return await ServerSetupFlow(gateway: gateway).connect(
            address: input, typedCode: code, linkName: linkName, deviceName: "iPhone", serverNamed: { _ in }
        )
    }

    func testAnAnsweringServerIsEnrolledWithTheNormalisedCode() async throws {
        let gateway = FakeGateway()
        let result = try await run(gateway, code: "abco-efgl")
        XCTAssertEqual(result, .connected(.fixture))
        let link = await gateway.connectedWith
        XCTAssertEqual(link?.enrollmentCode, "ABC0EFG1")
        XCTAssertEqual(link?.baseURL.absoluteString, "http://arch:4545")
    }

    func testTheServersOwnNameIsReportedAsSoonAsItAnswers() async throws {
        let gateway = FakeGateway(hello: .success(.fixture(name: "Study")))
        let named = NamedBox()
        let input = try XCTUnwrap(ServerAddressInput("100.91.211.44"))
        _ = await ServerSetupFlow(gateway: gateway).connect(
            address: input, typedCode: "A", linkName: nil, deviceName: "iPhone", serverNamed: { named.set($0) }
        )
        XCTAssertEqual(named.value, "Study")
    }

    func testEveryRowOfTheFailureTableWhetherTheProbeOrTheEnrollmentFails() async throws {
        let table: [(ServerSyncError, ServerSetupFailure)] = [
            (.timedOut, .unreachable(server: "arch")),
            (.noNetwork, .unreachable(server: "arch")),
            (.offline("refused"), .unreachable(server: "arch")),
            (.nameNotFound, .nameNotFound(server: "arch")),
            (.enrollInvalid, .codeRefused(server: "arch")),
            (.rateLimited(retryAfterSeconds: 60), .tooManyTries),
            (.notAFlaccyServer, .notAFlaccyServer(server: "arch")),
            (.serverTooOld, .serverTooOld),
            (.appTooOld, .appTooOld(server: "arch")),
            (.clockBehind, .serverClockWrong(server: "arch")),
            (.serverFailure(status: 500), .other(server: "arch")),
            (.malformed("the device token could not be stored"), .other(server: "arch")),
        ]
        for (error, failure) in table {
            let probing = FakeGateway(hello: .failure(error))
            let probed = try await run(probing)
            let enrollCallsAfterProbe = await probing.connectCalls
            XCTAssertEqual(probed, .failed(failure), "\(error) while probing")
            XCTAssertEqual(enrollCallsAfterProbe, 0, "a failed probe never spends the code")

            let enrolling = FakeGateway(connect: .failure(error))
            let enrolled = try await run(enrolling)
            XCTAssertEqual(enrolled, .failed(failure), "\(error) while enrolling")
        }
    }

    func testAServerThatSpeaksANewerProtocolNeedsANewerApp() async throws {
        let gateway = FakeGateway(hello: .success(.fixture(protocols: [2, 3])))
        let result = try await run(gateway)
        XCTAssertEqual(result, .failed(.appTooOld(server: "arch")))
        let calls = await gateway.connectCalls
        XCTAssertEqual(calls, 0)
    }

    func testAServerWithoutSyncOrWithOnlyAnOlderProtocolNeedsAnUpdate() async throws {
        let withoutSync = FakeGateway(hello: .success(.fixture(features: ["live"])))
        let olderProtocol = FakeGateway(hello: .success(.fixture(protocols: [0])))
        let first = try await run(withoutSync)
        let second = try await run(olderProtocol)
        XCTAssertEqual(first, .failed(.serverTooOld))
        XCTAssertEqual(second, .failed(.serverTooOld))
    }

    func testAnEmptyCodeNeverReachesTheServer() async throws {
        let gateway = FakeGateway()
        let result = try await run(gateway, code: " - ")
        XCTAssertEqual(result, .failed(.codeRefused(server: "arch")))
        let calls = await gateway.connectCalls
        XCTAssertEqual(calls, 0)
    }

    func testALinkNameWinsOverTheServersOwnInMessages() async throws {
        let gateway = FakeGateway(hello: .failure(.timedOut))
        let result = try await run(gateway, linkName: "Basement")
        XCTAssertEqual(result, .failed(.unreachable(server: "Basement")))
    }

    func testAnErrorThatIsNotAServerErrorIsGeneric() {
        struct Odd: Error {}
        XCTAssertEqual(ServerSetupFailure(error: Odd(), server: "arch"), .other(server: "arch"))
    }
}

private final class NamedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? { lock.withLock { stored } }
    func set(_ value: String) { lock.withLock { stored = value } }
}

extension ServerSetupConnection {
    fileprivate static let fixture = ServerSetupConnection(serverName: "arch", baseURL: URL(string: "http://arch:4545")!)
}

extension ServerHello {
    fileprivate static func fixture(
        name: String = "arch", protocols: [Int] = [1], features: [String] = ["sync", "live"]
    ) -> ServerHello {
        ServerHello(
            protocols: protocols, server: ServerInfo(name: name, version: "1.0.0", schema: 1), features: features,
            mode: "easy", serverTimeMs: 1_790_000_000_000, incarnation: "i"
        )
    }
}
