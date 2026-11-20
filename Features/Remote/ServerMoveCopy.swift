import FlaccyCore
import Foundation

/// The words of moving songs on this device to a server, shared by iPhone, iPad and the Mac.
nonisolated enum ServerMoveCopy {

    private enum Device {
        case phone
        case pad
        case mac

        static var current: Device {
            #if os(macOS)
            .mac
            #else
            DeviceKind.isPad ? .pad : .phone
            #endif
        }
    }

    private static func number(_ count: Int) -> String {
        LibraryLoadPhaseCopy.number(count)
    }

    static func title(server: String) -> String {
        String(localized: "Play from \(server)")
    }

    static func lead(songs: Int, server: String) -> String {
        let count = number(songs)
        switch (Device.current, songs == 1) {
        case (.phone, true): return String(localized: "1 song on this iPhone is also on \(server).")
        case (.phone, false): return String(localized: "\(count) songs on this iPhone are also on \(server).")
        case (.pad, true): return String(localized: "1 song on this iPad is also on \(server).")
        case (.pad, false): return String(localized: "\(count) songs on this iPad are also on \(server).")
        case (.mac, true): return String(localized: "1 song on this Mac is also on \(server).")
        case (.mac, false): return String(localized: "\(count) songs on this Mac are also on \(server).")
        }
    }

    static func promise(server: String) -> String {
        String(localized: "They can play from \(server) instead and keep their playlists, loves, plays and song volumes.")
    }

    static func freeUpTitle(bytes: Int64) -> String {
        String(localized: "Free Up \(RemoteCopy.byteText(bytes))")
    }

    static func freeUpDetail(server: String) -> String {
        String(localized: "Songs stream from \(server) on your network or over Tailscale. Download any of them again to play offline.")
    }

    static var keepLovedTitle: String {
        String(localized: "Keep Loved Songs Downloaded")
    }

    static func keepLovedDetail(songs: Int, bytes: Int64) -> String {
        let size = RemoteCopy.byteText(bytes)
        return songs == 1
            ? String(localized: "1 song, \(size)")
            : String(localized: "\(number(songs)) songs, \(size)")
    }

    static var keepTitle: String {
        String(localized: "Keep Them Downloaded")
    }

    static func keepDetail(server: String) -> String {
        String(localized: "Songs still play offline and now come from \(server). Nothing downloads again.")
    }

    static func staying(songs: Int, server: String) -> String {
        songs == 1
            ? String(localized: "1 song isn\u{2019}t on \(server), so it stays here.")
            : String(localized: "\(number(songs)) songs aren\u{2019}t on \(server), so they stay here.")
    }

    static var trashNote: String {
        String(localized: "Files this Mac no longer keeps go to the Trash.")
    }

    static func moveButton(songs: Int, server: String) -> String {
        songs == 1
            ? String(localized: "Play 1 Song from \(server)")
            : String(localized: "Play \(number(songs)) Songs from \(server)")
    }

    static var notNow: String {
        String(localized: "Not Now")
    }

    static func checking(server: String) -> String {
        String(localized: "Checking \(server)\u{2026}")
    }

    static func moving(server: String) -> String {
        String(localized: "Switching to \(server)\u{2026}")
    }

    static func progress(done: Int, total: Int) -> String {
        let read = number(min(done, total))
        return String(localized: "\(read) of \(number(total)) songs")
    }

    static var closeHint: String {
        String(localized: "You can close this. Flaccy finishes in the background.")
    }

    static func finished(songs: Int, server: String) -> String {
        songs == 1
            ? String(localized: "1 song now plays from \(server).")
            : String(localized: "\(number(songs)) songs now play from \(server).")
    }

    static func freed(bytes: Int64) -> String {
        String(localized: "Freed \(RemoteCopy.byteText(bytes)).")
    }

    static func kept(songs: Int) -> String {
        songs == 1
            ? String(localized: "1 stays downloaded for listening offline.")
            : String(localized: "\(number(songs)) stay downloaded for listening offline.")
    }

    static func notKept(songs: Int, server: String) -> String {
        songs == 1
            ? String(localized: "1 couldn\u{2019}t be kept downloaded, so it streams from \(server). Download it again to play it offline.")
            : String(localized: "\(number(songs)) couldn\u{2019}t be kept downloaded, so they stream from \(server). Download them again to play them offline.")
    }

    static var failedTitle: String {
        String(localized: "The songs didn\u{2019}t move")
    }

    static func nothing(server: String) -> String {
        switch Device.current {
        case .phone: String(localized: "None of the songs on this iPhone are on \(server).")
        case .pad: String(localized: "None of the songs on this iPad are on \(server).")
        case .mac: String(localized: "None of the songs on this Mac are on \(server).")
        }
    }

    static var sharingMac: String {
        String(localized: "This Mac shares its library with your other devices, so its music stays here.")
    }

    static var sectionHeader: String {
        switch Device.current {
        case .phone: String(localized: "On This iPhone")
        case .pad: String(localized: "On This iPad")
        case .mac: String(localized: "On This Mac")
        }
    }

    static func rowTitle(server: String) -> String {
        String(localized: "Songs Also on \(server)")
    }

    static func rowValue(songs: Int, bytes: Int64) -> String {
        "\(RemoteCopy.songs(songs)) \u{00B7} \(RemoteCopy.byteText(bytes))"
    }

    static func menuAction(server: String) -> String {
        String(localized: "Play Songs from \(server)\u{2026}")
    }

    static var tryAgain: String {
        String(localized: "Try Again")
    }

    static var done: String {
        String(localized: "Done")
    }
}
