import FlaccyCore
import XCTest
@testable import flaccy

nonisolated final class FailureCopyTests: XCTestCase {

    private struct Row: Sendable {
        let failure: ServerSetupFailure
        let title: String
        let body: String
        let buttons: [(String, FailureCopy.Action)]
    }

    @MainActor func testEveryRowReadsExactlyAsTheExperienceContractWordsIt() {
        let rows = [
            Row(
                failure: .unreachable(server: "arch"), title: "Can't reach arch",
                body: "Check that arch is on and on the same Wi-Fi as this device, or that Tailscale is on for both. Then try again.",
                buttons: [("Try again", .tryAgain), ("Open Tailscale", .openTailscale)]
            ),
            Row(
                failure: .nameNotFound(server: "arch"), title: "Can't find arch",
                body: "Check the address shown on arch, or scan its code again.",
                buttons: [("Try again", .tryAgain)]
            ),
            Row(
                failure: .codeRefused(server: "arch"), title: "That code didn't work",
                body: "A code works once and lasts 10 minutes. Make a new one on arch and try again.",
                buttons: [("Try again", .tryAgain)]
            ),
            Row(
                failure: .keyChanged(server: "arch"), title: "arch has a new security key",
                body: "It doesn't match the key from when this device was added, so nothing was sent. If arch was reinstalled or moved, remove it and add it again with a new code.",
                buttons: [("OK", .dismiss)]
            ),
            Row(
                failure: .tooManyTries, title: "Too many tries", body: "Wait a minute, then try again.",
                buttons: [("OK", .dismiss)]
            ),
            Row(
                failure: .notAFlaccyServer(server: "arch"), title: "arch isn't a Flaccy Server",
                body: "It answered, but not as Flaccy Server. If it is Navidrome or another Subsonic server, add it as a regular server.",
                buttons: [("Add as regular server", .addAsRegularServer), ("Cancel", .cancel)]
            ),
            Row(
                failure: .serverTooOld, title: "Update your Flaccy Server",
                body: "This version of Flaccy needs Flaccy Server 1.0 or newer. Update Flaccy on the Mac that shares, or the flaccy-server package on the computer that runs it.",
                buttons: [("OK", .dismiss)]
            ),
            Row(
                failure: .appTooOld(server: "arch"), title: "Update Flaccy",
                body: "arch needs a newer Flaccy than this one.", buttons: [("Open App Store", .openAppStore)]
            ),
            Row(
                failure: .serverClockWrong(server: "arch"), title: "The clock on arch is wrong",
                body: "Sync stays off until the date and time on arch are right.",
                buttons: [("OK", .dismiss)]
            ),
        ]
        for row in rows {
            let copy = FailureCopy(row.failure)
            XCTAssertEqual(copy.title, row.title)
            XCTAssertEqual(copy.body, row.body)
            XCTAssertEqual(copy.buttons.map(\.title), row.buttons.map(\.0), row.title)
            XCTAssertEqual(copy.buttons.map(\.action), row.buttons.map(\.1), row.title)
        }
    }

    @MainActor func testAFailureTheTableDoesNotNameStillSaysWhatToDoNext() {
        let copy = FailureCopy(.other(server: "arch"))
        XCTAssertEqual(copy.title, "Couldn't connect to arch")
        XCTAssertEqual(copy.buttons.map(\.action), [.tryAgain])
        XCTAssertTrue(copy.body.contains("arch"))
    }
}
