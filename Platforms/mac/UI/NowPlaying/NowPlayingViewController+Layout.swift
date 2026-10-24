import AppKit
import MidgarCore
import AVFoundation
import AVKit
import Combine

extension NowPlayingViewController {

    override func loadView() {
        let root = AppearanceReactiveView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(backdrop)

        scrim.locations = [0, 0.5, 1]
        let scrimView = NSView()
        scrimView.wantsLayer = true
        scrimView.layer?.addSublayer(scrim)
        scrimView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrimView)
        root.onAppearanceChange = { [weak self] in self?.applyBackdropTone() }

        let center = buildCenterColumn()
        buildColumn(lyricsColumn, hosting: lyricsPanel, title: String(localized: "Lyrics"))
        buildColumn(queueColumn, hosting: queuePanel, title: String(localized: "Up Next"))
        lyricsColumn.isHidden = !lyricsShown
        queueColumn.isHidden = !queueShown

        let body = NSStackView(views: [lyricsColumn, center, queueColumn])
        self.body = body
        body.orientation = .horizontal
        body.distribution = .fill
        body.spacing = 16
        body.alignment = .centerY
        body.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(body)
        center.setContentHuggingPriority(.init(1), for: .horizontal)
        body.setHuggingPriority(.init(1), for: .vertical)
        body.setContentHuggingPriority(.init(1), for: .vertical)
        body.setContentCompressionResistancePriority(.init(1), for: .vertical)
        lyricsWidthConstraint = lyricsColumn.widthAnchor.constraint(equalTo: center.widthAnchor)
        queueWidthConstraint = queueColumn.widthAnchor.constraint(equalTo: center.widthAnchor)
        lyricsWidthConstraint?.isActive = lyricsShown
        queueWidthConstraint?.isActive = queueShown
        applyColumnOrder()
        for column in [lyricsColumn, center, queueColumn] {
            NSLayoutConstraint.activate([
                column.topAnchor.constraint(equalTo: body.topAnchor),
                column.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            ])
        }

        let header = buildHeader()
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)

        let dock = buildTransportDock()
        dock.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(dock)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrimView.topAnchor.constraint(equalTo: root.topAnchor),
            scrimView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrimView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrimView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            header.heightAnchor.constraint(equalToConstant: 36),

            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            body.bottomAnchor.constraint(equalTo: dock.topAnchor, constant: -18),

            dock.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            dock.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            dock.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -64),
            dock.widthAnchor.constraint(lessThanOrEqualToConstant: 920),
            dock.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -64).with(priority: .defaultHigh),
        ])

        view = root
        scrimViewRef = scrimView
        applyBackdropTone()
    }

    /// The immersive readability scrim over the album-art field: a black veil in
    /// dark mode, a light veil in light mode so the whole surface follows the
    /// system appearance (mirrors the Linux Now Playing).
    func applyBackdropTone() {
        let dark = view.effectiveAppearance.isDark
        let base: NSColor = dark ? .black : .white
        let alphas: [CGFloat] = dark ? [0.62, 0.34, 0.68] : [0.74, 0.6, 0.78]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrim.colors = alphas.map { base.withAlphaComponent($0).cgColor }
        CATransaction.commit()
    }

    func buildHeader() -> NSView {
        let container = NSView()

        let closeButton = TransportButton(
            symbolName: "chevron.down", pointSize: 14, accessibilityLabel: String(localized: "Close Now Playing"),
            target: self, action: #selector(closeTapped)
        )
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(closeButton)

        lyricsCapsule = CapsuleButton(symbolName: "quote.bubble", title: String(localized: "Lyrics")) { [weak self] _ in
            self?.togglePanel(.lyrics)
        }
        queueCapsule = CapsuleButton(symbolName: "list.bullet", title: String(localized: "Up Next")) { [weak self] _ in
            self?.togglePanel(.queue)
        }
        swapCapsule = TransportButton(
            symbolName: "arrow.left.arrow.right", pointSize: 12,
            accessibilityLabel: String(localized: "Swap panel sides"),
            target: self, action: #selector(swapPanelSides)
        )
        swapCapsule.isHidden = !(lyricsShown && queueShown)

        let toggles = NSStackView(views: [lyricsCapsule, queueCapsule, swapCapsule])
        toggles.orientation = .horizontal
        toggles.spacing = 8
        toggles.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toggles)

        let aux = buildActionCapsules()
        aux.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(aux)

        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 60),
            closeButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            toggles.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            toggles.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            toggles.topAnchor.constraint(equalTo: container.topAnchor),
            toggles.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            aux.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            aux.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    func buildTransportDock() -> NSView {
        buildTransportButtons()
        configureScrubber()
        scrubber.style = .prominent

        let timeline = NSStackView(views: [elapsedLabel, scrubber, remainingLabel])
        timeline.orientation = .horizontal
        timeline.spacing = 14
        timeline.alignment = .centerY
        timeline.distribution = .fill

        let transportRow = NSStackView(views: [
            shuffleButton, backFifteenButton, previousButton, playPauseButton,
            nextButton, forwardFifteenButton, repeatButton,
        ])
        transportRow.orientation = .horizontal
        transportRow.spacing = 14
        transportRow.alignment = .centerY
        transportRow.setCustomSpacing(28, after: shuffleButton)
        transportRow.setCustomSpacing(28, after: forwardFifteenButton)

        let transportContainer = centeredRow(transportRow)
        let volumeContainer = centeredRow(buildVolumeRow())

        let stack = NSStackView(views: [timeline, transportContainer, volumeContainer])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        let stackHeight = stack.fittingSize.height
        let padding = NSEdgeInsets(top: 18, left: 28, bottom: 18, right: 28)

        let pad = NSView()
        pad.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        pad.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: pad.topAnchor, constant: padding.top),
            stack.leadingAnchor.constraint(equalTo: pad.leadingAnchor, constant: padding.left),
            stack.trailingAnchor.constraint(equalTo: pad.trailingAnchor, constant: -padding.right),
            stack.bottomAnchor.constraint(equalTo: pad.bottomAnchor, constant: -padding.bottom),
            timeline.widthAnchor.constraint(equalTo: stack.widthAnchor),
            transportContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            volumeContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrubber.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            scrubber.heightAnchor.constraint(equalToConstant: 26),
        ])

        let glass = MacLiquidGlass.surface(hosting: pad, cornerRadius: 26)
        glass.translatesAutoresizingMaskIntoConstraints = false

        let dock = NSView()
        dock.translatesAutoresizingMaskIntoConstraints = false
        dock.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: dock.topAnchor),
            glass.leadingAnchor.constraint(equalTo: dock.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: dock.trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: dock.bottomAnchor),
            dock.heightAnchor.constraint(equalToConstant: stackHeight + padding.top + padding.bottom),
        ])
        return dock
    }

    func centeredRow(_ content: NSView) -> NSView {
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        return container
    }

    func buildVolumeRow() -> NSView {
        volumeButton = TransportButton(
            symbolName: "speaker.wave.2.fill", pointSize: 13,
            accessibilityLabel: String(localized: "Mute"), target: self, action: #selector(toggleMute)
        )
        volumeButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        volumeButton.heightAnchor.constraint(equalToConstant: 30).isActive = true

        volumeSlider.minValue = 0
        volumeSlider.maxValue = 1
        volumeSlider.controlSize = .large
        volumeSlider.trackFillColor = .labelColor
        volumeSlider.isContinuous = true
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
        volumeSlider.toolTip = String(localized: "Volume")
        volumeSlider.setAccessibilityLabel(String(localized: "Volume"))
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.widthAnchor.constraint(equalToConstant: 190).isActive = true
        volumeSlider.heightAnchor.constraint(equalToConstant: 30).isActive = true

        volumeLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        volumeLabel.textColor = MacColors.tertiaryLabel
        volumeLabel.alignment = .right
        volumeLabel.setContentHuggingPriority(.required, for: .horizontal)
        volumeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        volumeLabel.widthAnchor.constraint(equalToConstant: 34).isActive = true

        let row = NSStackView(views: [volumeButton, volumeSlider, volumeLabel])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        refreshVolume()
        return row
    }
}
