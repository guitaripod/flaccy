import AuthenticationServices
import MidgarCore
import FlaccyCore
import StoreKit
import MidgarPortal
import UIKit

extension SettingsViewController {

    nonisolated enum Section: Int, CaseIterable, Hashable {
        case midgar
        case appearance
        case trial
        case lastFM
        case recap
        case playback
        case guide
        case watch
        case servers
        case serverCache
        case library
        case setup
        case about

        var header: String? {
            switch self {
            case .midgar: return nil
            case .appearance: return String(localized: "Appearance")
            case .trial: return String(localized: "Trial")
            case .lastFM: return "Last.fm"
            case .recap: return String(localized: "Year in Music")
            case .playback: return String(localized: "Playback")
            case .guide: return nil
            case .watch: return String(localized: "Apple Watch")
            case .servers: return String(localized: "Servers")
            case .serverCache: return String(localized: "Server Cache")
            case .library: return String(localized: "Library")
            case .setup: return nil
            case .about: return String(localized: "About")
            }
        }

        var footer: String? {
            switch self {
            case .midgar: return nil
            case .appearance: return String(localized: "System follows your device's light and dark setting.")
            case .trial: return String(localized: "Three reminders at most: two days before your trial ends, on the last day, and once if a welcome-back price becomes available.")
            case .lastFM: return nil
            case .recap: return String(localized: "Recap notifications are generated on this device from your local play history, with a shareable Year in Music story.")
            case .playback: return Self.playbackFooter
            case .guide: return String(localized: "How Bluetooth, AAC, and lossless files really affect what you hear.")
            case .watch: return nil
            case .servers: return nil
            case .serverCache: return RemoteCopy.cacheFooter
            case .library: return Self.libraryFooter
            case .setup: return LibraryDebutCopy.settingsCaveat
            case .about: return nil
            }
        }

        /// Names the one format caveat listeners actually hear, so a lossy album
        /// that clicks between tracks reads as the file's doing rather than the
        /// app quietly failing at the thing it advertises.
        private static var playbackFooter: String {
            let gapless = String(localized: "Gapless is always on. Consecutive album tracks play with no silence between them — no setting to turn on, nothing to configure.")
            let formats = String(localized: "It is exact for lossless files: FLAC, ALAC, WAV, AIFF. MP3 and AAC store a fraction of a second of encoder padding inside every file, which iOS does not strip, so those albums can still click between tracks. Re-rip the album to FLAC and the seam disappears.")
            let autoplay = String(localized: "Autoplay keeps a similar-music station going when the queue ends.")
            return "\(gapless)\n\n\(formats)\n\n\(autoplay)"
        }

        /// One sentence per switch in the section, in the order the switches
        /// appear.
        private static var libraryFooter: String {
            let editions = String(localized: "Group editions folds Deluxe, Remaster, and Explicit variants into one album and keeps a single best copy of each song.")
            let duplicates = String(localized: "Hide duplicate songs lists a song once when it sits on several albums, such as a single and the album it came from. Press and hold a song to see every copy.")
            let appleMusic = String(localized: "Flaccy asks Apple Music for covers it can't find anywhere else. Turning this on asks for permission once.")
            return "\(editions)\n\n\(duplicates)\n\n\(appleMusic)"
        }
    }

    nonisolated enum Row: Hashable {
        case appearance(AppAppearance)
        case trialReminders(enabled: Bool)
        case lastFMAccount(username: String?)
        case pendingScrobbles(count: Int)
        case historySync
        case yearInMusic
        case recapNotifications(frequency: String)
        case equalizer(summary: String)
        case gaplessPlayback
        case autoplaySimilar
        case libraryRadio
        case crateDig
        case listeningGuide
        case watchSync(syncedCount: Int, profile: WatchAudioProfile)
        case serversExplainer
        case server(RemoteServerRow)
        case addServer
        case cacheLimit
        case cacheUsage(String)
        case clearCache
        case importFiles
        case rescanLibrary
        case groupAlbumEditions
        case hideDuplicateSongs
        case metadataReport(complete: Int, gaveUp: Int)
        case findMissingArtwork(count: Int)
        case appleMusicArtwork(Bool)
        case libraryStats(albums: Int, tracks: Int)
        case storage(used: String)
        case libraryDebutSummary
        case midgarEntry
        case privacyPolicy
        case termsOfUse
    }

    /// Renders an Apple-Settings-style icon: a white SF Symbol glyph centered
    /// on a tinted continuous-corner rounded square.
    enum RowIcon {
        static let side: CGFloat = 29

        static func image(systemName: String, tint: UIColor) -> UIImage {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
            return renderer.image { _ in
                let rect = CGRect(x: 0, y: 0, width: side, height: side)
                let path = UIBezierPath(roundedRect: rect, cornerRadius: 6.5)
                tint.setFill()
                path.fill()
                let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
                guard let glyph = UIImage(systemName: systemName, withConfiguration: config)?
                    .withTintColor(.white, renderingMode: .alwaysOriginal) else { return }
                let glyphRect = CGRect(
                    x: (side - glyph.size.width) / 2,
                    y: (side - glyph.size.height) / 2,
                    width: glyph.size.width,
                    height: glyph.size.height
                )
                glyph.draw(in: glyphRect)
            }
        }
    }

    final class DataSource: UITableViewDiffableDataSource<Section, Row> {
        var footerForSection: ((Section) -> String?)?

        override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
            sectionIdentifier(for: section)?.header
        }

        override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
            guard let section = sectionIdentifier(for: section) else { return nil }
            return footerForSection?(section) ?? section.footer
        }
    }
}
