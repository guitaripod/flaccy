import FlaccyCore
import UIKit

extension EqualizerViewController {

    func toggleEnabled() {
        impact.impactOccurred()
        engine.setEnabled(enableSwitch.isOn)
    }

    func modeChanged() {
        impact.impactOccurred()
        let wantsAdvanced = modeControl.selectedSegmentIndex == 1
        if wantsAdvanced == (profile.kind == .parametric) { return }
        if wantsAdvanced {
            _ = engine.convertInForce(to: .parametric)
            selectedIndex = 0
        } else {
            let alert = UIAlertController(
                title: String(localized: "Switch to Simple?"),
                message: String(localized: "Simple mode holds ten points, so Flaccy matches your curve as closely as ten points allow. Your Advanced profile stays as it is."),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { [weak self] _ in self?.refresh(animated: false) })
            alert.addAction(UIAlertAction(title: String(localized: "Switch"), style: .default) { [weak self] _ in
                _ = self?.engine.convertInForce(to: .graphic)
                self?.selectedIndex = 3
            })
            present(alert, animated: true)
        }
    }

    func toggleAutoPreamp() {
        selection.selectionChanged()
        engine.edit { profile in
            if profile.isAutoPreamp {
                profile.manualPreamp = profile.preamp()
                profile.isAutoPreamp = false
            } else {
                profile.isAutoPreamp = true
            }
        }
    }

    func preampSliderMoved() {
        let value = (Double(preampSlider.value) * 2).rounded() / 2
        if value != Double(preampSlider.value) { preampSlider.value = Float(value) }
        selection.selectionChanged()
        engine.edit { profile in
            profile.isAutoPreamp = false
            profile.manualPreamp = value
        }
    }

    func beginCompare() {
        impact.impactOccurred()
        engine.beginCompare()
        refresh(animated: false)
    }

    func endCompare() {
        guard engine.isComparing else { return }
        impact.impactOccurred()
        engine.endCompare()
        refresh(animated: false)
    }

    func resetToFlat() {
        impact.impactOccurred()
        engine.select(profileID: EqualizerProfile.flatID)
        selectedIndex = 3
    }

    func setType(_ type: EqualizerFilterType) {
        let index = clampedSelection()
        selection.selectionChanged()
        engine.edit { profile in
            guard profile.bands.indices.contains(index) else { return }
            profile.bands[index].type = type
            profile.bands[index].q = type.defaultQ
            if !type.hasGain { profile.bands[index].gain = 0 }
        }
    }

    func deleteSelectedBand() {
        let index = clampedSelection()
        guard profile.bands.count > 1 else { return }
        impact.impactOccurred()
        engine.edit { profile in
            guard profile.bands.indices.contains(index) else { return }
            profile.bands.remove(at: index)
        }
        selectedIndex = max(index - 1, 0)
        refresh(animated: false)
    }

    func addBand(frequency: Double, gain: Double) {
        guard profile.bands.count < EqualizerBand.maximumPerProfile else {
            ToastView.show(String(localized: "Up to 10 bands"), in: view)
            return
        }
        engine.edit { profile in
            profile.bands.append(EqualizerBand(type: .bell, frequency: frequency, gain: gain, q: 1))
        }
        selectedIndex = profile.bands.count - 1
        refresh(animated: false)
    }

    func promptSave() {
        let alert = UIAlertController(
            title: String(localized: "Save as Preset"),
            message: String(localized: "Give this curve a name. It appears at the start of your presets."),
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = String(localized: "Name")
            field.text = EqualizerCopy.name(of: self.profile)
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .words
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Save"), style: .default) { [weak self, weak alert] _ in
            guard let self, let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
            self.engine.saveInForce(as: name)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            ToastView.show(String(localized: "Saved \u{201C}\(name)\u{201D}"), in: self.view)
        })
        present(alert, animated: true)
    }

    func exportProfile() {
        let text = engine.exportText(for: profile)
        let activity = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = moreCapsule
        present(activity, animated: true)
    }

    func openPresets() {
        navigationController?.pushViewController(EqualizerPresetsViewController(startingOn: .presets, accent: accent), animated: true)
    }

    func openOutputs() {
        navigationController?.pushViewController(EqualizerPresetsViewController(startingOn: .outputs, accent: accent), animated: true)
    }

    func openImport() {
        navigationController?.pushViewController(EqualizerImportViewController(accent: accent), animated: true)
    }
}
