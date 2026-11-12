import CryptoKit
import Foundation
import Security
import Testing

@testable import FlaccyServerEmbed

/// Accepts whatever key a server shows and remembers its pin, computed the way the app's `PinnedServerTrust` does: SHA-256 of
/// the key `SecKeyCopyExternalRepresentation` gives, as unpadded base64url.
private final class PinRecorder: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: String?

    var pin: String? { lock.withLock { seen } }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              let key = SecCertificateCopyKey(leaf),
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data?
        else { return (.cancelAuthenticationChallenge, nil) }
        let pin = Data(SHA256.hash(data: raw)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        lock.withLock { seen = pin }
        return (.useCredential, URLCredential(trust: trust))
    }
}

/// In the real-server suite, so it never runs beside another embedded server: one may run per process.
extension FlaccyServerHostTests {

    /// Opt-in with `FLACCY_LAN_TESTS=1`: the macOS application firewall lets a new unsigned test binary accept the TCP
    /// connection but never hands it the bytes until someone allows it, so on most Macs this would only time out.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FLACCY_LAN_TESTS"] == "1"))
    func aMacSharingOnItsNetworkAnswersOverTLSWithTheKeyItsLinkPins() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "flaccy-embed-lan-\(UUID().uuidString)", directoryHint: .isDirectory)
        let music = root.appending(path: "music", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = FlaccyServerHost()
        _ = try host.start(
            musicFolder: music, name: "LAN Test Mac", dataDirectory: root.appending(path: "data"), logDirectory: root.appending(path: "logs"),
            lan: true, lanName: "Flaccy-LAN-Test"
        )
        defer { try? host.stop() }
        var status = try host.status()
        for _ in 0..<300 where status.state != .running {
            try await Task.sleep(for: .milliseconds(100))
            status = try host.status()
        }
        #expect(status.state == .running)
        guard let localURL = status.localUrl, let pin = status.pin else {
            Issue.record("this Mac has no local network address, so sharing on it could not be checked")
            return
        }
        #expect(localURL.hasPrefix("https://Flaccy-LAN-Test.local:"))
        let local = try #require(status.addresses.first { address in
            ["10.", "192.168.", "172."].contains { address.hasPrefix($0) }
        })
        let enrollment = try host.enroll()
        #expect(enrollment.pin == pin)
        #expect(enrollment.link.contains("&pin="))

        let recorder = PinRecorder()
        let session = URLSession(configuration: .ephemeral, delegate: recorder, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let url = try #require(URL(string: "https://\(local)/flaccy/v1/hello"))
        let (_, response) = try await session.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(recorder.pin == pin, "the key Apple reads from the certificate is the one the server pins")
    }
}
