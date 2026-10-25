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
        if case .midgarEntry = row {
            return tableView.dequeueReusableCell(withIdentifier: MidgarEntryCell.reuseID, for: indexPath)
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
        case .appearance, .midgarEntry:
            break

        case .privacyPolicy:
            content.image = RowIcon.image(systemName: "hand.raised.fill", tint: .systemBlue)
            content.text = String(localized: "Privacy Policy")
            content.textProperties.color = .tintColor
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityLabel = String(localized: "Privacy Policy")

        case .termsOfUse:
            content.image = RowIcon.image(systemName: "doc.text.fill", tint: .systemGray)
            content.text = String(localized: "Terms of Use")
            content.textProperties.color = .tintColor
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityLabel = String(localized: "Terms of Use")

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

        case .importLastFM:
            content.image = RowIcon.image(systemName: "square.and.arrow.down.on.square", tint: .systemPink)
            if let imported = lastFMImportProgress {
                content.text = String(localized: "Importing Last.fm History")
                if imported > 0 { content.secondaryText = "\(imported)" }
                cell.accessoryView = makeSpinnerAccessory()
                cell.selectionStyle = .none
                cell.accessibilityLabel = String(localized: "Importing Last.fm History")
                if imported > 0 {
                    cell.accessibilityValue = String(localized: "\(imported) scrobbles imported")
                }
            } else {
                content.text = String(localized: "Import Last.fm History")
                content.textProperties.color = .tintColor
                cell.accessibilityLabel = String(localized: "Import Last.fm History")
                cell.accessibilityHint = String(localized: "Backfills your listening stats from Last.fm")
            }

        case .yearInMusic:
            content.image = RowIcon.image(systemName: "sparkles", tint: .systemIndigo)
            content.text = String(localized: "Your Year in Music")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityLabel = String(localized: "Your Year in Music")
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

        case .listeningGuide:
            content.image = RowIcon.image(systemName: "waveform", tint: .systemCyan)
            content.text = String(localized: "Listening Guide")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityLabel = String(localized: "Listening Guide")
            cell.accessibilityHint = String(localized: "Explains how Bluetooth, AAC, and lossless audio affect what you hear")
            cell.accessibilityIdentifier = "settings.row.listeningGuide"

        case .watchSync(let syncedCount, let profile):
            content.image = RowIcon.image(systemName: "applewatch", tint: .systemBlue)
            content.text = String(localized: "Sync Music to Watch")
            content.secondaryText = syncedCount > 0 ? "\(syncedCount) · \(profile.displayName)" : profile.displayName
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityLabel = String(localized: "Sync Music to Watch")
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

        case .serversExplainer, .server, .addServer, .cacheLimit, .cacheUsage, .clearCache:
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
}
