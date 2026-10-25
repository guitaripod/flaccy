import AuthenticationServices
import MidgarCore
import FlaccyCore
import StoreKit
import MidgarPortal
import UIKit

extension SettingsViewController {

    func makeSpinnerAccessory() -> UIActivityIndicatorView {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        return spinner
    }

    func makeHideDuplicatesSwitch() -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = HideDuplicateSongsSetting.isEnabled
        toggle.accessibilityLabel = String(localized: "Hide Duplicate Songs")
        toggle.addAction(UIAction { [weak self] action in
            guard let toggle = action.sender as? UISwitch else { return }
            self?.selectionFeedback.selectionChanged()
            HideDuplicateSongsSetting.set(toggle.isOn)
        }, for: .valueChanged)
        return toggle
    }

    func makeGroupEditionsSwitch() -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = GroupAlbumEditionsSetting.isEnabled
        toggle.accessibilityLabel = String(localized: "Group Album Editions")
        toggle.addAction(UIAction { [weak self] action in
            guard let toggle = action.sender as? UISwitch else { return }
            self?.selectionFeedback.selectionChanged()
            GroupAlbumEditionsSetting.set(toggle.isOn)
        }, for: .valueChanged)
        return toggle
    }

    /// Turning it on asks Apple Music for permission exactly once. A refusal
    /// snaps the switch back rather than leaving a setting on that the system
    /// will silently ignore.
    func makeAppleMusicArtworkSwitch(isEnabled: Bool) -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = isEnabled
        toggle.accessibilityLabel = String(localized: "Use Apple Music artwork")
        toggle.addAction(UIAction { [weak self] action in
            guard let toggle = action.sender as? UISwitch else { return }
            self?.selectionFeedback.selectionChanged()
            self?.setAppleMusicArtwork(enabled: toggle.isOn, toggle: toggle)
        }, for: .valueChanged)
        return toggle
    }

    func setAppleMusicArtwork(enabled: Bool, toggle: UISwitch) {
        guard enabled else {
            AppleMusicArtworkSetting.set(false)
            return
        }
        toggle.isEnabled = false
        Task { [weak self] in
            let granted = await MusicKitService.shared.enableArtworkSource()
            toggle.isEnabled = true
            toggle.setOn(granted, animated: true)
            guard let self else { return }
            if granted {
                await EnrichmentCoordinator.shared.resume()
            } else {
                self.notificationFeedback.notificationOccurred(.warning)
                MidgarLog.info("Apple Music artwork declined", category: .content)
            }
            self.applySnapshot(animated: false)
        }
    }

    /// Turning reminders on asks the system once; a refusal snaps the switch
    /// back and points at the one place that can change the answer.
    func makeTrialRemindersSwitch(isEnabled: Bool) -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = isEnabled
        toggle.accessibilityLabel = String(localized: "Trial reminders")
        toggle.addAction(UIAction { [weak self] action in
            guard let toggle = action.sender as? UISwitch else { return }
            self?.selectionFeedback.selectionChanged()
            self?.setTrialReminders(enabled: toggle.isOn, toggle: toggle)
        }, for: .valueChanged)
        return toggle
    }

    func setTrialReminders(enabled: Bool, toggle: UISwitch) {
        let scheduler = TrialReminderScheduler.shared
        scheduler.markAsked()
        guard enabled else {
            scheduler.disable()
            refreshTrialSectionVisibility()
            return
        }
        toggle.isEnabled = false
        Task { [weak self] in
            let granted = await scheduler.enable()
            toggle.isEnabled = true
            toggle.setOn(granted, animated: true)
            guard let self else { return }
            if !granted {
                self.notificationFeedback.notificationOccurred(.warning)
                ToastView.show(String(localized: "Turn on notifications for Flaccy in Settings"), in: self.view, style: .info)
            }
            self.refreshTrialSectionVisibility()
        }
    }

    func makeAutoplaySwitch() -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = AudioPlayer.shared.autoplaySimilarWhenQueueEnds
        toggle.accessibilityLabel = String(localized: "Autoplay Similar")
        toggle.accessibilityHint = String(localized: "Keeps a similar-music station going when the queue ends")
        toggle.addAction(UIAction { [weak self] action in
            guard let toggle = action.sender as? UISwitch else { return }
            self?.selectionFeedback.selectionChanged()
            AudioPlayer.shared.autoplaySimilarWhenQueueEnds = toggle.isOn
        }, for: .valueChanged)
        return toggle
    }

    func makeVersionFooter() -> UIView {
        let info = Bundle.main.infoDictionary
        let name = info?["CFBundleDisplayName"] as? String
            ?? info?["CFBundleName"] as? String
            ?? "flaccy"
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"

        let nameLabel = UILabel()
        nameLabel.text = name
        nameLabel.font = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .systemFont(ofSize: 13, weight: .semibold))
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .secondaryLabel
        nameLabel.textAlignment = .center

        let versionLabel = UILabel()
        versionLabel.text = String(localized: "Version \(version) (\(build))")
        versionLabel.font = .preferredFont(forTextStyle: .footnote)
        versionLabel.adjustsFontForContentSizeCategory = true
        versionLabel.textColor = .tertiaryLabel
        versionLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [nameLabel, versionLabel])
        stack.axis = .vertical
        stack.spacing = 2
        stack.alignment = .center
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 20, left: 16, bottom: 24, right: 16)
        stack.isAccessibilityElement = true
        stack.accessibilityLabel = String(localized: "\(name), version \(version), build \(build)")

        let width = view.bounds.width
        let size = stack.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        stack.frame = CGRect(origin: .zero, size: CGSize(width: width, height: size.height))
        return stack
    }

    func lastFMFooter() -> String {
        if LastFMService.shared.isAuthenticated {
            return String(localized: "Flaccy and Last.fm share one listening history. Every scrobble on your account, from Flaccy or any other app or device, flows into Stats, play counts and Most Played, and keeps flowing on its own.")
        }
        return String(localized: "Optional. Connect a Last.fm account to scrobble your listens, sync loved tracks, and bring your whole listening history into Stats and play counts. Everything else works without it.")
    }
}
