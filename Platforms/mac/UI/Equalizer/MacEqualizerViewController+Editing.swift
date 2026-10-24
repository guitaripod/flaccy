import AppKit
import FlaccyCore
import UniformTypeIdentifiers

extension MacEqualizerViewController {

    func beginEditing() {
        if undoBase == nil { undoBase = engine.state }
    }

    func finishEditing() {
        guard let base = undoBase else { return }
        undoBase = nil
        guard base != engine.state else { return }
        registerUndo(restoring: base)
    }

    func registerUndo(restoring previous: EqualizerState) {
        view.window?.undoManager?.registerUndo(withTarget: self) { target in
            let current = target.engine.state
            target.engine.restore(previous)
            target.registerUndo(restoring: current)
        }
        view.window?.undoManager?.setActionName(String(localized: "Equalizer"))
    }

    func select(_ index: Int) {
        selectedIndex = index
        if !engine.state.isEnabled { engine.setEnabled(true) }
        refresh(animated: false)
    }

    func setTarget(_ value: Double, at index: Int) {
        beginEditing()
        engine.edit { profile in
            guard profile.targets.indices.contains(index) else { return }
            profile.targets[index] = min(max(value, -12), 12)
        }
        finishEditing()
    }

    func stepBand(_ index: Int, by delta: Double) {
        beginEditing()
        engine.edit { profile in
            switch profile.kind {
            case .graphic:
                guard profile.targets.indices.contains(index) else { return }
                profile.targets[index] = min(max(profile.targets[index] + delta, -12), 12)
            case .parametric:
                guard profile.bands.indices.contains(index), profile.bands[index].type.hasGain else { return }
                profile.bands[index].gain = min(max(profile.bands[index].gain + delta, -12), 12)
            }
        }
        finishEditing()
    }

    func resetBand(_ index: Int) {
        beginEditing()
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

    func editBand(_ index: Int, _ change: (inout EqualizerBand) -> Void) {
        beginEditing()
        engine.edit { profile in
            guard profile.bands.indices.contains(index) else { return }
            change(&profile.bands[index])
            profile.bands[index] = profile.bands[index].clamped()
        }
        finishEditing()
    }

    // MARK: Actions

    @objc func toggleEnabled() {
        beginEditing()
        engine.setEnabled(enableSwitch.state == .on)
        finishEditing()
    }

    func keepPreset(_ id: String) {
        endAudition()
        beginEditing()
        engine.select(profileID: id)
        finishEditing()
        refresh(animated: false)
        view.window?.makeFirstResponder(curveView)
    }

    @objc func modeChanged() {
        let wantsAdvanced = modeControl.selectedSegment == 1
        if wantsAdvanced == (profile.kind == .parametric) { return }
        if wantsAdvanced {
            beginEditing()
            _ = engine.convertInForce(to: .parametric)
            selectedIndex = 0
            finishEditing()
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Switch to Simple?")
        alert.informativeText = String(localized: "Simple mode holds ten points, so Flaccy matches your curve as closely as ten points allow. Your Advanced profile stays as it is.")
        alert.addButton(withTitle: String(localized: "Switch"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                self.beginEditing()
                _ = self.engine.convertInForce(to: .graphic)
                self.selectedIndex = 5
                self.finishEditing()
            } else {
                self.refresh(animated: false)
            }
        }
    }

    @objc func preampMoved() {
        beginEditing()
        let value = (preampSlider.doubleValue * 2).rounded() / 2
        engine.edit { profile in
            profile.isAutoPreamp = false
            profile.manualPreamp = value
        }
        if NSApp.currentEvent?.type == .leftMouseUp { finishEditing() }
    }

    @objc func toggleAutoPreamp() {
        beginEditing()
        engine.edit { profile in
            if profile.isAutoPreamp {
                profile.manualPreamp = profile.preamp()
                profile.isAutoPreamp = false
            } else {
                profile.isAutoPreamp = true
            }
        }
        finishEditing()
    }

    func beginCompare() {
        engine.beginCompare()
        refresh(animated: false)
    }

    func endCompare() {
        engine.endCompare()
        refresh(animated: false)
    }

    @objc func promptSave() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Save as Preset")
        alert.informativeText = String(localized: "Give this curve a name. It appears at the start of your presets.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = EqualizerCopy.name(of: profile)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            self?.beginEditing()
            self?.engine.saveInForce(as: name)
            self?.finishEditing()
            MacToast.show(String(localized: "Saved \u{201C}\(name)\u{201D}"), in: window)
        }
    }

    @objc func importProfile() {
        guard let window = view.window else { return }
        let sheet = MacEqualizerImportViewController(accent: accent)
        sheet.onFinish = { [weak self] in self?.refresh(animated: false) }
        presentAsSheet(sheet)
        _ = window
    }

    @objc func exportProfile() {
        export(profile)
    }

    @objc func copyProfile() {
        copyAsText(profile)
    }

    func export(_ profile: EqualizerProfile) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(EqualizerCopy.name(of: profile)).txt"
        guard let window = view.window else { return }
        let text = engine.exportText(for: profile)
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func copyAsText(_ profile: EqualizerProfile) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(engine.exportText(for: profile), forType: .string)
        if let window = view.window { MacToast.show(String(localized: "Copied to the clipboard"), in: window) }
    }

    func promptRename(_ id: String) {
        guard let target = engine.state.userProfiles.first(where: { $0.id == id }), let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename Preset")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = target.name
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Rename"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard response == .alertFirstButtonReturn, !name.isEmpty else { return }
            self?.beginEditing()
            self?.engine.rename(profileID: id, to: name)
            self?.finishEditing()
        }
        alert.window.makeFirstResponder(field)
    }

    func confirmDelete(_ id: String) {
        guard let target = engine.state.userProfiles.first(where: { $0.id == id }), let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Delete \u{201C}\(target.name)\u{201D}?")
        alert.informativeText = String(localized: "This removes the preset. Anything that used it goes back to Flat.")
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.beginEditing()
            self?.engine.delete(profileID: id)
            self?.finishEditing()
        }
    }

    @objc func openAutoEq() {
        if let url = URL(string: "https://autoeq.app") { NSWorkspace.shared.open(url) }
    }

    @objc func addBandPressed() {
        addBand(frequency: 1_000, gain: 0)
    }

    @objc func removeBandPressed() {
        deleteSelectedBand()
    }

    func addBand(frequency: Double, gain: Double) {
        guard profile.bands.count < EqualizerBand.maximumPerProfile else {
            if let window = view.window { MacToast.show(String(localized: "Up to 10 bands"), in: window) }
            return
        }
        beginEditing()
        engine.edit { profile in
            profile.bands.append(EqualizerBand(type: .bell, frequency: frequency, gain: gain, q: 1))
        }
        selectedIndex = profile.bands.count - 1
        finishEditing()
        refresh(animated: false)
    }

    func deleteSelectedBand() {
        guard mode == .advanced, profile.bands.count > 1 else { return }
        let index = clampedSelection()
        beginEditing()
        engine.edit { profile in
            guard profile.bands.indices.contains(index) else { return }
            profile.bands.remove(at: index)
        }
        selectedIndex = max(index - 1, 0)
        finishEditing()
        refresh(animated: false)
    }
}
