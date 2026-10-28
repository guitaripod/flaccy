import AVFoundation
import MidgarCore
import AVKit
import Combine
import UIKit

extension NowPlayingViewController {

    func setupTransport() {
        let skipConfig = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        let transportConfig = UIImage.SymbolConfiguration(pointSize: 30, weight: .bold)

        skipBackButton.setImage(UIImage(systemName: "gobackward.15", withConfiguration: skipConfig), for: .normal)
        skipBackButton.tintColor = .white.withAlphaComponent(0.85)
        skipBackButton.accessibilityLabel = String(localized: "Skip back 15 seconds")
        skipBackButton.addAction(UIAction { [weak self] _ in self?.skip(by: -15) }, for: .touchUpInside)

        previousButton.setImage(UIImage(systemName: "backward.fill", withConfiguration: transportConfig), for: .normal)
        previousButton.tintColor = .white
        previousButton.accessibilityLabel = String(localized: "Previous track")
        previousButton.addAction(UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self?.viewModel.previousTrack()
        }, for: .touchUpInside)

        playPauseIconView.image = UIImage(systemName: "play.fill", withConfiguration: Self.playIconConfig)
        playPauseIconView.tintColor = .white
        playPauseIconView.contentMode = .center
        playPauseIconView.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.addSubview(playPauseIconView)
        playPauseButton.accessibilityLabel = String(localized: "Play")
        playPauseButton.addAction(UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            self?.viewModel.togglePlayPause()
        }, for: .touchUpInside)

        nextButton.setImage(UIImage(systemName: "forward.fill", withConfiguration: transportConfig), for: .normal)
        nextButton.tintColor = .white
        nextButton.accessibilityLabel = String(localized: "Next track")
        nextButton.addAction(UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self?.viewModel.nextTrack()
        }, for: .touchUpInside)

        skipForwardButton.setImage(UIImage(systemName: "goforward.15", withConfiguration: skipConfig), for: .normal)
        skipForwardButton.tintColor = .white.withAlphaComponent(0.85)
        skipForwardButton.accessibilityLabel = String(localized: "Skip forward 15 seconds")
        skipForwardButton.addAction(UIAction { [weak self] _ in self?.skip(by: 15) }, for: .touchUpInside)

        NSLayoutConstraint.activate([
            playPauseButton.widthAnchor.constraint(equalToConstant: 72),
            playPauseButton.heightAnchor.constraint(equalToConstant: 72),
            playPauseIconView.centerXAnchor.constraint(equalTo: playPauseButton.centerXAnchor),
            playPauseIconView.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
        ])
    }

    func makeVolumeRow() -> UIStackView {
        let glyphConfig = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let minGlyph = UIImageView(image: UIImage(systemName: "speaker.fill", withConfiguration: glyphConfig))
        minGlyph.tintColor = .white.withAlphaComponent(0.5)
        minGlyph.setContentHuggingPriority(.required, for: .horizontal)
        volumeSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)

        configureEqualizerButton()
        let capsule = GlassCapsule(hosting: equalizerButton)
        capsule.widthAnchor.constraint(equalToConstant: 44).isActive = true
        capsule.setContentHuggingPriority(.required, for: .horizontal)
        equalizerCapsule = capsule

        let row = UIStackView(arrangedSubviews: [minGlyph, volumeSlider, capsule])
        row.spacing = 12
        row.alignment = .center
        return row
    }

    func configureEqualizerButton() {
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        equalizerButton.setImage(UIImage(systemName: "slider.vertical.3", withConfiguration: iconConfig), for: .normal)
        equalizerButton.accessibilityLabel = EqualizerCopy.title
        equalizerButton.accessibilityIdentifier = "nowplaying.equalizer"
        equalizerButton.accessibilityHint = String(localized: "Shapes the sound with a response curve and presets")
        equalizerButton.addAction(UIAction { [weak self] _ in self?.presentEqualizer() }, for: .touchUpInside)
        equalizerBadge.addAction(UIAction { [weak self] _ in self?.presentEqualizer() }, for: .touchUpInside)
        updateEqualizerState()
    }

    func presentEqualizer() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        present(EqualizerViewController.makePresented(), animated: true)
    }

    func updateEqualizerState() {
        let isRunning = EqualizerEngine.shared.isRunning
        equalizerButton.tintColor = isRunning ? .white : .white.withAlphaComponent(0.7)
        equalizerButton.accessibilityValue = isRunning ? String(localized: "On") : String(localized: "Off")
        equalizerCapsule?.setActive(isRunning, animated: hasAppliedInitialState)
        equalizerBadge.isHidden = !isRunning
    }

    @objc func equalizerStateDidChange() {
        updateEqualizerState()
    }

    @objc func equalizerOutputDidChange(_ notification: Notification) {
        guard let profile = notification.userInfo?[EqualizerEngine.outputProfileKey] as? String,
              let output = EqualizerEngine.shared.output else { return }
        ToastView.show(EqualizerCopy.outputChanged(name: output.name, profile: profile), in: view)
    }

    func makeActionRow() -> UIView {
        configureActionButtons()

        let capsules: [PlayerAction: GlassCapsule] = [
            .shuffle: GlassCapsule(hosting: shuffleButton),
            .repeatMode: GlassCapsule(hosting: repeatButton),
            .airplay: GlassCapsule(hosting: airplayButton),
            .sleepTimer: GlassCapsule(hosting: sleepTimerButton),
            .share: GlassCapsule(hosting: shareButton),
            .lyrics: GlassCapsule(hosting: lyricsButton),
            .queue: GlassCapsule(hosting: queueButton),
        ]
        shuffleCapsule = capsules[.shuffle]
        repeatCapsule = capsules[.repeatMode]
        sleepTimerCapsule = capsules[.sleepTimer]
        lyricsCapsule = capsules[.lyrics]
        queueCapsule = capsules[.queue]

        let controls: [PlayerAction: UIView] = [
            .shuffle: shuffleButton,
            .repeatMode: repeatButton,
            .airplay: airplayButton,
            .sleepTimer: sleepTimerButton,
            .share: shareButton,
            .lyrics: lyricsButton,
            .queue: queueButton,
        ]
        let editor = PlayerActionRowEditor(
            container: actionRowContainer, host: view, capsules: capsules, controls: controls
        )
        editor.onOrderChanged = { [weak self] in self?.setupAccessibilityOrder() }
        actionRowEditor = editor

        relayoutActionRow()
        return actionRowContainer
    }

    /// Lays the capsules out from the person's saved order, splitting into two
    /// rows at accessibility text sizes or in a column too narrow for seven
    /// round capsules, so they never overflow or squeeze into ovals.
    func relayoutActionRow() {
        let wraps = traitCollection.preferredContentSizeCategory.isAccessibilityCategory || actionRowIsNarrow
        actionRowEditor?.applyLayout(wraps: wraps)
    }

    /// Opens the jiggle for the screenshot and exercise routes.
    func beginActionRowEditing() {
        actionRowEditor?.beginEditing()
    }

    /// Re-splits the capsule row when the column it lives in crosses the width
    /// that fits them on one line.
    func refreshActionRowWrapping() {
        let width = bottomControls.bounds.width
        guard width > 1 else { return }
        let narrow = width < AdaptiveLayout.actionRowSingleLineMinimumWidth
        guard narrow != actionRowIsNarrow else { return }
        actionRowIsNarrow = narrow
        relayoutActionRow()
    }

    func configureActionButtons() {
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)

        shuffleButton.setImage(UIImage(systemName: "shuffle", withConfiguration: iconConfig), for: .normal)
        shuffleButton.accessibilityLabel = String(localized: "Shuffle")
        shuffleButton.accessibilityIdentifier = "player.action.shuffle"
        shuffleButton.addAction(UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            AudioPlayer.shared.toggleShuffle()
            self?.updateShuffleRepeatState()
        }, for: .touchUpInside)

        repeatButton.setImage(UIImage(systemName: "repeat", withConfiguration: iconConfig), for: .normal)
        repeatButton.accessibilityLabel = String(localized: "Repeat")
        repeatButton.accessibilityIdentifier = "player.action.repeat"
        repeatButton.addAction(UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            AudioPlayer.shared.cycleRepeatMode()
            self?.updateShuffleRepeatState()
        }, for: .touchUpInside)

        airplayButton.tintColor = .white.withAlphaComponent(0.7)
        airplayButton.activeTintColor = .white
        airplayButton.accessibilityLabel = "AirPlay"
        airplayButton.accessibilityIdentifier = "player.action.airplay"

        sleepTimerButton.setImage(UIImage(systemName: "moon.zzz", withConfiguration: iconConfig), for: .normal)
        sleepTimerButton.accessibilityLabel = String(localized: "Sleep timer")
        sleepTimerButton.accessibilityIdentifier = "player.action.sleep"
        sleepTimerButton.addAction(UIAction { [weak self] _ in self?.showSleepTimerSheet() }, for: .touchUpInside)
        sleepTimerButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.sleepTimerMenuActions() ?? [])
            }
        ])

        shareButton.setImage(UIImage(systemName: "square.and.arrow.up", withConfiguration: iconConfig), for: .normal)
        shareButton.accessibilityLabel = String(localized: "Share")
        shareButton.accessibilityIdentifier = "player.action.share"
        shareButton.addAction(UIAction { [weak self] _ in
            guard let self, let track = AudioPlayer.shared.currentTrack else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self.shareTrackViaSonglink(title: track.title, artist: track.artist, from: self.view)
        }, for: .touchUpInside)
        shareButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.shareMenuActions() ?? [])
            }
        ])

        lyricsButton.setImage(UIImage(systemName: "text.quote", withConfiguration: iconConfig), for: .normal)
        lyricsButton.accessibilityLabel = String(localized: "Lyrics")
        lyricsButton.accessibilityIdentifier = "player.lyrics"
        lyricsButton.accessibilityHint = String(localized: "Shows lyrics in place of the artwork")
        lyricsButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.setCenterState(self.centerState == .lyrics ? .artwork : .lyrics)
        }, for: .touchUpInside)

        queueButton.setImage(UIImage(systemName: "list.bullet", withConfiguration: iconConfig), for: .normal)
        queueButton.accessibilityLabel = String(localized: "Queue")
        queueButton.accessibilityIdentifier = "player.queue"
        queueButton.accessibilityHint = String(localized: "Shows the queue in place of the artwork")
        queueButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.setCenterState(self.centerState == .queue ? .artwork : .queue)
        }, for: .touchUpInside)

        for button in [shuffleButton, repeatButton, sleepTimerButton, shareButton, lyricsButton, queueButton] {
            button.tintColor = .white.withAlphaComponent(0.7)
        }
    }

    func sleepTimerMenuActions() -> [UIMenuElement] {
        var actions: [UIMenuElement] = [15, 30, 45, 60].map { minutes in
            UIAction(title: String(localized: "\(minutes) minutes"), image: UIImage(systemName: "timer")) { [weak self] _ in
                AudioPlayer.shared.setSleepTimer(minutes: minutes)
                self?.updateSleepTimerButton()
            }
        }
        actions.append(UIAction(title: String(localized: "End of Track"), image: UIImage(systemName: "forward.end")) { [weak self] _ in
            AudioPlayer.shared.setSleepTimerEndOfTrack()
            self?.updateSleepTimerButton()
        })
        if AudioPlayer.shared.sleepTimerRemaining != nil || AudioPlayer.shared.sleepAtEndOfTrack {
            actions.append(UIAction(title: String(localized: "Cancel Timer"), image: UIImage(systemName: "xmark.circle"), attributes: .destructive) { [weak self] _ in
                AudioPlayer.shared.cancelSleepTimer()
                self?.updateSleepTimerButton()
            })
        }
        return actions
    }

    func shareMenuActions() -> [UIMenuElement] {
        guard let track = AudioPlayer.shared.currentTrack else { return [] }
        var actions: [UIMenuElement] = [
            UIAction(title: String(localized: "Share Track"), image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                guard let self else { return }
                self.shareTrackViaSonglink(title: track.title, artist: track.artist, from: self.view)
            },
            UIAction(title: String(localized: "Copy Songlink"), image: UIImage(systemName: "link")) { [weak self] _ in
                self?.copySonglink(title: track.title, artist: track.artist)
            },
        ]
        if LyricsService.shared.cachedLyrics(track: track.title, artist: track.artist) != nil {
            actions.append(UIAction(title: LyricShareCopy.menuTitle, image: UIImage(systemName: "quote.bubble")) { [weak self] _ in
                guard let self, let session = LyricShareSession.forCurrentTrack() else { return }
                LyricShareViewController.present(session, from: self)
            })
        }
        if let artwork = artworkView.image, artworkView.contentMode == .scaleAspectFill {
            actions.append(UIAction(title: String(localized: "Share Artwork"), image: UIImage(systemName: "photo")) { [weak self] _ in
                self?.shareArtworkImage(artwork)
            })
        }
        return actions
    }

    func copySonglink(title: String, artist: String) {
        Task { [weak self] in
            let outcome = await SonglinkService.shared.lookup(title: title, artist: artist)
            guard let result = outcome.result else {
                if let self, let message = outcome.failureMessage(title: title) {
                    ToastView.show(message, in: self.view, style: .error)
                }
                return
            }
            UIPasteboard.general.url = result.pageURL
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if let self {
                ToastView.show(String(localized: "Songlink copied"), in: self.view, style: .success)
            }
        }
    }

    func shareArtworkImage(_ image: UIImage) {
        let activity = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = artworkContainer
        present(activity, animated: true)
    }
}
