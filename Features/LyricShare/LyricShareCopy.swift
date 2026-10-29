import FlaccyCore
import Foundation

/// The words of the lyric share sheet on the Apple clients. The Linux client
/// carries the same English in `linux/src/lyric_share/copy.rs`.
nonisolated enum LyricShareCopy {

    static var sheetTitle: String { String(localized: "Share Lyrics") }
    static var menuTitle: String { String(localized: "Share Lyrics…") }
    static var fromLine: String { String(localized: "Share from This Line") }
    static var templateHeader: String { String(localized: "Template") }
    static var formatHeader: String { String(localized: "Format") }
    static var colorsHeader: String { String(localized: "Colors") }
    static var fontHeader: String { String(localized: "Font") }
    static var linesHeader: String { String(localized: "Lines") }
    static var showCover: String { String(localized: "Cover") }
    static var showVisualizer: String { String(localized: "Visualizer") }
    static var showMark: String { String(localized: "Flaccy Mark") }
    static var shareVideo: String { String(localized: "Share Video") }
    static var shareImage: String { String(localized: "Share Image") }
    static var saveVideo: String { String(localized: "Save Video…") }
    static var saveImage: String { String(localized: "Save Image…") }
    static var making: String { String(localized: "Making your video…") }
    static var playPreview: String { String(localized: "Play Preview") }
    static var pausePreview: String { String(localized: "Pause Preview") }
    static var readingAudio: String { String(localized: "Reading the song…") }
    static var close: String { String(localized: "Close") }
    static var nothingToShare: String {
        String(localized: "Couldn't open Share Lyrics because this song has no lines to share. Play a song with lyrics and try again.")
    }

    static func saved(_ name: String) -> String {
        String(localized: "Saved “\(name)”")
    }

    static func saveFailure(_ name: String, reason: String) -> String {
        String(localized: "Couldn't save “\(name)” (\(reason)). Choose another folder and try again.")
    }

    static func template(_ template: LyricShareTemplate) -> String {
        switch template {
        case .spotlight: return String(localized: "Spotlight")
        case .verse: return String(localized: "Verse")
        case .poster: return String(localized: "Poster")
        case .pulse: return String(localized: "Pulse")
        }
    }

    static func templateHint(_ template: LyricShareTemplate) -> String {
        switch template {
        case .spotlight: return String(localized: "One big line at a time")
        case .verse: return String(localized: "The verse scrolls past")
        case .poster: return String(localized: "Cover art with every line")
        case .pulse: return String(localized: "A disc that moves with the music")
        }
    }

    static func templateSymbol(_ template: LyricShareTemplate) -> String {
        switch template {
        case .spotlight: return "text.aligncenter"
        case .verse: return "text.alignleft"
        case .poster: return "photo.artframe"
        case .pulse: return "dot.radiowaves.left.and.right"
        }
    }

    static func format(_ format: LyricShareFormat) -> String {
        switch format {
        case .story: return String(localized: "Story")
        case .portrait: return String(localized: "Post")
        case .square: return String(localized: "Square")
        case .wide: return String(localized: "Wide")
        }
    }

    static func theme(_ theme: LyricShareTheme) -> String {
        switch theme {
        case .artwork: return String(localized: "Artwork")
        case .vivid: return String(localized: "Vivid")
        case .dark: return String(localized: "Dark")
        case .light: return String(localized: "Light")
        }
    }

    static func typeface(_ typeface: LyricShareTypeface) -> String {
        switch typeface {
        case .modern: return String(localized: "Modern")
        case .serif: return String(localized: "Serif")
        case .rounded: return String(localized: "Rounded")
        case .mono: return String(localized: "Mono")
        }
    }

    static func clock(_ seconds: Double) -> String {
        let whole = max(Int(seconds.rounded()), 0)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// The length of the clip and how to change the lines.
    static func linesHint(duration: Double, timed: Bool) -> String {
        let length = clock(duration)
        if timed {
            return String(localized: "\(length) clip · Tap lines to choose up to 30 seconds.")
        }
        return String(localized: "\(length) clip · Tap lines to choose up to 6.")
    }

    static func startsAt(_ seconds: Double) -> String {
        String(localized: "Music starts at \(clock(seconds))")
    }

    static func audioFailure(_ failure: LyricShareAudioFailure, song: String) -> String {
        switch failure {
        case .unreadable(let reason):
            return String(localized: "Couldn't read the audio of “\(song)” (\(reason)). You can still share an image.")
        case .outOfRange:
            return String(localized: "Couldn't read the audio of “\(song)” — the chosen lines lie past the end of the file. Pick earlier lines.")
        case .notDownloaded:
            return String(localized: "Couldn't download “\(song)” from your server. Check the connection and try again, or share an image.")
        }
    }

    static func exportFailure(_ failure: LyricShareExportFailure) -> String {
        switch failure {
        case .cancelled:
            return String(localized: "Stopped making the video.")
        case .writer(let reason):
            return String(localized: "Couldn't make the video (\(reason)). Try again, or share an image instead.")
        case .image:
            return String(localized: "Couldn't make the image. Check free space and try again.")
        }
    }
}
