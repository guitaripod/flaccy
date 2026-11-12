import FlaccyCore
import Foundation
import Security

/// Trusts a Flaccy Server on the local network by the pin of its key instead of by a certificate authority. With a pin it
/// accepts only that key; without one (an address typed by hand) it accepts the first key it sees and remembers its pin, so
/// enrolling can pin it from then on. A refused key cancels the challenge, which URLSession reports as `cancelled`: callers
/// ask `refusedKey` to tell that apart from a cancelled call.
nonisolated final class PinnedServerTrust: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    private let expected: String?
    private let lock = NSLock()
    private var seen: String?
    private var refused = false

    /// Trust for `trust`, or nil when the system's certificate authorities decide.
    static func make(for trust: ServerKeyTrust) -> PinnedServerTrust? {
        switch trust {
        case .system: nil
        case .pinned(let pin): PinnedServerTrust(expected: pin)
        case .firstContact: PinnedServerTrust(expected: nil)
        }
    }

    private init(expected: String?) {
        self.expected = expected
    }

    /// The pin of the key the last handshake showed.
    var seenPin: String? {
        lock.withLock { seen }
    }

    /// True once a handshake showed a key other than the pinned one.
    var refusedKey: Bool {
        lock.withLock { refused }
    }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        decide(challenge)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        decide(challenge)
    }

    private func decide(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else { return (.performDefaultHandling, nil) }
        guard let pin = Self.pin(of: trust) else {
            lock.withLock { refused = true }
            return (.cancelAuthenticationChallenge, nil)
        }
        let accepted = expected.map { CertificatePin.matches($0, pin) } ?? true
        lock.withLock {
            seen = pin
            if !accepted { refused = true }
        }
        return accepted ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
    }

    /// The pin of the leaf certificate's public key: the SHA-256 of the key's uncompressed point.
    static func pin(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              let key = SecCertificateCopyKey(leaf),
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data?
        else { return nil }
        return CertificatePin.pin(ofPublicKey: raw)
    }
}
