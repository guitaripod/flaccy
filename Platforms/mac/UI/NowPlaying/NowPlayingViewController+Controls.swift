import AppKit
import MidgarCore
import AVFoundation
import AVKit
import Combine

extension NowPlayingViewController {

    func configureLabels() {
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = MacColors.primaryLabel
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.heightAnchor.constraint(equalToConstant: 28).isActive = true
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        artistButton.font = .systemFont(ofSize: 15, weight: .medium)
        artistButton.contentTintColor = MacColors.primaryLabel
        artistButton.target = self
        artistButton.action = #selector(artistTapped)
        artistButton.setContentCompressionResistancePriority(.required, for: .vertical)

        albumLabel.font = .systemFont(ofSize: 12)
        albumLabel.textColor = MacColors.tertiaryLabel
        albumLabel.lineBreakMode = .byTruncatingTail
        albumLabel.alignment = .center
        albumLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        badgeLabel.font = .systemFont(ofSize: 10, weight: .semibold)

        loveButton = TransportButton(
            symbolName: "heart", pointSize: 16, accessibilityLabel: String(localized: "Love on Last.fm"),
            target: self, action: #selector(toggleLove)
        )

        for label in [elapsedLabel, remainingLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            label.textColor = MacColors.secondaryLabel
            label.alignment = label === elapsedLabel ? .right : .left
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.widthAnchor.constraint(equalToConstant: 52).isActive = true
        }
    }

    func buildTransportButtons() {
        shuffleButton = TransportButton(
            symbolName: "shuffle", pointSize: 15, accessibilityLabel: String(localized: "Shuffle"),
            target: self, action: #selector(toggleShuffle)
        )
        backFifteenButton = TransportButton(
            symbolName: "gobackward.15", pointSize: 16, accessibilityLabel: String(localized: "Back 15 seconds"),
            target: self, action: #selector(skipBackFifteen)
        )
        previousButton = TransportButton(
            symbolName: "backward.fill", pointSize: 20, accessibilityLabel: String(localized: "Previous"),
            target: self, action: #selector(previousTrack)
        )
        playPauseButton = TransportButton(
            symbolName: "play.fill", pointSize: 34, accessibilityLabel: String(localized: "Play or pause"),
            target: self, action: #selector(togglePlayPause)
        )
        playPauseButton.isProminent = true
        playPauseButton.widthAnchor.constraint(equalToConstant: 72).isActive = true
        playPauseButton.heightAnchor.constraint(equalToConstant: 72).isActive = true
        nextButton = TransportButton(
            symbolName: "forward.fill", pointSize: 20, accessibilityLabel: String(localized: "Next"),
            target: self, action: #selector(nextTrack)
        )
        forwardFifteenButton = TransportButton(
            symbolName: "goforward.15", pointSize: 16, accessibilityLabel: String(localized: "Forward 15 seconds"),
            target: self, action: #selector(skipForwardFifteen)
        )
        repeatButton = TransportButton(
            symbolName: "repeat", pointSize: 15, accessibilityLabel: String(localized: "Repeat"),
            target: self, action: #selector(cycleRepeat)
        )
        let secondaryButtons: [TransportButton] = [
            shuffleButton, backFifteenButton, previousButton, nextButton, forwardFifteenButton, repeatButton
        ]
        for button in secondaryButtons {
            button.widthAnchor.constraint(equalToConstant: 40).isActive = true
            button.heightAnchor.constraint(equalToConstant: 40).isActive = true
        }
    }

    @objc func volumeChanged() {
        player.volume = Float(volumeSlider.doubleValue)
        refreshVolume()
    }

    @objc func volumeDidChangeExternally() {
        refreshVolume()
    }

    @objc func toggleMute() {
        if player.volume > 0 {
            volumeBeforeMute = player.volume
            player.volume = 0
        } else {
            player.volume = volumeBeforeMute ?? 0.8
            volumeBeforeMute = nil
        }
        refreshVolume()
    }

    @objc func equalizerChanged() {
        equalizerButton.isActiveToggle = EqualizerEngine.shared.isRunning
    }

    @objc func showEqualizerPanel() {
        if let popover = equalizerPopover, popover.isShown {
            popover.close()
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = MacEqualizerQuickPanel()
        popover.show(relativeTo: equalizerButton.bounds, of: equalizerButton, preferredEdge: .maxY)
        equalizerPopover = popover
    }

    func refreshVolume() {
        let volume = player.volume
        volumeSlider.doubleValue = Double(volume)
        volumeLabel.stringValue = "\(Int((volume * 100).rounded()))%"
        let symbol: String
        if volume == 0 {
            symbol = "speaker.slash.fill"
        } else if volume < 0.34 {
            symbol = "speaker.wave.1.fill"
        } else if volume < 0.67 {
            symbol = "speaker.wave.2.fill"
        } else {
            symbol = "speaker.wave.3.fill"
        }
        volumeButton.setSymbol(symbol, pointSize: 13)
        volumeButton.isActiveToggle = volume == 0
        volumeButton.setAccessibilityLabel(
            volume == 0 ? String(localized: "Unmute") : String(localized: "Mute")
        )
    }

    func configureScrubber() {
        scrubber.onScrub = { [weak self] time in
            self?.chaseSeek(to: time)
        }
        scrubber.onCommit = { [weak self] time in
            self?.player.seek(to: time)
        }
    }

    func buildActionCapsules() -> NSView {
        sleepCapsule = CapsuleButton(symbolName: "moon.zzz", title: String(localized: "Sleep")) { [weak self] button in
            self?.showSleepMenu(from: button)
        }
        shareCapsule = CapsuleButton(symbolName: "square.and.arrow.up", title: String(localized: "Share")) { [weak self] button in
            self?.shareCurrentTrack(from: button)
        }

        equalizerButton = TransportButton(
            symbolName: "slider.vertical.3", pointSize: 13,
            accessibilityLabel: EqualizerCopy.title, target: self, action: #selector(showEqualizerPanel)
        )
        equalizerButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        equalizerButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        equalizerButton.isActiveToggle = EqualizerEngine.shared.isRunning

        routePicker.translatesAutoresizingMaskIntoConstraints = false
        routePicker.widthAnchor.constraint(equalToConstant: 34).isActive = true
        routePicker.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let row = NSStackView(views: [sleepCapsule, shareCapsule, equalizerButton, routePicker])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        return row
    }
}
