import AuthenticationServices
import MidgarCore
import FlaccyCore
import StoreKit
import MidgarPortal
import UIKit

extension SettingsViewController {

    /// A screen of Settings. The root lists every other page as a row with its icon, the way
    /// the system Settings app does; each page holds the switches and actions of one subject.
    nonisolated enum Page: Hashable, CaseIterable {
        case root
        case plan
        case appearance
        case notifications
        case playback
        case library
        case servers
        case lastFM
        case about

        var title: String {
            switch self {
            case .root: String(localized: "Settings")
            case .plan: String(localized: "Flaccy Pro")
            case .appearance: String(localized: "Appearance")
            case .notifications: String(localized: "Notifications")
            case .playback: String(localized: "Playback")
            case .library: String(localized: "Library")
            case .servers: String(localized: "Servers")
            case .lastFM: "Last.fm"
            case .about: String(localized: "About")
            }
        }

        var symbolName: String {
            switch self {
            case .root, .plan: "sparkles"
            case .appearance: "circle.lefthalf.filled"
            case .notifications: "bell.badge.fill"
            case .playback: "play.fill"
            case .library: "music.note.house.fill"
            case .servers: "server.rack"
            case .lastFM: "dot.radiowaves.left.and.right"
            case .about: "info"
            }
        }

        var tint: UIColor {
            switch self {
            case .root, .plan: .systemPurple
            case .appearance: .systemBlue
            case .notifications: .systemRed
            case .playback: .systemPurple
            case .library: .systemOrange
            case .servers: .systemTeal
            case .lastFM: .systemRed
            case .about: .systemGray
            }
        }

        var accessibilityIdentifier: String { "settings.page.\(self)" }
    }

    nonisolated enum Section: Int, CaseIterable, Hashable {
        case rootPlan
        case rootGeneral
        case rootListening
        case rootLibrary
        case rootServices
        case rootSupport
        case midgar
        case appearance
        case trial
        case recap
        case playback
        case stations
        case lastFM
        case servers
        case serverCache
        case libraryAdd
        case libraryOrganize
        case libraryDetails
        case libraryOverview
        case aboutVersion
        case aboutLegal

        var page: Page {
            switch self {
            case .rootPlan, .rootGeneral, .rootListening, .rootLibrary, .rootServices, .rootSupport, .midgar: .root
            case .appearance: .appearance
            case .trial, .recap: .notifications
            case .playback, .stations: .playback
            case .lastFM: .lastFM
            case .servers, .serverCache: .servers
            case .libraryAdd, .libraryOrganize, .libraryDetails, .libraryOverview: .library
            case .aboutVersion, .aboutLegal: .about
            }
        }

        var header: String? {
            switch self {
            case .trial: String(localized: "Trial")
            case .recap: String(localized: "Year in Music")
            case .stations: String(localized: "Stations")
            case .serverCache: String(localized: "Server Cache")
            case .libraryAdd: String(localized: "Music")
            case .libraryOrganize: String(localized: "Organize")
            case .libraryDetails: String(localized: "Artwork and Details")
            case .libraryOverview: String(localized: "Overview")
            case .midgar: String(localized: "More from Midgar")
            default: nil
            }
        }

        var footer: String? {
            switch self {
            case .trial: String(localized: "Two reminders before your trial ends, and one if an offer opens.")
            case .playback: String(localized: "Gapless is exact on lossless files. MP3 and AAC files can keep tiny encoder gaps.")
            case .servers: String(localized: "Stream from Flaccy Server, Navidrome or another Subsonic server.")
            case .serverCache: RemoteCopy.cacheFooter
            default: nil
            }
        }
    }

    /// What the plan row at the top of Settings says: the plan, or the trial and its days.
    nonisolated struct PlanSummary: Hashable {
        let title: String
        let subtitle: String
    }

    nonisolated enum Row: Hashable {
        case plan(PlanSummary)
        case page(Page, value: String?)
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
        case version(String)
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
