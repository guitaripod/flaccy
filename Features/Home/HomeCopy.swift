import Foundation
import FlaccyCore

/// Every word Home says on the iPhone and the Mac. Linux carries the same
/// English in `linux/shared/src/home_copy.rs`; keep the two word for word.
enum HomeCopy {

    static var home: String { String(localized: "Home") }
    static var seeAll: String { String(localized: "See All") }
    static var resume: String { String(localized: "Resume") }
    static var play: String { String(localized: "Play") }
    static var shuffle: String { String(localized: "Shuffle") }
    static var shuffleAlbum: String { String(localized: "Shuffle Album") }
    static var more: String { String(localized: "More") }
    static var playNext: String { String(localized: "Play after the current song") }
    static var yourQueue: String { String(localized: "Your Queue") }
    static var openRecap: String { String(localized: "Open Recap") }
    static var goToAlbum: String { String(localized: "Go to Album") }
    static var goToPlaylist: String { String(localized: "Go to Playlist") }
    static var playFromBeginning: String { String(localized: "Play from the Beginning") }
    static var removeFromJumpBackIn: String { String(localized: "Remove from Jump Back In") }
    static var playingNext: String { String(localized: "Playing next") }
    static var settings: String { String(localized: "Settings") }
    static var cancel: String { String(localized: "Cancel") }
    static var done: String { String(localized: "Done") }
    static var visibleOnHome: String { String(localized: "Show on Home") }

    static func title(for section: HomeSection) -> String {
        switch section {
        case .resume: String(localized: "Continue")
        case .jumpBackIn: String(localized: "Jump Back In")
        case .madeForYou: String(localized: "Made for You")
        case .recentlyAdded: String(localized: "Recently Added")
        case .onThisDay: String(localized: "On This Day")
        case .thisWeek: String(localized: "This Week")
        }
    }

    static func editSubtitle(for section: HomeSection) -> String {
        switch section {
        case .resume: String(localized: "Your last album or playlist")
        case .jumpBackIn: String(localized: "Six things you played recently")
        case .madeForYou: String(localized: "Mixes and Library Radio")
        case .recentlyAdded: String(localized: "New in your library")
        case .onThisDay: String(localized: "From your listening history")
        case .thisWeek: String(localized: "A glance at Recap")
        }
    }

    static var editHome: String { String(localized: "Edit Home") }
    static var customizeHome: String { String(localized: "Customize Home") }
    static var customizeHomeMenu: String { String(localized: "Customize Home…") }
    static var editIntro: String {
        String(localized: "Drag to reorder. Turn a section off to hide it; it stays here for when you want it back.")
    }
    static var editFooter: String {
        String(localized: "Home is put together on this device from your library and what you play. Sections with nothing to show stay out of the way.")
    }
    static var restoreDefault: String { String(localized: "Restore Default") }
    static var openAtLaunch: String { String(localized: "Open at launch") }
    static var whereYouLeftOff: String { String(localized: "Where you left off") }

    static func resumeKicker(_ recency: ResumeRecency) -> String {
        switch recency {
        case .justNow: return String(localized: "Continue · just now")
        case .earlierToday: return String(localized: "Continue · earlier today")
        case .lastNight: return String(localized: "Continue · last night")
        case .yesterday: return String(localized: "Continue · yesterday")
        case .weekday(let weekday):
            let name = Calendar.current.standaloneWeekdaySymbols[(weekday - 1 + 7) % 7]
            return String(localized: "Continue · \(name)")
        case .date(let date):
            return String(localized: "Continue · \(date.formatted(.dateTime.month(.abbreviated).day()))")
        }
    }

    static func trackLine(index: Int, title: String) -> String {
        "\(index) · \(title)"
    }

    /// "18 min left", "1 h 5 min left": minutes rounded up, never zero.
    static func remaining(_ seconds: Double) -> String {
        let minutes = max(Int((seconds / 60).rounded(.up)), 1)
        guard minutes >= 60 else { return String(localized: "\(minutes) min left") }
        return String(localized: "\(minutes / 60) h \(minutes % 60) min left")
    }

    static func songCount(_ count: Int) -> String {
        String(localized: "\(count) songs")
    }

    static func upNextKicker(isPlaying: Bool) -> String {
        isPlaying ? String(localized: "Up next · made for you") : String(localized: "Made for you")
    }

    /// "1 h 38 min" from an hour, else "38 min".
    static func duration(_ seconds: Double) -> String {
        let minutes = max(Int((seconds / 60).rounded()), 1)
        guard minutes >= 60 else { return String(localized: "\(minutes) min") }
        return String(localized: "\(minutes / 60) h \(minutes % 60) min")
    }

    static func mixMeta(count: Int, seconds: Double) -> String {
        "\(songCount(count)) · \(duration(seconds))"
    }

    static func startsWith(_ names: [String]) -> String? {
        switch names.count {
        case 0: return nil
        case 1: return String(localized: "Starts with \(names[0])")
        case 2: return String(localized: "Starts with \(names[0]) and \(names[1])")
        case 3: return String(localized: "Starts with \(names[0]), \(names[1]) and \(names[2])")
        default: return String(localized: "Starts with \(names[0]), \(names[1]), \(names[2]) and \(names[3])")
        }
    }

    static var dayOneKicker: String { String(localized: "Your library is ready") }
    static var dayOneTitle: String { String(localized: "Start anywhere") }
    static var shuffleLibrary: String { String(localized: "Shuffle Library") }
    static var radio: String { String(localized: "Radio") }

    static func dayOneCounts(songs: Int, albums: Int) -> String {
        String(localized: "\(songs) songs · \(albums) albums")
    }

    static func hiResCount(_ count: Int) -> String {
        String(localized: "\(count) of them hi-res")
    }

    static var getStartedTitle: String { String(localized: "Bring in your music") }
    static var getStartedBody: String {
        String(localized: "Add songs from the Files app, a NAS or your computer, or start with a free sample album.")
    }
    static var getStartedBodyMac: String {
        String(localized: "Choose a folder of music on this Mac, import files, or start with a free sample album.")
    }
    static var addMusic: String { String(localized: "Add Music") }
    static var playSampleAlbum: String { String(localized: "Play the Sample Album") }
    static var otherWaysToAdd: String { String(localized: "Other ways to add music") }
    static var keepListeningTitle: String { String(localized: "Keep listening with Flaccy Pro") }
    static var seePlans: String { String(localized: "See Plans") }
    static var restorePurchases: String { String(localized: "Restore Purchases") }

    static var libraryRadio: String { String(localized: "Library Radio") }
    static var libraryRadioSubtitle: String { String(localized: "Endless, from everything") }
    static var moreMixes: String { String(localized: "More mixes appear as you listen") }

    static func onThisDayHeadline(_ pick: OnThisDayPick) -> String {
        switch pick.kind {
        case .sameDay: String(localized: "On this day in \(String(pick.year))")
        case .yearAgoThisWeek: String(localized: "A year ago this week")
        }
    }

    static func onThisDayLine(_ pick: OnThisDayPick) -> String {
        String(localized: "\(pick.album), \(pick.plays) plays")
    }

    /// The iPhone card's detail under the album title.
    static func onThisDayDetail(_ pick: OnThisDayPick) -> String {
        switch pick.kind {
        case .sameDay: String(localized: "\(pick.plays) plays in \(String(pick.year))")
        case .yearAgoThisWeek: String(localized: "A year ago this week")
        }
    }

    static var thisWeek: String { String(localized: "This week") }

    /// "14 h 20 m", or "45 min" under an hour; truncated like Recap.
    static func listening(_ seconds: Int) -> String {
        let parts = WeekGlance.hoursAndMinutes(seconds)
        guard parts.hours > 0 else { return String(localized: "\(parts.minutes) min") }
        return String(localized: "\(parts.hours) h \(parts.minutes) m")
    }

    static func delta(_ delta: PeriodDelta) -> String? {
        switch delta {
        case .none: nil
        case .up(let percent): "▲ \(percent)%"
        case .down(let percent): "▼ \(percent)%"
        case .even: String(localized: "Even")
        case .new: String(localized: "New")
        }
    }

    static func plays(_ count: Int) -> String {
        String(localized: "\(count) plays")
    }
}
