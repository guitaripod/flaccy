import FlaccyCore
import Foundation

/// One row of the failure table of docs/server/UX.md section 3 as the sheet shows it: the title, the body, and the buttons in
/// the order they appear.
nonisolated struct FailureCopy: Equatable, Sendable {

    enum Action: Equatable, Sendable {
        case tryAgain
        case openTailscale
        case addAsRegularServer
        case openAppStore
        case dismiss
        case cancel
    }

    struct Button: Equatable, Sendable {
        let title: String
        let action: Action
    }

    let failure: ServerSetupFailure
    let title: String
    let body: String
    let buttons: [Button]

    init(_ failure: ServerSetupFailure) {
        self.failure = failure
        switch failure {
        case .unreachable(let server):
            title = String(localized: "Can't reach \(server)")
            body = String(localized: "Is Tailscale on? Open Tailscale and connect on this device and on \(server), then try again.")
            buttons = [Button(title: Self.openTailscale, action: .openTailscale), Button(title: Self.tryAgain, action: .tryAgain)]
        case .nameNotFound(let server):
            title = String(localized: "Can't find \(server)")
            body = String(localized: "Check the name on the server with `tailscale status`, or scan the code from the server.")
            buttons = [Button(title: Self.tryAgain, action: .tryAgain)]
        case .codeRefused(let server):
            title = String(localized: "That code didn't work")
            body = String(localized: "A code works once and expires after 10 minutes. On \(server), run `flaccy-server enroll` for a new one.")
            buttons = [Button(title: Self.tryAgain, action: .tryAgain)]
        case .tooManyTries:
            title = String(localized: "Too many tries")
            body = String(localized: "Wait a minute, then try again.")
            buttons = [Button(title: Self.ok, action: .dismiss)]
        case .notAFlaccyServer(let server):
            title = String(localized: "\(server) isn't a Flaccy Server")
            body = String(localized: "It answered, but not as Flaccy Server. If it is Navidrome or another Subsonic server, add it as a regular server.")
            buttons = [
                Button(title: String(localized: "Add as regular server"), action: .addAsRegularServer),
                Button(title: String(localized: "Cancel"), action: .cancel),
            ]
        case .serverTooOld:
            title = String(localized: "Update your Flaccy Server")
            body = String(localized: "This version of Flaccy needs Flaccy Server 1.0 or newer.")
            buttons = [Button(title: Self.ok, action: .dismiss)]
        case .appTooOld(let server):
            title = String(localized: "Update Flaccy")
            body = String(localized: "\(server) needs a newer Flaccy than this one.")
            buttons = [Button(title: String(localized: "Open App Store"), action: .openAppStore)]
        case .serverClockWrong(let server):
            title = String(localized: "The clock on \(server) is wrong")
            body = String(localized: "Sync stays off until the server's date and time are right. Check it with `timedatectl`.")
            buttons = [Button(title: Self.ok, action: .dismiss)]
        case .other(let server):
            title = String(localized: "Couldn't connect to \(server)")
            body = String(localized: "Something unexpected went wrong. Try again, and if it keeps happening, check that \(server) is running Flaccy Server.")
            buttons = [Button(title: Self.tryAgain, action: .tryAgain)]
        }
    }

    private static var tryAgain: String { String(localized: "Try again") }
    private static var openTailscale: String { String(localized: "Open Tailscale") }
    private static var ok: String { String(localized: "OK") }
}
