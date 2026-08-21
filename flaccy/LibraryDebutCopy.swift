import FlaccyCore
import Foundation

/// The words of the once-per-library Debut: the second act's two headlines, the
/// summary card that closes it, and the two lines Settings keeps forever after.
/// Act I borrows `LibraryLoadPhaseCopy`, because the phases it narrates are the
/// same phases every rescan narrates.
nonisolated enum LibraryDebutCopy {

    /// Act II names the source it is waiting on rather than the phase it is in,
    /// because by then the library is already browsable and the reader is being
    /// told what is still improving, not what is still blocking.
    static func headline(for scope: EnrichmentScope) -> String {
        switch scope {
        case .aiBatch: return String(localized: "Cleaning up your tags")
        case .album, .artist: return String(localized: "Finding your covers")
        }
    }

    static func explanation(for scope: EnrichmentScope) -> String {
        switch scope {
        case .aiBatch:
            return String(localized: "Flaccy's AI turns scrambled filenames into real titles, artists and albums.")
        case .album, .artist:
            return String(localized: "Looking up artwork, years and genres for every album.")
        }
    }

    static var trialChip: String {
        String(localized: "AI · included in your 7-day trial")
    }

    static var aiSkippedHeadline: String {
        String(localized: "Tag cleanup skipped — your trial has ended")
    }

    static var aiSkippedAction: String {
        String(localized: "Turn on AI cleanup")
    }

    static var cardTitle: String {
        String(localized: "Your library is ready.")
    }

    enum Stat {
        case tracks, albums, artists, duration
    }

    static func statLabel(_ stat: Stat) -> String {
        switch stat {
        case .tracks: return String(localized: "Tracks")
        case .albums: return String(localized: "Albums")
        case .artists: return String(localized: "Artists")
        case .duration: return String(localized: "Of music")
        }
    }

    static func coversLine(coversResolved: Int, albumsDated: Int) -> String {
        let covers = LibraryLoadPhaseCopy.number(coversResolved)
        let dated = LibraryLoadPhaseCopy.number(albumsDated)
        return String(localized: "\(covers) covers found · \(dated) albums dated")
    }

    static func aiLine(cleanedTracks: Int) -> String {
        let cleaned = LibraryLoadPhaseCopy.number(cleanedTracks)
        return String(localized: "\(cleaned) tracks cleaned up by Flaccy AI")
    }

    static func qualityLine(losslessPercent: Int, averageBitrate: Int) -> String {
        let share = LibraryLoadPhaseCopy.number(losslessPercent)
        let bitrate = LibraryLoadPhaseCopy.number(averageBitrate)
        return String(localized: "\(share)% lossless · \(bitrate) kbps average")
    }

    static var paywallLine: String {
        String(localized: "Tag cleanup is powered by Flaccy AI — included in Flaccy Lifetime.")
    }

    static var primaryAction: String {
        String(localized: "Take me to my music")
    }

    static var secondaryAction: String {
        String(localized: "See what's included")
    }

    static func settingsSummary(builtOn: Date, trackCount: Int, aiCleanedTracks: Int) -> String {
        let day = LibraryLoadPhaseCopy.day(builtOn)
        let tracks = LibraryLoadPhaseCopy.number(trackCount)
        let cleaned = LibraryLoadPhaseCopy.number(aiCleanedTracks)
        return String(localized: "Library built \(day) · \(tracks) tracks · \(cleaned) cleaned up by AI")
    }

    /// The Debut is gated on one row in this library's database, so a reinstall
    /// or a reset earns it again. The footer says so rather than letting the
    /// summary look like a claim about the person.
    static var settingsCaveat: String {
        String(localized: "The setup summary belongs to this library. Reinstalling or resetting builds a new one.")
    }

    static var watchCardTitle: String {
        String(localized: "Ready.")
    }

    static func watchCardDetail(trackCount: Int, albumCount: Int) -> String {
        let tracks = LibraryLoadPhaseCopy.number(trackCount)
        let albums = LibraryLoadPhaseCopy.number(albumCount)
        return String(localized: "\(tracks) tracks · \(albums) albums on your wrist")
    }
}
