import FlaccyCore
import UIKit

extension EqualizerViewController: EqualizerCurveViewDelegate {

    func curveView(_ view: EqualizerCurveView, didBeginEditing index: Int) {
        selectedIndex = index
        if !engine.state.isEnabled { engine.setEnabled(true) }
    }

    func curveView(_ view: EqualizerCurveView, setTarget value: Double, at index: Int) {
        engine.edit { profile in
            guard profile.targets.indices.contains(index) else { return }
            profile.targets[index] = value
        }
    }

    func curveView(_ view: EqualizerCurveView, setFrequency frequency: Double, gain: Double, at index: Int) {
        engine.edit { profile in
            guard profile.bands.indices.contains(index) else { return }
            profile.bands[index].frequency = frequency
            if profile.bands[index].type.hasGain { profile.bands[index].gain = gain }
        }
        refreshAdvancedValues()
    }

    func curveView(_ view: EqualizerCurveView, scaleQBy factor: Double, at index: Int) {
        engine.edit { profile in
            guard profile.bands.indices.contains(index) else { return }
            let q = profile.bands[index].q * factor
            profile.bands[index].q = (min(max(q, EqualizerBand.qRange.lowerBound), EqualizerBand.qRange.upperBound) * 100).rounded() / 100
        }
    }

    func curveView(_ view: EqualizerCurveView, stepGainBy delta: Double, at index: Int) {
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
    }

    func curveView(_ view: EqualizerCurveView, resetBandAt index: Int) {
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
    }

    func curveView(_ view: EqualizerCurveView, addBandAtFrequency frequency: Double, gain: Double) {
        addBand(frequency: frequency, gain: gain)
    }

    func curveViewDidEndEditing(_ view: EqualizerCurveView) {
        refresh(animated: false)
    }

    func refreshAdvancedValues() {
        guard mode == .advanced else { return }
        updateAdvanced(profile: profile)
    }
}
