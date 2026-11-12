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
            case .trial: return String(localized: "Two reminders before your trial ends, and one if an offer opens.")
            case .lastFM: return nil
            case .playback: return String(localized: "Gapless is exact on lossless files. MP3 and AAC files can keep tiny encoder gaps.")
            case .servers: return String(localized: "Stream from Flaccy Server, Navidrome or another Subsonic server.")
            case .serverCache: return RemoteCopy.cacheFooter
            case .midgar, .appearance, .recap, .watch, .library, .setup, .about: return nil
            }
        }
    }

    nonisolated enum Row: Hashable {
        case appearance(AppAppearance)
        case accent(AccentChoice)
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
        case watchSync(syncedCount: Int, profile: WatchAudioProfile)
        case server(RemoteServerRow)
        case addFlaccyServer
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
        case support
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
