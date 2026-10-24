import AppKit
import FlaccyCore
import UniformTypeIdentifiers

extension MacEqualizerViewController: MacEqualizerCurveViewDelegate {

    func interaction(didBeginEditing index: Int) {
        beginEditing()
        selectedIndex = index
        if !engine.state.isEnabled { engine.setEnabled(true) }
    }

    func interaction(setTarget value: Double, at index: Int) {
        engine.edit { profile in
            guard profile.targets.indices.contains(index) else { return }
            profile.targets[index] = value
        }
    }

    func interaction(setFrequency frequency: Double, gain: Double, at index: Int) {
        engine.edit { profile in
            guard profile.bands.indices.contains(index) else { return }
            profile.bands[index].frequency = frequency
            if profile.bands[index].type.hasGain { profile.bands[index].gain = gain }
        }
    }

    func interaction(resetBandAt index: Int) {
        engine.edit { profile in
            switch profile.kind {
            case .graphic:
                guard profile.targets.indices.contains(index) else { return }
                profile.targets[index] = 0
            case .parametric:
                guard profile.bands.indices.contains(index) else { return }
                profile.bands[index].gain = 0
            }
        }
        finishEditing()
    }

    func interaction(addBandAtFrequency frequency: Double, gain: Double) {
        guard profile.bands.count < EqualizerBand.maximumPerProfile else { return }
        engine.edit { profile in
            profile.bands.append(EqualizerBand(type: .bell, frequency: frequency, gain: gain, q: 1))
        }
        selectedIndex = profile.bands.count - 1
    }

    func interaction(didCross detent: EqualizerDetent) {
        if detent == .zero || detent == .reset || detent == .add {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    func interactionDidEnd() {
        finishEditing()
        refresh(animated: false)
    }

    func curveView(_ view: MacEqualizerCurveView, scaleQBy factor: Double, at index: Int) {
        editBand(index) { $0.q = ($0.q * factor * 100).rounded() / 100 }
    }

    func curveView(_ view: MacEqualizerCurveView, stepGainBy delta: Double, at index: Int) {
        stepBand(index, by: delta)
    }

    func curveView(_ view: MacEqualizerCurveView, selectBandBy offset: Int) {
        let count = mode == .simple ? GraphicSolver.centres.count : profile.bands.count
        guard count > 0 else { return }
        selectedIndex = min(max(selectedIndex + offset, 0), count - 1)
        refresh(animated: false)
    }

    func curveViewDeleteSelectedBand(_ view: MacEqualizerCurveView) {
        deleteSelectedBand()
    }

    func curveViewBeginCompare(_ view: MacEqualizerCurveView) {
        beginCompare()
    }

    func curveViewEndCompare(_ view: MacEqualizerCurveView) {
        endCompare()
    }
}

extension MacEqualizerViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        mode == .advanced ? profile.bands.count : 0
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row != selectedIndex, mode == .advanced else { return }
        selectedIndex = row
        curveView.update(contentForCurve(), animated: false)
    }

    func contentForCurve() -> EqualizerCurveContent {
        var content = curveView.content
        content.selectedIndex = selectedIndex
        return content
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard profile.bands.indices.contains(row), let identifier = tableColumn?.identifier.rawValue else { return nil }
        let band = profile.bands[row]
        switch identifier {
        case "index":
            let label = NSTextField(labelWithString: "  \(row + 1)")
            label.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .bold)
            label.textColor = EqualizerTheme.bandColor(row)
            return verticallyCentered(label)
        case "enabled":
            let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(enabledToggled(_:)))
            check.state = band.isEnabled ? .on : .off
            check.tag = row
            return verticallyCentered(check)
        case "type":
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: 12)
            for type in EqualizerFilterType.allCases { popup.addItem(withTitle: EqualizerCopy.typeName(type)) }
            popup.selectItem(at: EqualizerFilterType.allCases.firstIndex(of: band.type) ?? 0)
            popup.tag = row
            popup.target = self
            popup.action = #selector(typeChosen(_:))
            return verticallyCentered(popup)
        case "frequency":
            return verticallyCentered(field(text: EqualizerCopy.hertz(band.frequency), row: row, kind: .frequency, enabled: true))
        case "gain":
            return verticallyCentered(field(text: band.type.hasGain ? "\(EqualizerCopy.decibels(band.gain)) dB" : "—", row: row, kind: .gain, enabled: band.type.hasGain))
        case "q":
            return verticallyCentered(field(text: EqualizerCopy.q(band.q), row: row, kind: .q, enabled: true))
        default:
            return nil
        }
    }

    /// A table cell that holds `control` on the row's vertical centre: row views
    /// otherwise pin a cell's content to its top edge, so text sat above the
    /// pop-ups beside it.
    func verticallyCentered(_ control: NSView) -> NSView {
        let cell = NSView()
        control.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            control is NSTextField
                ? control.trailingAnchor.constraint(equalTo: cell.trailingAnchor)
                : control.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    enum FieldKind: Int {
        case frequency
        case gain
        case q
    }

    func field(text: String, row: Int, kind: FieldKind, enabled: Bool) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        field.textColor = .white.withAlphaComponent(enabled ? 0.9 : 0.35)
        field.isEditable = enabled
        field.identifier = NSUserInterfaceItemIdentifier("\(kind.rawValue):\(row)")
        field.target = self
        field.action = #selector(fieldCommitted(_:))
        return field
    }

    @objc func enabledToggled(_ sender: NSButton) {
        editBand(sender.tag) { $0.isEnabled = sender.state == .on }
    }

    @objc func typeChosen(_ sender: NSPopUpButton) {
        let type = EqualizerFilterType.allCases[sender.indexOfSelectedItem]
        editBand(sender.tag) { band in
            band.type = type
            band.q = type.defaultQ
            if !type.hasGain { band.gain = 0 }
        }
    }

    @objc func fieldCommitted(_ sender: NSTextField) {
        let parts = (sender.identifier?.rawValue ?? "").split(separator: ":")
        guard parts.count == 2, let rawKind = Int(parts[0]), let kind = FieldKind(rawValue: rawKind), let row = Int(parts[1]) else { return }
        switch kind {
        case .frequency:
            if let value = Self.parseFrequency(sender.stringValue) { editBand(row) { $0.frequency = value } }
        case .gain:
            if let value = Self.parseNumber(sender.stringValue) { editBand(row) { $0.gain = value } }
        case .q:
            if let value = Self.parseNumber(sender.stringValue) { editBand(row) { $0.q = value } }
        }
        refresh(animated: false)
    }

    static func parseNumber(_ text: String) -> Double? {
        let cleaned = text.lowercased().replacingOccurrences(of: "db", with: "").replacingOccurrences(of: "\u{2212}", with: "-").trimmingCharacters(in: .whitespaces)
        return Double(cleaned)
    }

    static func parseFrequency(_ text: String) -> Double? {
        var cleaned = text.lowercased().replacingOccurrences(of: "hz", with: "").trimmingCharacters(in: .whitespaces)
        var factor = 1.0
        if cleaned.hasSuffix("k") {
            factor = 1_000
            cleaned.removeLast()
        }
        return Double(cleaned.trimmingCharacters(in: .whitespaces)).map { $0 * factor }
    }
}
