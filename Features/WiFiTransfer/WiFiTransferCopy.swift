import Foundation

/// The words of Wi-Fi Transfer: the screen on the iPhone and the page the computer's browser shows, which is written
/// in the iPhone's language.
enum WiFiTransferCopy {
    static var title: String { String(localized: "Send Music over Wi-Fi") }
    static var subtitle: String { String(localized: "From any computer on the same Wi-Fi, in its web browser. Nothing to install.") }
    static var openThis: String { String(localized: "On your computer, open this address:") }
    static var copy: String { String(localized: "Copy") }
    static var copied: String { String(localized: "Copied") }
    static var share: String { String(localized: "Send Link") }
    static var stepNetwork: String { (DeviceKind.isPad ? String(localized: "Your computer and this iPad need to be on the same Wi-Fi.") : String(localized: "Your computer and this iPhone need to be on the same Wi-Fi.")) }
    static var stepBrowser: String { String(localized: "Type the address into Safari, Chrome, Edge or Firefox.") }
    static var stepDrop: String { String(localized: "Drop your music folders onto the page. Keep Flaccy open until they arrive.") }
    static var waiting: String { String(localized: "Waiting for your computer…") }
    static var offline: String { (DeviceKind.isPad ? String(localized: "Connect this iPad to Wi-Fi to send music to it.") : String(localized: "Connect this iPhone to Wi-Fi to send music to it.")) }
    static var listenerFailed: String { String(localized: "Wi-Fi Transfer couldn't start. Close this screen and open it again.") }
    static var outOfSpace: String { (DeviceKind.isPad ? String(localized: "This iPad is out of space. Free some up, then send the rest again.") : String(localized: "This iPhone is out of space. Free some up, then send the rest again.")) }
    static var serverPrompt: String { String(localized: "Rather stream your whole library without copying it?") }
    static var serverButton: String { String(localized: "Set Up Flaccy Server") }

    static func receiving(_ fileName: String) -> String {
        String(localized: "Receiving \u{201C}\(fileName)\u{201D}")
    }

    static func received(_ count: Int) -> String {
        String(localized: "\(count) songs received")
    }

    static func adding(_ count: Int) -> String {
        String(localized: "Adding \(count) songs to your library…")
    }

    /// Every string the upload page shows, by the key the page looks it up with. `{count}` and `{total}` are filled in
    /// by the page.
    static var page: [String: String] {
        [
            "title": String(localized: "Send music to Flaccy", comment: "Wi-Fi Transfer web page: title"),
            "lead": (DeviceKind.isPad ? String(localized: "Songs and whole folders go straight to your iPad.", comment: "Wi-Fi Transfer web page: line under the title") : String(localized: "Songs and whole folders go straight to your iPhone.", comment: "Wi-Fi Transfer web page: line under the title")),
            "drop": String(localized: "Drop music here", comment: "Wi-Fi Transfer web page: drop zone"),
            "or": String(localized: "or", comment: "Wi-Fi Transfer web page: between the drop zone and its buttons"),
            "chooseFolder": String(localized: "Choose a Folder", comment: "Wi-Fi Transfer web page: button"),
            "chooseFiles": String(localized: "Choose Files", comment: "Wi-Fi Transfer web page: button"),
            "formats": String(localized: "FLAC, ALAC, WAV, AIFF, MP3 and AAC, plus .lrc lyrics. Anything else is skipped.", comment: "Wi-Fi Transfer web page: what can be sent"),
            "keepOpen": (DeviceKind.isPad ? String(localized: "Keep Flaccy open on your iPad until everything has arrived.", comment: "Wi-Fi Transfer web page") : String(localized: "Keep Flaccy open on your iPhone until everything has arrived.", comment: "Wi-Fi Transfer web page")),
            "sending": String(localized: "Sending {count} of {total}…", comment: "Wi-Fi Transfer web page: progress; keep {count} and {total} as they are"),
            "sent": (DeviceKind.isPad ? String(localized: "Sent {count} of {total} to your iPad.", comment: "Wi-Fi Transfer web page: finished; keep {count} and {total} as they are") : String(localized: "Sent {count} of {total} to your iPhone.", comment: "Wi-Fi Transfer web page: finished; keep {count} and {total} as they are")),
            "skipped": String(localized: "Skipped {count} files that aren't music.", comment: "Wi-Fi Transfer web page; keep {count} as it is"),
            "nothing": String(localized: "Nothing to send: none of those files is music Flaccy plays.", comment: "Wi-Fi Transfer web page"),
            "failed": String(localized: "couldn't be sent", comment: "Wi-Fi Transfer web page: after a file's name"),
            "space": (DeviceKind.isPad ? String(localized: "your iPad is out of space", comment: "Wi-Fi Transfer web page: after a file's name") : String(localized: "your iPhone is out of space", comment: "Wi-Fi Transfer web page: after a file's name")),
            "unsupported": String(localized: "not a format Flaccy plays", comment: "Wi-Fi Transfer web page: after a file's name"),
            "unreachable": (DeviceKind.isPad ? String(localized: "lost the connection. Is Flaccy still open on your iPad?", comment: "Wi-Fi Transfer web page: after a file's name") : String(localized: "lost the connection. Is Flaccy still open on your iPhone?", comment: "Wi-Fi Transfer web page: after a file's name")),
        ]
    }
}
