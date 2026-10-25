import FlaccyCore
import Foundation

/// Why a call to a music server failed, worded for the person: what failed, the cause, and
/// what to do next. Every case carries the host it is about, so a person with two servers
/// can tell which one is meant.
nonisolated enum RemoteFailure: Error, Equatable, Sendable {
    case invalidAddress
    case unreachable(host: String)
    case tlsFailure(host: String)
    case wrongPassword(host: String)
    case wrongAPIKey(host: String)
    case tokenAuthUnsupported(host: String)
    case notSubsonic(host: String)
    case httpStatus(Int, host: String)
    case server(code: Int, message: String)
    case storage
    case keychain
    case songMissing

    /// The failure a server names in its `error` object.
    init(subsonic failure: SubsonicFailure, code: Int?, message: String?, host: String) {
        switch failure {
        case .wrongCredentials: self = .wrongPassword(host: host)
        case .invalidAPIKey: self = .wrongAPIKey(host: host)
        case .tokenAuthUnsupported: self = .tokenAuthUnsupported(host: host)
        default: self = .server(code: code ?? 0, message: message ?? "")
        }
    }

    /// The failure a transport error stands for.
    init(transport error: URLError, host: String) {
        switch error.code {
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired,
             .secureConnectionFailed:
            self = .tlsFailure(host: host)
        case .badURL, .unsupportedURL:
            self = .invalidAddress
        default:
            self = .unreachable(host: host)
        }
    }

    /// The failure any error stands for: a failure passes through, a transport error is mapped,
    /// anything else is reported as the server being unreachable.
    static func from(_ error: Error, host: String) -> RemoteFailure {
        if let failure = error as? RemoteFailure { return failure }
        if let urlError = error as? URLError { return RemoteFailure(transport: urlError, host: host) }
        return .unreachable(host: host)
    }
}

extension RemoteFailure: LocalizedError {

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            String(localized: "That server address can\u{2019}t be read. Type it like music.example.com or http://192.168.1.20:4533, then try again.")
        case .unreachable(let host):
            String(localized: "Flaccy can\u{2019}t reach \(host). The server didn\u{2019}t answer. Check that it is running and that this device is on the same network or Tailscale, then try again.")
        case .tlsFailure(let host):
            String(localized: "Flaccy couldn\u{2019}t make a secure connection to \(host). Its certificate isn\u{2019}t trusted. Use the server\u{2019}s http:// address on your own network, or give it a valid certificate, then try again.")
        case .wrongPassword(let host):
            String(localized: "\(host) refused the username or password. Check both and try again.")
        case .wrongAPIKey(let host):
            String(localized: "\(host) refused the API key. Create a new key in the server\u{2019}s settings and try again.")
        case .tokenAuthUnsupported(let host):
            String(localized: "\(host) doesn\u{2019}t accept password sign-in from apps. Use an API key instead: create one in the server\u{2019}s settings and enter it here.")
        case .notSubsonic(let host):
            String(localized: "\(host) answered, but it isn\u{2019}t a Subsonic or OpenSubsonic server. Check the address and the port, then try again.")
        case .httpStatus(let code, let host):
            String(localized: "\(host) answered with an HTTP \(code) error. A proxy in front of the server, or the server itself, is failing. Try again in a moment, or check the server\u{2019}s log.")
        case .server(let code, let message):
            String(localized: "The server reported error \(code): \(message). Check its settings and try again.")
        case .storage:
            String(localized: "Flaccy couldn\u{2019}t save the song on this device. Free some space and try again.")
        case .songMissing:
            String(localized: "This song is no longer in your library. Refresh the library to update the list.")
        case .keychain:
            String(localized: "Flaccy couldn\u{2019}t store the sign-in in this device\u{2019}s Keychain. Unlock the device and try again.")
        }
    }
}
