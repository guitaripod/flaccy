import Foundation
import Testing

@testable import FlaccyServerEmbed

private struct Scratch {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "flaccy-embed-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
    }

    var music: URL { root.appending(path: "music", directoryHint: .isDirectory) }
    var data: URL { root.appending(path: "container/data", directoryHint: .isDirectory) }
    var logs: URL { root.appending(path: "container/logs", directoryHint: .isDirectory) }

    func addTinySong() throws {
        let album = music.appending(path: "Embed Test/Fixtures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let fixture = try #require(Bundle.module.url(forResource: "tiny", withExtension: "flac", subdirectory: "Resources"))
        try FileManager.default.copyItem(at: fixture, to: album.appending(path: "01 Tiny Tone.flac"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func waitForStatus(
    _ host: FlaccyServerHost,
    until reached: (ServerHostStatus) -> Bool
) async throws -> ServerHostStatus {
    let deadline = Date().addingTimeInterval(60)
    while Date() < deadline {
        let status = try host.status()
        if reached(status) { return status }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw ServerHostError.server("the server never reached the expected state: \(try host.status())")
}

private func request(_ method: String, _ url: URL, body: [String: String]? = nil) async throws -> (Int, Data) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    if let body {
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
}

@Suite(.serialized)
struct FlaccyServerHostTests {
    private let host = FlaccyServerHost()

    @Test func startsScansEnrollsAnswersAndStops() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.addTinySong()

        let started = try host.start(
            musicFolder: scratch.music, name: "Embed Test Mac", dataDirectory: scratch.data, logDirectory: scratch.logs)
        #expect([.starting, .running].contains(started.state))
        let running = try await waitForStatus(host) { $0.state == .running && $0.songCount == 1 }
        let loopback = try #require(running.addresses.first { $0.hasPrefix("127.0.0.1:") })
        let base = try #require(URL(string: "http://\(loopback)"))

        let enrollment = try host.enroll()
        #expect(enrollment.user == "owner")
        #expect(enrollment.link.hasPrefix("flaccy://server?url="))

        let (helloStatus, helloBody) = try await request("GET", base.appending(path: "flaccy/v1/hello"))
        #expect(helloStatus == 200)
        let hello = try #require(try JSONSerialization.jsonObject(with: helloBody) as? [String: Any])
        let server = try #require(hello["server"] as? [String: Any])
        #expect(server["name"] as? String == "Embed Test Mac")

        let device = ["enroll": enrollment.code, "name": "Test Mac client", "platform": "macos", "instance": "embed-test"]
        let (enrollStatus, _) = try await request("POST", base.appending(path: "flaccy/v1/devices"), body: device)
        #expect(enrollStatus == 201)
        #expect(try host.status().deviceCount == 1)

        try host.stop()
        #expect(try host.status().state == .stopped)
        try host.stop()
        #expect(FileManager.default.fileExists(atPath: scratch.logs.appending(path: "flaccy.log").path))
    }

    @Test func aMissingFolderAndAServerThatIsNotRunningThrowASentence() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let missing = scratch.root.appending(path: "gone", directoryHint: .isDirectory)
        #expect {
            try host.start(musicFolder: missing, name: "x", dataDirectory: scratch.data, logDirectory: scratch.logs)
        } throws: { error in
            (error as? ServerHostError).map { "\($0)".contains("Choose the folder again") } ?? false
        }
        try host.stop()
        #expect {
            try host.enroll()
        } throws: { error in
            (error as? ServerHostError) == .server("The library server is not running. Start it, then try again.")
        }
    }
}
