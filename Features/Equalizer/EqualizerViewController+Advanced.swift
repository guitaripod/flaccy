import FlaccyCore
import UIKit

extension EqualizerViewController {

    func updateAdvanced(profile: EqualizerProfile) {
        let selected = clampedSelection()
        guard profile.bands.indices.contains(selected) else { return }
        let signature = "\(selected)|\(profile.bands.count)|\(profile.bands[selected].type.rawValue)|\(accent.hash)"
        if signature != advancedSignature {
            advancedSignature = signature
            rebuildAdvancedChips(profile: profile, selected: selected)
        }
        updateAdvancedValues(profile: profile, selected: selected)
    }

    func rebuildAdvancedChips(profile: EqualizerProfile, selected: Int) {
        bandChipsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, band) in profile.bands.enumerated() {
            let button = UIButton(type: .custom)
            button.translatesAutoresizingMaskIntoConstraints = false
            let color = EqualizerTheme.bandColor(index)
            button.setTitle("\(index + 1)", for: .normal)
            button.titleLabel?.font = .equalizerRounded(.callout, size: 14, weight: .heavy)
            button.setTitleColor(.white, for: .normal)
            button.backgroundColor = color.withAlphaComponent(index == selected ? 0.38 : 0.18)
            button.layer.cornerRadius = 18
            button.layer.borderWidth = 2
            button.layer.borderColor = (index == selected ? UIColor.white : color.withAlphaComponent(0.65)).cgColor
            button.accessibilityLabel = String(localized: "Band \(index + 1), \(EqualizerCopy.hertz(band.frequency))")
            button.accessibilityTraits = index == selected ? [.button, .selected] : .button
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 36),
                button.heightAnchor.constraint(equalToConstant: 36),
            ])
            button.addAction(UIAction { [weak self] _ in
                self?.selection.selectionChanged()
                self?.selectedIndex = index
                self?.refresh(animated: false)
            }, for: .touchUpInside)
            bandChipsRow.addArrangedSubview(button)
        }
        let add = UIButton(type: .system)
        add.translatesAutoresizingMaskIntoConstraints = false
        add.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)), for: .normal)
        add.tintColor = .white
        add.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        add.layer.cornerRadius = 18
        add.accessibilityLabel = String(localized: "Add band")
        NSLayoutConstraint.activate([add.widthAnchor.constraint(equalToConstant: 36), add.heightAnchor.constraint(equalToConstant: 36)])
        add.addAction(UIAction { [weak self] _ in self?.addBand(frequency: 1_000, gain: 0) }, for: .touchUpInside)
        bandChipsRow.addArrangedSubview(add)

        let band = profile.bands[selected]
        let bandColor = EqualizerTheme.bandColor(selected)
        typeChipsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for type in EqualizerFilterType.allCases {
            let chip = EqualizerChip(title: "")
            chip.set(title: EqualizerCopy.typeName(type), active: band.type == type, tint: bandColor)
            chip.addAction(UIAction { [weak self] _ in self?.setType(type) }, for: .touchUpInside)
            typeChipsRow.addArrangedSubview(chip)
        }
    }

    func updateAdvancedValues(profile: EqualizerProfile, selected: Int) {
        let band = profile.bands[selected]
        let bandColor = EqualizerTheme.bandColor(selected)
        for (index, view) in bandChipsRow.arrangedSubviews.enumerated() where profile.bands.indices.contains(index) {
            view.accessibilityLabel = String(localized: "Band \(index + 1), \(EqualizerCopy.hertz(profile.bands[index].frequency))")
        }
        freqValue.text = EqualizerCopy.hertz(band.frequency)
        gainValue.text = band.type.hasGain ? "\(EqualizerCopy.decibels(band.gain)) dB" : "\u{2014}"
        qValue.text = EqualizerCopy.q(band.q)
        gainColumn.alpha = band.type.hasGain ? 1 : 0.35
        gainRuler.isUserInteractionEnabled = band.type.hasGain
        for ruler in [freqRuler, gainRuler, qRuler] { ruler.pointerColor = bandColor }
        freqRuler.accessibilityValue = EqualizerCopy.hertz(band.frequency)
        gainRuler.accessibilityValue = "\(EqualizerCopy.decibels(band.gain)) dB"
        qRuler.accessibilityValue = EqualizerCopy.q(band.q)
    }

    func updateCompareTitle() {
        var configuration = compareButton.configuration
        configuration?.title = engine.isComparing ? String(localized: "Hearing original") : String(localized: "Hold to compare")
        configuration?.baseForegroundColor = engine.isComparing ? EqualizerTheme.caution : .white
        compareButton.configuration = configuration
    }

    func updateMeter() {
        let meter = engine.meter()
        let peakLinear = meter?.peak ?? 0
        let decibels: Float = peakLinear > 0.000_03 ? 20 * log10(peakLinear) : -60
        let color: UIColor = decibels > -1 ? EqualizerTheme.danger : (decibels > -3 ? EqualizerTheme.caution : EqualizerTheme.lossless)
        meterBar.set(peakDecibels: decibels, color: color)
        peakLabel.text = meter == nil ? "—" : String(format: "%.1f", decibels)
        peakLabel.textColor = meter == nil ? UIColor.white.withAlphaComponent(0.42) : color
        let reduced = meter?.guardReduced ?? false
        if reduced != peakGuardActive {
            peakGuardActive = reduced
            updatePreampCaption(profile: profile)
        }
    }

    enum RulerKind {
        case frequency
        case gain
        case q
    }

    func wireRuler(_ ruler: EqualizerRulerView, kind: RulerKind) {
        ruler.onScrub = { [weak self] dx in self?.scrub(kind, by: dx) }
        ruler.onEnd = { [weak self] in self?.scrubStart = nil }
    }

    func scrub(_ kind: RulerKind, by dx: CGFloat) {
        let index = clampedSelection()
        guard profile.bands.indices.contains(index) else { return }
        if scrubStart == nil {
            let band = profile.bands[index]
            scrubStart = (band.frequency, band.gain, band.q)
        }
        guard let start = scrubStart else { return }
        engine.edit { profile in
            guard profile.bands.indices.contains(index) else { return }
            switch kind {
            case .frequency:
                profile.bands[index].frequency = EqualizerPlot.roundedFrequency(start.frequency * pow(2, Double(dx) / 110))
            case .gain:
                profile.bands[index].gain = EqualizerPlot.preciseGain(start.gain + Double(dx) / 14)
            case .q:
                let q = start.q * pow(2, Double(dx) / 140)
                profile.bands[index].q = (min(max(q, EqualizerBand.qRange.lowerBound), EqualizerBand.qRange.upperBound) * 100).rounded() / 100
            }
        }
    }
}
