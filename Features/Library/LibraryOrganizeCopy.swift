import Foundation

/// The words of keeping the library tidy, shared by iPhone, iPad and the Mac.
nonisolated enum LibraryOrganizeCopy {

    static var cleanLibraryTitle: String {
        String(localized: "Clean Library")
    }

    static var cleanLibraryHint: String {
        String(localized: "Shows each song once and each album's editions as one album")
    }

    /// The Mac has no copies sheet, so its footer stops at what Clean Library keeps.
    static var cleanLibraryFooter: String {
        #if os(macOS)
        String(localized: "Each song shows once, wherever its copies live: in your library, on a server, or tagged with another artist on the same album. An album's editions show as one album. Nothing is deleted.")
        #else
        String(localized: "Each song shows once, wherever its copies live: in your library, on a server, or tagged with another artist on the same album. An album's editions show as one album. Nothing is deleted; touch and hold a song to see its other copies.")
        #endif
    }
}
