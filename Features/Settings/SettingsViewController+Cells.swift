import AuthenticationServices
import MidgarCore
import FlaccyCore
import StoreKit
import MidgarPortal
import UIKit

extension SettingsViewController {

    func cell(for row: Row, at indexPath: IndexPath, in tableView: UITableView) -> UITableViewCell {
        if case .appearance(let current) = row {
            return appearanceCell(current: current, in: tableView, at: indexPath)
        }
        if case .accent(let current) = row {
            return accentCell(current: current, in: tableView, at: indexPath)
        }
        if case .midgarEntry = row {
            return tableView.dequeueReusableCell(withIdentifier: MidgarEntryCell.reuseID, for: indexPath)
        }
        if case .signalPath(let path) = row,
           let cell = tableView.dequeueReusableCell(withIdentifier: SignalPathCell.reuseID, for: indexPath) as? SignalPathCell {
            cell.configure(path)
            return cell
        }
        if case .libraryOverview(let overview) = row,
           let cell = tableView.dequeueReusableCell(withIdentifier: LibraryOverviewCell.reuseID, for: indexPath) as? LibraryOverviewCell {
            cell.configure(overview)
            return cell
        }
        if case .plan(let summary) = row,
           let cell = tableView.dequeueReusableCell(withIdentifier: SettingsPlanCell.reuseID, for: indexPath) as? SettingsPlanCell {
            cell.configure(summary)
            return cell
        }

        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellReuseIdentifier, for: indexPath)
        cell.accessoryType = .none
        cell.accessoryView = nil
        cell.selectionStyle = .default
        cell.accessibilityTraits = .button
        cell.accessibilityValue = nil
        cell.accessibilityHint = nil
        cell.accessibilityIdentifier = nil

        var content = Self.baseContent(for: row)

        switch row {
        case .appearance, .accent, .midgarEntry, .plan, .signalPath, .libraryOverview:
            break

        case .guideCard(_, let title, let symbolName):
            content.image = RowIcon.image(systemName: symbolName, tint: .systemCyan)
            content.text = title
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityLabel = title
            cell.accessibilityHint = String(localized: "Opens this card of the Listening Guide")

        case .listeningGuide:
            content.image = RowIcon.image(systemName: "book.fill", tint: .systemCyan)
            content.text = String(localized: "Listening Guide")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityLabel = String(localized: "Listening Guide")
            cell.accessibilityIdentifier = "settings.row.listeningGuide"

        case .songVolumes(let count):
            content.image = RowIcon.image(systemName: "speaker.wave.2.fill", tint: .systemOrange)
            content.text = String(localized: "Song Volumes")
            content.secondaryText = count == 0 ? String(localized: "None") : count.formatted()
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityLabel = String(localized: "Song Volumes")
            cell.accessibilityValue = content.secondaryText
            cell.accessibilityIdentifier = "settings.row.songVolumes"

        case .homeScreen(let visibleSections):
            content.image = RowIcon.image(systemName: "house.fill", tint: .systemOrange)
            content.text = String(localized: "Home Screen")
            content.secondaryText = String(localized: "\(visibleSections) sections")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityLabel = String(localized: "Home Screen")
            cell.accessibilityValue = content.secondaryText
            cell.accessibilityIdentifier = "settings.row.homeScreen"

        case .playerButtons(let isCustom):
            content.image = RowIcon.image(systemName: "circle.grid.3x3.fill", tint: .systemPink)
            content.text = String(localized: "Player Buttons")
            content.secondaryText = isCustom ? String(localized: "Reset") : String(localized: "Original Order")
            if isCustom {
                content.secondaryTextProperties.color = .tintColor
            } else {
                cell.selectionStyle = .none
            }
            cell.accessibilityLabel = String(localized: "Player Buttons")
            cell.accessibilityValue = isCustom ? String(localized: "Custom order") : String(localized: "Original Order")
            cell.accessibilityHint = isCustom ? String(localized: "Puts the buttons under Now Playing back in their original order") : nil

        case .scrobbled(let count):
            content.image = RowIcon.image(systemName: "chart.bar.fill", tint: .systemRed)
            content.text = String(localized: "Plays")
            content.secondaryText = count.formatted()
            cell.selectionStyle = .none
            cell.accessibilityTraits = .staticText
            cell.accessibilityLabel = String(localized: "Plays")
            cell.accessibilityValue = content.secondaryText

        case .page(let page, let value):
            content.image = RowIcon.image(systemName: page.symbolName, tint: page.tint)
            content.text = page.title
            content.secondaryText = value
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityLabel = page.title
            cell.accessibilityValue = value
            cell.accessibilityIdentifier = page.accessibilityIdentifier

        case .version(let version):
            content.text = String(localized: "Version")
            content.secondaryText = version
            cell.selectionStyle = .none
            cell.accessibilityTraits = .staticText
            cell.accessibilityLabel = String(localized: "Version")
            cell.accessibilityValue = version

        case .privacyPolicy:
            content.image = RowIcon.image(systemName: "hand.raised.fill", tint: .systemBlue)
            content.text = String(localized: "Privacy Policy")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityLabel = String(localized: "Privacy Policy")

        case .termsOfUse:
            content.image = RowIcon.image(systemName: "doc.text.fill", tint: .systemGray)
            content.text = String(localized: "Terms of Use")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityLabel = String(localized: "Terms of Use")

        case .support:
            content.image = RowIcon.image(systemName: "envelope.fill", tint: .systemGreen)
            content.text = String(localized: "Contact Support")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityLabel = String(localized: "Contact Support")
            cell.accessibilityValue = MidgarSupport.address

        case .trialReminders(let enabled):
            content.image = RowIcon.image(systemName: "bell.badge.fill", tint: .systemOrange)
            content.text = String(localized: "Trial reminders")
            cell.selectionStyle = .none
            cell.accessoryView = makeTrialRemindersSwitch(isEnabled: enabled)
            cell.accessibilityTraits = []
            cell.accessibilityLabel = String(localized: "Trial reminders")
            cell.accessibilityIdentifier = "settings.row.trialReminders"

        case .lastFMAccount(let username):
            content.image = RowIcon.image(systemName: "dot.radiowaves.left.and.right", tint: .systemRed)
            if let username {
                content.text = String(localized: "Last.fm Account")
                content.secondaryText = username
                cell.accessoryType = .disclosureIndicator
                cell.accessibilityHint = String(localized: "Shows account options")
            } else {
                content.text = String(localized: "Connect to Last.fm")
                cell.accessoryType = .disclosureIndicator
                cell.accessibilityHint = String(localized: "Signs in to Last.fm to scrobble your listens")
            }
            cell.accessibilityLabel = content.text
            cell.accessibilityValue = content.secondaryText

        case .pendingScrobbles(let count):
            content.image = RowIcon.image(systemName: "clock.arrow.circlepath", tint: .systemOrange)
            content.text = String(localized: "Retry Pending Scrobbles")
            content.secondaryText = "\(count)"
            content.textProperties.color = .tintColor
            cell.accessibilityLabel = String(localized: "Retry pending scrobbles")
            cell.accessibilityValue = String(localized: "\(count) pending scrobbles")

        case .historySync:
            let status = ListenHistorySync.shared.status
            content.image = RowIcon.image(systemName: "arrow.triangle.2.circlepath", tint: .systemPink)
            content.text = String(localized: "History Sync")
            content.secondaryText = status.summary
            cell.accessibilityLabel = String(localized: "History Sync")
            cell.accessibilityValue = status.summary
            if status.isBusy {
                cell.accessoryView = makeSpinnerAccessory()
                cell.selectionStyle = .none
            } else {
                cell.accessibilityHint = String(localized: "Syncs your Last.fm listening history now")
            }

        case .yearInMusic:
            content.image = RowIcon.image(systemName: "sparkles", tint: .systemIndigo)
            content.text = String(localized: "Year in Music")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityLabel = String(localized: "Year in Music")
            cell.accessibilityHint = String(localized: "Shows your yearly listening recap with shareable story cards")
            cell.accessibilityIdentifier = "settings.row.yearInMusic"

        case .recapNotifications(let frequency):
            content.image = RowIcon.image(systemName: "bell.badge.fill", tint: .systemRed)
            content.text = String(localized: "Recap Notifications")
            content.secondaryText = frequency
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityLabel = String(localized: "Recap Notifications")
            cell.accessibilityValue = frequency
            cell.accessibilityHint = String(localized: "Chooses how often flaccy reminds you about your recap")

        case .equalizer(let summary):
            content.image = RowIcon.image(systemName: "slider.vertical.3", tint: .systemPink)
            content.text = EqualizerCopy.title
            content.secondaryText = summary
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityLabel = EqualizerCopy.title
            cell.accessibilityValue = summary
            cell.accessibilityHint = String(localized: "Shapes the sound with a response curve and presets")
            cell.accessibilityIdentifier = "settings.row.equalizer"

        case .gaplessPlayback:
            content.image = RowIcon.image(systemName: "infinity", tint: .systemPurple)
            content.text = String(localized: "Gapless Playback")
            content.secondaryText = String(localized: "Always on")
            cell.selectionStyle = .none
            cell.accessibilityLabel = String(localized: "Gapless Playback")
            cell.accessibilityValue = String(localized: "Always on")
            cell.accessibilityTraits = []

        case .autoplaySimilar:
            content.image = RowIcon.image(systemName: "infinity.circle", tint: .systemPink)
            content.text = String(localized: "Autoplay Similar")
            cell.selectionStyle = .none
            cell.accessoryView = makeAutoplaySwitch()
            cell.accessibilityTraits = []

        case .libraryRadio:
            content.image = RowIcon.image(systemName: "dot.radiowaves.left.and.right", tint: .systemOrange)
            content.text = String(localized: "Library Radio")
            content.textProperties.color = .tintColor
            cell.accessibilityLabel = String(localized: "Library Radio")
            cell.accessibilityHint = String(localized: "Plays a station from your most-played tracks")

        case .crateDig:
            content.image = RowIcon.image(systemName: "opticaldisc.fill", tint: .systemIndigo)
            content.text = String(localized: "Crate Dig")
            content.textProperties.color = .tintColor
            cell.accessibilityLabel = String(localized: "Crate Dig")
            cell.accessibilityHint = String(localized: "Plays deep cuts from albums you already love")

        case .watchSync(let syncedCount, let profile):
            content.image = RowIcon.image(systemName: "applewatch", tint: .systemGray)
            content.text = String(localized: "Apple Watch")
            content.secondaryText = syncedCount > 0 ? "\(syncedCount) · \(profile.displayName)" : profile.displayName
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityLabel = String(localized: "Apple Watch")
            cell.accessibilityIdentifier = "settings.row.watch"
            let spoken = [syncedCount > 0 ? String(localized: "\(syncedCount) tracks synced") : nil, profile.displayName]
            cell.accessibilityValue = spoken.compactMap { $0 }.joined(separator: ", ")

        case .importFiles:
            content.image = RowIcon.image(systemName: "square.and.arrow.down", tint: .systemGreen)
            content.text = String(localized: "Import Files")
            content.textProperties.color = .tintColor
            cell.accessibilityLabel = String(localized: "Import Files")
            cell.accessibilityHint = String(localized: "Opens the file browser to add music")

        case .rescanLibrary:
            content.image = RowIcon.image(systemName: "arrow.clockwise", tint: .systemIndigo)
            if isRescanning {
                content.text = String(localized: "Rescanning Library")
                content.textProperties.color = .secondaryLabel
                cell.accessoryView = makeSpinnerAccessory()
                cell.selectionStyle = .none
                cell.accessibilityLabel = String(localized: "Rescanning Library")
            } else {
                content.text = String(localized: "Rescan Library")
                content.textProperties.color = .tintColor
                cell.accessibilityLabel = String(localized: "Rescan Library")
                cell.accessibilityHint = String(localized: "Re-analyzes all tracks")
            }

        case .groupAlbumEditions:
            content.image = RowIcon.image(systemName: "square.stack.3d.up", tint: .systemPurple)
            content.text = String(localized: "Group Album Editions")
            cell.selectionStyle = .none
            cell.accessibilityTraits = .none
            cell.accessoryView = makeGroupEditionsSwitch()
            cell.accessibilityLabel = String(localized: "Group Album Editions")
            cell.accessibilityHint = String(localized: "Folds deluxe, remaster, and explicit variants into one album")

        case .hideDuplicateSongs:
            content.image = RowIcon.image(systemName: "square.on.square", tint: .systemTeal)
            content.text = String(localized: "Hide Duplicate Songs")
            cell.selectionStyle = .none
            cell.accessibilityTraits = .none
            cell.accessoryView = makeHideDuplicatesSwitch()
            cell.accessibilityLabel = String(localized: "Hide Duplicate Songs")
            cell.accessibilityHint = String(localized: "Lists one copy of a song that appears on several albums")

        case .metadataReport(let complete, let gaveUp):
            content.image = RowIcon.image(systemName: "tag.fill", tint: .systemBlue)
            content.text = String(localized: "Metadata")
            content.secondaryText = EnrichmentJobCopy.reportCounts(
                complete: complete, inProgress: metadataViewModel.counts.inProgress, gaveUp: gaveUp
            )
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityLabel = String(localized: "Metadata")
            cell.accessibilityValue = content.secondaryText
            cell.accessibilityIdentifier = "settings.row.metadata"

        case .findMissingArtwork(let count):
            content.image = RowIcon.image(systemName: "photo.on.rectangle.angled", tint: .systemPink)
            content.text = EnrichmentJobCopy.findMissingArtwork
            content.secondaryText = EnrichmentJobCopy.detail(remaining: count)
            content.textProperties.color = .tintColor
            cell.accessibilityLabel = EnrichmentJobCopy.findMissingArtwork
            cell.accessibilityValue = content.secondaryText

        case .appleMusicArtwork(let isEnabled):
            content.image = RowIcon.image(systemName: "music.note", tint: .systemRed)
            content.text = String(localized: "Use Apple Music artwork")
            cell.selectionStyle = .none
            cell.accessibilityTraits = []
            cell.accessoryView = makeAppleMusicArtworkSwitch(isEnabled: isEnabled)
            cell.accessibilityLabel = String(localized: "Use Apple Music artwork")

        case .libraryDebutSummary:
            content.image = RowIcon.image(systemName: "checkmark.seal.fill", tint: .systemGreen)
            content.text = LibraryDebutCopy.cardTitle
            content.secondaryText = libraryDebut.map {
                LibraryDebutCopy.settingsSummary(
                    builtOn: $0.completedAt, trackCount: $0.trackCount, aiCleanedTracks: $0.aiCleanedTracks
                )
            }
            cell.selectionStyle = .none
            cell.accessibilityTraits = .staticText
            cell.accessibilityLabel = LibraryDebutCopy.cardTitle
            cell.accessibilityValue = content.secondaryText

        case .libraryStats(let albums, let tracks):
            content.image = RowIcon.image(systemName: "chart.bar.fill", tint: .systemTeal)
            content.text = String(localized: "Library")
            content.secondaryText = String(localized: "\(albums) albums, \(tracks) tracks")
            cell.selectionStyle = .none
            cell.accessibilityTraits = .staticText
            cell.accessibilityLabel = String(localized: "Library")
            cell.accessibilityValue = content.secondaryText

        case .server, .addFlaccyServer, .addServer, .cacheLimit, .cacheUsage, .clearCache:
            configureServerRow(row, cell: cell, content: &content)

        case .storage(let used):
            content.image = RowIcon.image(systemName: "internaldrive.fill", tint: .systemGray)
            content.text = String(localized: "Storage Used")
            content.secondaryText = used
            cell.selectionStyle = .none
            cell.accessibilityTraits = .staticText
            cell.accessibilityLabel = String(localized: "Storage Used")
            cell.accessibilityValue = used
        }

        cell.contentConfiguration = content
        return cell
    }

    /// Rows whose secondary text is a sentence rather than a value get the
    /// subtitle layout, because a trailing value cell truncates the counts to
    /// nothing on a phone.
    static func baseContent(for row: Row) -> UIListContentConfiguration {
        var content: UIListContentConfiguration
        switch row {
        case .metadataReport, .libraryDebutSummary, .server:
            content = .subtitleCell()
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
            content.secondaryTextProperties.numberOfLines = 0
        default:
            content = .valueCell()
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .body)
        }
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.color = .secondaryLabel
        content.imageProperties.maximumSize = CGSize(width: RowIcon.side, height: RowIcon.side)
        return content
    }

    func appearanceCell(current: AppAppearance, in tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: AppearanceCell.reuseID, for: indexPath) as! AppearanceCell
        cell.configure(selected: current)
        cell.onChange = { [weak self] appearance in
            guard let self else { return }
            self.selectionFeedback.selectionChanged()
            AppAppearance.current = appearance
            AppearanceApplier.apply(appearance, animated: true)
            MidgarLog.info("Appearance set to \(appearance.displayName)", category: .ui)
        }
        return cell
    }

    func accentCell(current: AccentChoice, in tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: AccentCell.reuseID, for: indexPath) as! AccentCell
        cell.configure(selected: current)
        cell.onChange = { [weak self] accent in
            guard let self else { return }
            self.selectionFeedback.selectionChanged()
            AppAccent.current = accent
            AccentApplier.apply(accent, animated: true)
            MidgarLog.info("Accent set to \(accent.rawValue)", category: .ui)
        }
        return cell
    }
}
