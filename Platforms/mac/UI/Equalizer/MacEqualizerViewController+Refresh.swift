import AppKit
import FlaccyCore
import UniformTypeIdentifiers

extension MacEqualizerViewController {

    func refresh(animated: Bool) {
        guard isViewLoaded else { return }
        let profile = profile
        let state = engine.state
        let running = state.isEnabled && !engine.isOutputBoundToOff

        enableSwitch.state = running ? .on : .off
        enableLabel.stringValue = running ? String(localized: "On") : String(localized: "Off")
        modeControl.selectedSegment = profile.kind == .graphic ? 0 : 1

        var content = EqualizerCurveContent()
        content.mode = mode
        content.targets = profile.targets
        content.bands = profile.bands.map { $0.clamped() }
        content.selectedIndex = clampedSelection()
        content.isEnabled = running
        content.isComparing = engine.isComparing
        content.accent = accent
        curveView.update(content, animated: animated)

        simpleStrip.superview?.isHidden = false
        simpleStrip.isHidden = mode != .simple
        advancedPanel.isHidden = mode != .advanced
        lowerHeight?.constant = mode == .simple ? 168 : 212
        hintLabel.stringValue = mode == .simple
            ? String(localized: "Drag a point, or type a value. The curve passes through every point.")
            : String(localized: "Drag a node · scroll over it to change Q · double-click empty space to add a band")

        profileTitle.stringValue = EqualizerCopy.name(of: profile)
        previewPill.setAccent(accent)
        deck.sync(userProfiles: engine.state.userProfiles, currentID: profile.id, accent: accent)
        endAuditionIfPresetVanished()
        updateOutputButton()
        updatePreamp(profile: profile)
        updateStatus(profile: profile, running: running)
        if mode == .simple { updateCells(profile: profile) } else { table.reloadData(); syncTableSelection() }
        compareButton.title = engine.isComparing ? String(localized: "Hearing original") : String(localized: "Hold to compare")
    }

    func clampedSelection() -> Int {
        let count = mode == .simple ? GraphicSolver.centres.count : max(profile.bands.count, 1)
        selectedIndex = min(max(selectedIndex, 0), count - 1)
        return selectedIndex
    }

    func updateOutputButton() {
        let output = engine.output
        outputButton.title = output?.name ?? String(localized: "Output")
        let symbol: String
        switch output?.kind {
        case .headphones: symbol = "headphones"
        case .bluetooth: symbol = "airpods.pro"
        case .airPlay: symbol = "airplayaudio"
        case .usb: symbol = "cable.connector"
        case .display: symbol = "tv"
        default: symbol = "speaker.wave.2"
        }
        outputButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        outputButton.toolTip = engine.keepsOwnProfileForOutput
            ? String(localized: "This output remembers its own profile")
            : String(localized: "Choose the profile for this output")
    }

    func updatePreamp(profile: EqualizerProfile) {
        let preamp = profile.preamp()
        preampValue.stringValue = "\(EqualizerCopy.decibels(preamp)) dB"
        if !preampSlider.isHighlighted { preampSlider.doubleValue = preamp }
        autoButton.title = profile.isAutoPreamp ? String(localized: "Auto") : String(localized: "Manual")
        autoButton.state = profile.isAutoPreamp ? .on : .off
        preampSlider.trackFillColor = profile.isAutoPreamp ? accent.withAlphaComponent(0.6) : accent
        preampSlider.setAccessibilityValue("\(EqualizerCopy.decibels(preamp)) dB")
    }

    func updateStatus(profile: EqualizerProfile, running: Bool) {
        let status: EqualizerCopy.Status
        if !running { status = .off } else if engine.isComparing { status = .comparing } else if profile.isFlat { status = .flat } else { status = .processing }
        let color: NSColor
        let symbol: String
        switch status {
        case .off, .flat: color = EqualizerTheme.lossless; symbol = "checkmark.circle"
        case .processing: color = accent; symbol = "waveform"
        case .comparing: color = EqualizerTheme.caution; symbol = "circle.lefthalf.filled"
        }
        statusLabel.stringValue = EqualizerCopy.status(status)
        statusLabel.textColor = color
        statusIcon.contentTintColor = color
        statusIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    func updateCells(profile: EqualizerProfile) {
        for (index, cell) in cells.enumerated() where index < profile.targets.count {
            cell.configure(
                frequency: EqualizerCopy.hertz(GraphicSolver.centres[index]),
                value: profile.targets[index],
                isSelected: index == selectedIndex,
                accent: accent
            )
        }
    }

    func syncTableSelection() {
        let index = clampedSelection()
        if profile.bands.indices.contains(index), table.selectedRow != index {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    func updateMeter() {
        let meter = engine.meter()
        let peak = meter?.peak ?? 0
        let decibels: Float = peak > 0.000_03 ? 20 * log10(peak) : -60
        let color: NSColor = decibels > -1 ? EqualizerTheme.danger : (decibels > -3 ? EqualizerTheme.caution : EqualizerTheme.lossless)
        meterLeft.set(peakDecibels: decibels, color: color)
        meterRight.set(peakDecibels: decibels - 0.6, color: color)
        peakLabel.stringValue = meter == nil ? "—" : String(format: "%.1f dB", decibels)
        peakLabel.textColor = meter == nil ? .white.withAlphaComponent(0.42) : color
        let reduced = meter?.guardReduced ?? false
        if reduced != guardActive {
            guardActive = reduced
            statusLabel.toolTip = reduced ? String(localized: "Peak guard is catching overs. Lower the preamp or return to Auto.") : nil
        }
    }
}
