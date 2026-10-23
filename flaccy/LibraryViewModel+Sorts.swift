import Combine
import MidgarCore
import FlaccyCore

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

extension LibraryViewModel {

    enum Segment: Int, CaseIterable {
        case albums
        case songs
        case artists
        case playlists
    }

    enum AlbumSort: String, CaseIterable {
        case title, artist, year, recentlyAdded, recentlyPlayed

        var displayName: String {
            switch self {
            case .title: String(localized: "Title")
            case .artist: String(localized: "Artist")
            case .year: String(localized: "Year")
            case .recentlyAdded: String(localized: "Recently Added")
            case .recentlyPlayed: String(localized: "Recently Played")
            }
        }

        var icon: String {
            switch self {
            case .title: "textformat.abc"
            case .artist: "person"
            case .year: "calendar"
            case .recentlyAdded: "clock.badge.plus"
            case .recentlyPlayed: "clock.arrow.circlepath"
            }
        }
    }

    enum SongSort: String, CaseIterable {
        case title, artist, mostScrobbled, recentlyPlayed, dateAdded

        var displayName: String {
            switch self {
            case .title: String(localized: "Title")
            case .artist: String(localized: "Artist")
            case .mostScrobbled: String(localized: "Most Played")
            case .recentlyPlayed: String(localized: "Recently Played")
            case .dateAdded: String(localized: "Date Added")
            }
        }

        var icon: String {
            switch self {
            case .title: "textformat.abc"
            case .artist: "person"
            case .mostScrobbled: "flame"
            case .recentlyPlayed: "clock"
            case .dateAdded: "calendar"
            }
        }
    }

    enum ArtistSort: String, CaseIterable {
        case name, albumCount, mostPlayed, recentlyPlayed

        var displayName: String {
            switch self {
            case .name: String(localized: "Name")
            case .albumCount: String(localized: "Album Count")
            case .mostPlayed: String(localized: "Most Played")
            case .recentlyPlayed: String(localized: "Recently Played")
            }
        }

        var icon: String {
            switch self {
            case .name: "textformat.abc"
            case .albumCount: "number"
            case .mostPlayed: "flame"
            case .recentlyPlayed: "clock.arrow.circlepath"
            }
        }
    }

    typealias Snapshot = NSDiffableDataSourceSnapshot<Int, LibraryItem>
}
