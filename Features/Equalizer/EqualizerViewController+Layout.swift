import FlaccyCore
import UIKit

extension EqualizerViewController {

    func buildLayout() {
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = false
        view.addSubview(scroll)

        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -40),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])

        stack.addArrangedSubview(makeHeader())
        stack.addArrangedSubview(makeStatusRow())
        stack.addArrangedSubview(makeModeControl())
        stack.addArrangedSubview(makeCurveCard())
        stack.addArrangedSubview(makePreampBlock())
        stack.addArrangedSubview(makeDescribeRow())
        stack.addArrangedSubview(makePresetsBlock())
        stack.addArrangedSubview(makeAdvancedBlock())
        stack.addArrangedSubview(makeActionRow())
    }

    func makeHeader() -> UIView {
        titleLabel.text = EqualizerCopy.title
        titleLabel.font = .equalizerRounded(.largeTitle, size: 30, weight: .bold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.accessibilityTraits = .header
        enableSwitch.addAction(UIAction { [weak self] _ in self?.toggleEnabled() }, for: .valueChanged)
        enableSwitch.accessibilityLabel = EqualizerCopy.title
        let row = UIStackView(arrangedSubviews: [titleLabel, UIView(), enableSwitch])
        row.alignment = .center
        return row
    }

    func makeStatusRow() -> UIView {
        statusIcon.contentMode = .scaleAspectFit
        statusIcon.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.font = .scaled(.footnote, size: 13, weight: .semibold)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 2
        let status = UIStackView(arrangedSubviews: [statusIcon, statusLabel])
        status.spacing = 7
        status.alignment = .center

        var configuration = UIButton.Configuration.plain()
        configuration.imagePadding = 6
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 11, bottom: 5, trailing: 11)
        configuration.baseForegroundColor = .white
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.scaled(.footnote, size: 12.5, weight: .semibold)
            return outgoing
        }
        outputButton.configuration = configuration
        outputButton.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        outputButton.layer.cornerRadius = 15
        outputButton.layer.cornerCurve = .continuous
        outputButton.layer.borderWidth = 1
        outputButton.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        outputButton.addAction(UIAction { [weak self] _ in self?.openOutputs() }, for: .touchUpInside)
        outputButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        outputButton.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [status, UIView(), outputButton])
        row.alignment = .center
        row.spacing = 10
        return row
    }

    func makeModeControl() -> UIView {
        modeControl.selectedSegmentTintColor = UIColor.white.withAlphaComponent(0.18)
        modeControl.backgroundColor = UIColor.white.withAlphaComponent(0.07)
        modeControl.setTitleTextAttributes([.foregroundColor: UIColor.white.withAlphaComponent(0.7), .font: UIFont.scaled(.subheadline, size: 13.5, weight: .semibold)], for: .normal)
        modeControl.setTitleTextAttributes([.foregroundColor: UIColor.white, .font: UIFont.scaled(.subheadline, size: 13.5, weight: .semibold)], for: .selected)
        modeControl.addAction(UIAction { [weak self] _ in self?.modeChanged() }, for: .valueChanged)
        modeControl.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return modeControl
    }

    func makeCurveCard() -> UIView {
        curveCard.layer.cornerRadius = 28
        curveCard.layer.cornerCurve = .continuous
        curveCard.clipsToBounds = true
        curveCard.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        curveCard.layer.borderWidth = 1
        curveCard.layer.borderColor = UIColor.white.withAlphaComponent(0.1).cgColor

        curveView.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = .scaled(.caption1, size: 11.5, weight: .regular)
        hintLabel.adjustsFontForContentSizeCategory = true
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.42)
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 2
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hearingPill.translatesAutoresizingMaskIntoConstraints = false
        curveCard.addSubview(curveView)
        curveCard.addSubview(hintLabel)
        curveCard.addSubview(hearingPill)
        NSLayoutConstraint.activate([
            hearingPill.topAnchor.constraint(equalTo: curveCard.topAnchor, constant: 12),
            hearingPill.trailingAnchor.constraint(equalTo: curveCard.trailingAnchor, constant: -12),
            hearingPill.leadingAnchor.constraint(greaterThanOrEqualTo: curveCard.leadingAnchor, constant: 12),
            curveView.topAnchor.constraint(equalTo: curveCard.topAnchor),
            curveView.leadingAnchor.constraint(equalTo: curveCard.leadingAnchor),
            curveView.trailingAnchor.constraint(equalTo: curveCard.trailingAnchor),
            curveHeight,
            hintLabel.topAnchor.constraint(equalTo: curveView.bottomAnchor, constant: -4),
            hintLabel.leadingAnchor.constraint(equalTo: curveCard.leadingAnchor, constant: 12),
            hintLabel.trailingAnchor.constraint(equalTo: curveCard.trailingAnchor, constant: -12),
            hintLabel.bottomAnchor.constraint(equalTo: curveCard.bottomAnchor, constant: -12),
        ])
        return curveCard
    }

    func tagLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text.uppercased()
        label.font = .scaled(.caption2, size: 11, weight: .bold)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = UIColor.white.withAlphaComponent(0.42)
        return label
    }

    func makePreampBlock() -> UIView {
        preampValueLabel.font = .equalizerRounded(.headline, size: 17, weight: .bold)
        preampValueLabel.adjustsFontForContentSizeCategory = true
        preampValueLabel.textColor = .white
        autoChip.addAction(UIAction { [weak self] _ in self?.toggleAutoPreamp() }, for: .touchUpInside)

        peakLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        peakLabel.textAlignment = .right
        peakLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        peakLabel.isAccessibilityElement = false

        let left = UIStackView(arrangedSubviews: [tagLabel(String(localized: "Preamp")), preampValueLabel, autoChip])
        left.spacing = 10
        left.alignment = .center
        let right = UIStackView(arrangedSubviews: [tagLabel(String(localized: "Peak")), meterBar, peakLabel])
        right.spacing = 8
        right.alignment = .center
        let top = UIStackView(arrangedSubviews: [left, UIView(), right])
        top.alignment = .center

        preampSlider.minimumValue = Float(EqualizerProfile.preampRange.lowerBound)
        preampSlider.maximumValue = Float(EqualizerProfile.preampRange.upperBound)
        preampSlider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.14)
        preampSlider.accessibilityLabel = String(localized: "Preamp")
        preampSlider.addAction(UIAction { [weak self] _ in self?.preampSliderMoved() }, for: .valueChanged)
        preampSlider.addAction(UIAction { [weak self] _ in self?.selection.prepare() }, for: .touchDown)

        preampCaption.font = .scaled(.caption1, size: 11.5, weight: .regular)
        preampCaption.adjustsFontForContentSizeCategory = true
        preampCaption.numberOfLines = 0

        let block = UIStackView(arrangedSubviews: [top, preampSlider, preampCaption])
        block.axis = .vertical
        block.spacing = 6
        block.isLayoutMarginsRelativeArrangement = true
        block.layoutMargins = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        return block
    }

    func makePresetsBlock() -> UIView {
        let allButton = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.title = String(localized: "All presets")
        configuration.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 4
        configuration.contentInsets = .zero
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.scaled(.subheadline, size: 13, weight: .semibold)
            return outgoing
        }
        allButton.configuration = configuration
        allButton.tintColor = accent
        allButton.addAction(UIAction { [weak self] _ in self?.openPresets() }, for: .touchUpInside)
        allButton.accessibilityIdentifier = "equalizer.allPresets"

        presetsHintLabel.text = String(localized: "Hold and slide to hear them")
        presetsHintLabel.font = .scaled(.caption1, size: 11.5, weight: .regular)
        presetsHintLabel.adjustsFontForContentSizeCategory = true
        presetsHintLabel.textColor = UIColor.white.withAlphaComponent(0.42)
        presetsHintLabel.numberOfLines = 0
        let titles = UIStackView(arrangedSubviews: [tagLabel(String(localized: "Presets")), presetsHintLabel])
        titles.axis = .vertical
        titles.spacing = 2

        let header = UIStackView(arrangedSubviews: [titles, UIView(), allButton])
        header.alignment = .center
        header.isLayoutMarginsRelativeArrangement = true
        header.layoutMargins = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)

        presetsRow.axis = .horizontal
        presetsRow.spacing = 8
        presetsRow.alignment = .fill
        presetsRow.translatesAutoresizingMaskIntoConstraints = false
        presetsScroll.translatesAutoresizingMaskIntoConstraints = false
        presetsScroll.showsHorizontalScrollIndicator = false
        presetsScroll.clipsToBounds = false
        presetsScroll.addSubview(presetsRow)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
        hold.minimumPressDuration = Self.holdDuration
        hold.allowableMovement = 10_000
        presetsScroll.addGestureRecognizer(hold)
        NSLayoutConstraint.activate([
            presetsRow.topAnchor.constraint(equalTo: presetsScroll.contentLayoutGuide.topAnchor),
            presetsRow.bottomAnchor.constraint(equalTo: presetsScroll.contentLayoutGuide.bottomAnchor),
            presetsRow.leadingAnchor.constraint(equalTo: presetsScroll.contentLayoutGuide.leadingAnchor),
            presetsRow.trailingAnchor.constraint(equalTo: presetsScroll.contentLayoutGuide.trailingAnchor),
            presetsRow.heightAnchor.constraint(equalTo: presetsScroll.frameLayoutGuide.heightAnchor),
            presetsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: EqualizerPresetCard.size.height),
        ])

        presetsBlock.axis = .vertical
        presetsBlock.spacing = 10
        presetsBlock.addArrangedSubview(header)
        presetsBlock.addArrangedSubview(presetsScroll)
        return presetsBlock
    }

    /// The way into Describe the Sound: a row that reads as a field waiting for a sentence.
    func makeDescribeRow() -> UIView {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.title = EqualizerDescribeCopy.menuTitle
        configuration.image = UIImage(systemName: "wand.and.stars", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        configuration.imagePadding = 10
        configuration.baseForegroundColor = UIColor.white.withAlphaComponent(0.86)
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.scaled(.body, size: 15, weight: .semibold, maxSize: 19)
            return outgoing
        }
        button.configuration = configuration
        button.contentHorizontalAlignment = .leading
        button.accessibilityIdentifier = "equalizer.describe"
        button.addAction(UIAction { [weak self] _ in self?.openDescribe() }, for: .touchUpInside)
        return LiquidGlass.capsule(hosting: button, height: 48)
    }

    func makeAdvancedBlock() -> UIView {
        bandChipsRow.axis = .horizontal
        bandChipsRow.spacing = 8
        bandChipsRow.alignment = .center
        typeChipsRow.axis = .horizontal
        typeChipsRow.spacing = 6
        typeChipsRow.alignment = .center

        let chipsScroll = horizontalScroller(for: bandChipsRow, height: 38)
        let typeScroll = horizontalScroller(for: typeChipsRow, height: 32)

        func column(tag: String, value: UILabel, ruler: EqualizerRulerView) -> UIStackView {
            value.font = .equalizerRounded(.title3, size: 19, weight: .bold)
            value.adjustsFontForContentSizeCategory = true
            value.textColor = .white
            value.adjustsFontSizeToFitWidth = true
            value.minimumScaleFactor = 0.7
            ruler.pointerColor = accent
            let column = UIStackView(arrangedSubviews: [tagLabel(tag), value, ruler])
            column.axis = .vertical
            column.spacing = 4
            return column
        }
        let freq = column(tag: String(localized: "Freq"), value: freqValue, ruler: freqRuler)
        let gain = column(tag: String(localized: "Gain"), value: gainValue, ruler: gainRuler)
        let q = column(tag: String(localized: "Q"), value: qValue, ruler: qRuler)
        gainColumn.axis = .vertical
        gainColumn.addArrangedSubview(gain)
        let rulers = UIStackView(arrangedSubviews: [freq, gainColumn, q])
        rulers.spacing = 14
        rulers.distribution = .fillEqually
        rulers.alignment = .top

        freqRuler.accessibilityLabel = String(localized: "Frequency")
        gainRuler.accessibilityLabel = String(localized: "Gain")
        qRuler.accessibilityLabel = String(localized: "Q")
        wireRuler(freqRuler, kind: .frequency)
        wireRuler(gainRuler, kind: .gain)
        wireRuler(qRuler, kind: .q)

        advancedBlock.axis = .vertical
        advancedBlock.spacing = 12
        advancedBlock.addArrangedSubview(chipsScroll)
        advancedBlock.addArrangedSubview(typeScroll)
        advancedBlock.addArrangedSubview(rulers)
        return advancedBlock
    }

    func horizontalScroller(for content: UIStackView, height: CGFloat) -> UIScrollView {
        let scroller = UIScrollView()
        scroller.translatesAutoresizingMaskIntoConstraints = false
        scroller.showsHorizontalScrollIndicator = false
        scroller.clipsToBounds = false
        content.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            content.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor),
            scroller.heightAnchor.constraint(equalToConstant: height),
        ])
        return scroller
    }

    func makeActionRow() -> UIView {
        var compare = UIButton.Configuration.plain()
        compare.image = UIImage(systemName: "circle.lefthalf.filled", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        compare.imagePadding = 8
        compare.baseForegroundColor = .white
        compare.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        compare.titleLineBreakMode = .byTruncatingTail
        compare.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.scaled(.body, size: 15, weight: .semibold, maxSize: 19)
            return outgoing
        }
        compareButton.configuration = compare
        yieldWidth(of: compareButton)
        compareButton.addAction(UIAction { [weak self] _ in self?.beginCompare() }, for: .touchDown)
        compareButton.addAction(UIAction { [weak self] _ in self?.endCompare() }, for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        compareButton.accessibilityHint = String(localized: "Hold to hear the original without the equalizer")
        let compareCapsule = LiquidGlass.capsule(hosting: compareButton, height: 48)

        let reset = makePillButton(resetButton, title: Self.resetTitle, symbol: "arrow.counterclockwise") { [weak self] in self?.resetToFlat() }
        let save = makePillButton(saveButton, title: Self.saveTitle, symbol: "bookmark") { [weak self] in self?.promptSave() }
        resetButton.accessibilityLabel = Self.resetTitle
        saveButton.accessibilityLabel = Self.saveTitle
        let delete = makeIconButton(symbol: "trash", label: String(localized: "Delete band"), tint: EqualizerTheme.danger) { [weak self] in self?.deleteSelectedBand() }
        let more = makeMoreButton()
        resetCapsule.addSubview(reset); pin(reset, in: resetCapsule)
        saveCapsule.addSubview(save); pin(save, in: saveCapsule)
        deleteCapsule.addSubview(delete); pin(delete, in: deleteCapsule)
        moreCapsule.addSubview(more); pin(more, in: moreCapsule)

        actionRow.axis = .horizontal
        actionRow.spacing = 8
        actionRow.alignment = .fill
        actionRow.distribution = .fill
        for capsule in [resetCapsule, deleteCapsule, saveCapsule, moreCapsule] {
            capsule.translatesAutoresizingMaskIntoConstraints = false
        }
        resetCapsule.heightAnchor.constraint(equalToConstant: 48).isActive = true
        saveCapsule.heightAnchor.constraint(equalToConstant: 48).isActive = true
        deleteCapsule.widthAnchor.constraint(equalToConstant: 48).isActive = true
        moreCapsule.widthAnchor.constraint(equalToConstant: 48).isActive = true
        compareCapsule.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for capsule in [resetCapsule, saveCapsule] { capsule.setContentHuggingPriority(.required, for: .horizontal) }
        for view in [resetCapsule, deleteCapsule, compareCapsule, saveCapsule, moreCapsule] {
            actionRow.addArrangedSubview(view)
        }
        return actionRow
    }

    static var resetTitle: String { String(localized: "Reset") }
    static var saveTitle: String { String(localized: "Save") }
    static let actionFont = UIFont.scaled(.body, size: 15, weight: .semibold, maxSize: 19)
    static let smallestCompareScale: CGFloat = 0.75
    /// How far the compare title may shrink before a pill gives up its word. Kept above the smallest scale the
    /// label takes, so a title that only just fits on paper is not cut short on screen.
    static let plannedCompareScale: CGFloat = 0.85

    /// Makes the compare button the one that gives way when the row is too wide for the screen: its title
    /// shrinks, then shortens, so the pills beside it keep their words on one line. A configured button resets
    /// its label on every update, so the label is set up again each time.
    func yieldWidth(of button: UIButton) {
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.configurationUpdateHandler = { button in
            button.titleLabel?.numberOfLines = 1
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = Self.smallestCompareScale
        }
    }

    /// Keeps Reset, the compare button and Save on one row in every language. When the three do not fit with
    /// their words, even with the compare title somewhat smaller, Reset keeps only its arrow, and when that is
    /// not enough Save keeps only its bookmark. Both symbols read on their own, and VoiceOver hears the words
    /// either way.
    func fitActionRow() {
        let width = actionRow.bounds.width
        guard width > 0, !resetCapsule.isHidden else { return }
        let compareTitle = compareButton.configuration?.title ?? ""
        let smallestCompare = compareButton.intrinsicContentSize.width - Self.width(of: compareTitle) * (1 - Self.plannedCompareScale)
        let resetWord = wordWidth(of: resetButton, Self.resetTitle)
        let saveWord = wordWidth(of: saveButton, Self.saveTitle)
        let room = width - smallestCompare - actionRow.spacing * 2
            - (resetButton.intrinsicContentSize.width - (resetButton.configuration?.title == nil ? 0 : resetWord))
            - (saveButton.intrinsicContentSize.width - (saveButton.configuration?.title == nil ? 0 : saveWord))
        show(room >= resetWord + saveWord ? Self.resetTitle : nil, on: resetButton)
        show(room >= saveWord ? Self.saveTitle : nil, on: saveButton)
    }

    /// The width a pill's word adds beside its symbol.
    private func wordWidth(of button: UIButton, _ word: String) -> CGFloat {
        Self.width(of: word) + (button.configuration?.imagePadding ?? 0)
    }

    private func show(_ word: String?, on button: UIButton) {
        guard button.configuration?.title != word else { return }
        button.configuration?.title = word
    }

    private static func width(of title: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: actionFont]).width)
    }

    func pin(_ child: UIView, in parent: UIView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        ])
    }

    func makePillButton(_ button: UIButton, title: String, symbol: String, action: @escaping () -> Void) -> UIView {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        configuration.imagePadding = 7
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)
        configuration.baseForegroundColor = .white
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.scaled(.body, size: 15, weight: .semibold, maxSize: 19)
            return outgoing
        }
        button.configuration = configuration
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return LiquidGlass.capsule(hosting: button, height: 48)
    }

    func makeIconButton(symbol: String, label: String, tint: UIColor, action: @escaping () -> Void) -> UIView {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        button.tintColor = tint
        button.accessibilityLabel = label
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return LiquidGlass.capsule(hosting: button, height: 48)
    }

    func makeMoreButton() -> UIView {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        button.tintColor = .white
        button.accessibilityLabel = String(localized: "More")
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.moreMenuActions() ?? [])
            },
        ])
        return LiquidGlass.capsule(hosting: button, height: 48)
    }

    func moreMenuActions() -> [UIMenuElement] {
        [
            UIAction(title: EqualizerDescribeCopy.menuTitle, image: UIImage(systemName: "wand.and.stars")) { [weak self] _ in self?.openDescribe() },
            UIAction(title: String(localized: "Import from Text…"), image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in self?.openImport() },
            UIAction(title: String(localized: "Export as Text"), image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.exportProfile() },
            UIAction(title: String(localized: "Save as Preset…"), image: UIImage(systemName: "bookmark")) { [weak self] _ in self?.promptSave() },
            UIAction(title: String(localized: "Reset All Bands"), image: UIImage(systemName: "arrow.counterclockwise"), attributes: .destructive) { [weak self] _ in self?.resetToFlat() },
        ]
    }
}
