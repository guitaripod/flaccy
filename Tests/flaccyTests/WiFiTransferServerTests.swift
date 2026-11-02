import FlaccyCore
import Foundation
import Testing
@testable import flaccy

/// Drives the real server over loopback with URLSession, the way a browser on the same network would.
@MainActor
@Suite(.serialized)
struct WiFiTransferServerTests {

    /// Keeps the server's events in order and wakes a waiter when one arrives.
    @MainActor
    private final class EventLog {
        private(set) var events: [WiFiTransferEvent] = []

        func record(_ event: WiFiTransferEvent) {
            events.append(event)
        }

        func waitFor(_ match: (WiFiTransferEvent) -> Bool) async -> WiFiTransferEvent? {
            for _ in 0..<200 {
                if let event = events.first(where: match) { return event }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return nil
        }
    }

    private struct Rig {
        let server: WiFiTransferServer
        let log: EventLog
        let root: URL
        let port: UInt16

        func url(_ path: String) -> URL {
            URL(string: "http://127.0.0.1:\(port)/\(server.token)/\(path)")!
        }

        func put(_ body: Data, path: String, batch: String = "b1") async throws -> Int {
            var request = URLRequest(url: url("upload?batch=\(batch)&path=\(path)"))
            request.httpMethod = "PUT"
            let (_, response) = try await URLSession.shared.upload(for: request, from: body)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }

        func done(batch: String = "b1") async throws -> Int {
            var request = URLRequest(url: url("done?batch=\(batch)"))
            request.httpMethod = "POST"
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }
    }

    private func makeRig(freeSpace: Int64? = nil) async throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wifi-transfer-\(UUID().uuidString)", isDirectory: true)
        let log = EventLog()
        let server = WiFiTransferServer(
            token: WiFiTransferProtocol.makeToken(),
            stagingRoot: root,
            page: Data("<html>page</html>".utf8),
            acceptedExtensions: ["flac", "lrc"],
            freeSpace: { _ in freeSpace },
            onEvent: { log.record($0) }
        )
        server.start()
        let listening = await log.waitFor { if case .listening = $0 { true } else { false } }
        guard case .listening(let port) = listening else {
            server.stop()
            throw CancellationError()
        }
        return Rig(server: server, log: log, root: root, port: port)
    }

    @Test func servesThePageOnlyUnderTheToken() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop(); try? FileManager.default.removeItem(at: rig.root) }

        let (page, response) = try await URLSession.shared.data(from: rig.url(""))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: page, encoding: .utf8) == "<html>page</html>")

        let (_, guessed) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(rig.port)/zzzzzz/")!)
        #expect((guessed as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test func aSongIsStagedUnderItsBatchAndTheBatchIsHandedOverWhenDone() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop(); try? FileManager.default.removeItem(at: rig.root) }
        let song = Data((0..<300_000).map { UInt8($0 % 251) })

        #expect(try await rig.put(song, path: "Bach%2FGoldberg%2F01%20Aria.flac") == 201)
        #expect(try await rig.done() == 200)

        let staged = rig.root.appendingPathComponent("b1/Bach/Goldberg/01 Aria.flac")
        #expect(try Data(contentsOf: staged) == song)
        let partLeft = FileManager.default.fileExists(atPath: rig.root.appendingPathComponent("b1/Bach/Goldberg/.01 Aria.flac.part").path)
        #expect(!partLeft)
        let finished = await rig.log.waitFor { if case .batchFinished = $0 { true } else { false } }
        #expect(finished == .batchFinished(folder: rig.root.appendingPathComponent("b1", isDirectory: true)))
        #expect(rig.log.events.contains(.received(fileName: "01 Aria.flac")))
    }

    @Test func whatFlaccyCannotImportIsRefusedAndNotStored() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop(); try? FileManager.default.removeItem(at: rig.root) }

        #expect(try await rig.put(Data("x".utf8), path: "cover.jpg") == 415)
        #expect(try await rig.put(Data("x".utf8), path: "..%2Fescape.flac") == 400)
        #expect(!FileManager.default.fileExists(atPath: rig.root.path))
    }

    @Test func aSongThatWouldNotFitIsRefusedBeforeAByteIsWritten() async throws {
        let rig = try await makeRig(freeSpace: 1024)
        defer { rig.server.stop(); try? FileManager.default.removeItem(at: rig.root) }

        #expect(try await rig.put(Data(count: 4096), path: "big.flac") == 507)
        let dropped = await rig.log.waitFor { if case .dropped = $0 { true } else { false } }
        #expect(dropped == .dropped(fileName: "big.flac", reason: .noSpace))
        #expect(!FileManager.default.fileExists(atPath: rig.root.appendingPathComponent("b1").path))
    }

    @Test func doneForABatchThatSentNothingHandsNothingOver() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop(); try? FileManager.default.removeItem(at: rig.root) }

        #expect(try await rig.done(batch: "empty") == 200)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!rig.log.events.contains { if case .batchFinished = $0 { true } else { false } })
    }

    @Test func theUploadPageCarriesTheStringsAndFormats() throws {
        let page = String(decoding: WiFiTransferSession.page(), as: UTF8.self)
        #expect(page.contains("\"chooseFolder\""))
        #expect(page.contains("\"flac\""))
        #expect(!page.contains("__FLACCY_"))
    }
}
