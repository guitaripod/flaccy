import FlaccyCore
import UIKit

/// The equalizer: a response curve you shape with your fingers, a preamp that
/// looks after headroom, the presets, and an Advanced mode with parametric
/// bands. It is presented as a sheet over Now Playing so the record's colours
/// carry through, and everything on it reads from `EqualizerEngine`.
final class EqualizerViewController: UIViewController {

    static func makePresented() -> UINavigationController {
        let nav = UINavigationController(rootViewController: EqualizerViewController())
        nav.setNavigationBarHidden(true, animated: false)
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 38
        }
        return nav
    }

    private let engine = EqualizerEngine.shared
    private let backdrop = AmbientPaletteBackdropView()
    private let scroll = UIScrollView()
    private let stack = UIStackView()

    private let titleLabel = UILabel()
    private let enableSwitch = UISwitch()
    private let statusIcon = UIImageView()
    private let statusLabel = UILabel()
    private let outputButton = UIButton(type: .system)
    private let modeControl = UISegmentedControl(items: [String(localized: "Simple"), String(localized: "Advanced")])
    private let curveCard = UIView()
    private let curveView = EqualizerCurveView()
    private let hintLabel = UILabel()
    private lazy var curveHeight = curveView.heightAnchor.constraint(equalToConstant: Self.minimumCurveHeight)

    private static let minimumCurveHeight: CGFloat = 262
    private static let maximumCurveHeight: CGFloat = 400
    private static let holdDuration: TimeInterval = 0.18
    private static let cancelDistance: CGFloat = 70
    private static let autoscrollEdge: CGFloat = 44
    private static let accessibilityPreviewSeconds = 4.0

    private let preampValueLabel = UILabel()
    private let autoChip = EqualizerChip(title: "")
    private let meterBar = EqualizerMeterBar()
    private let peakLabel = UILabel()
    private let preampSlider = UISlider()
    private let preampCaption = UILabel()

    private let presetsBlock = UIStackView()
    private let presetsRow = UIStackView()
    private let presetsScroll = UIScrollView()
    private let presetsHintLabel = UILabel()
    private let hearingPill = EqualizerHearingPill()
    private let auditioner = EqualizerAuditioner()
    private var holdPoint = CGPoint.zero
    private var holdIsCancelling = false
    private var autoscrollLink: CADisplayLink?
    private var autoscrollSpeed: CGFloat = 0
    private var previewTimer: Task<Void, Never>?
    private var hasAnnouncedAudition = false

    private let advancedBlock = UIStackView()
    private let bandChipsRow = UIStackView()
    private let typeChipsRow = UIStackView()
    private let freqValue = UILabel()
    private let gainValue = UILabel()
    private let qValue = UILabel()
    private let freqRuler = EqualizerRulerView()
    private let gainRuler = EqualizerRulerView()
    private let qRuler = EqualizerRulerView()
    private let gainColumn = UIStackView()

    private let actionRow = UIStackView()
    private let resetCapsule = UIView()
    private let deleteCapsule = UIView()
    private let compareButton = UIButton(type: .system)
    private let saveCapsule = UIView()
    private let moreCapsule = UIView()

    private var accent: UIColor = EqualizerTheme.fallbackAccent
    private var selectedIndex = 3
    private var scrubStart: (frequency: Double, gain: Double, q: Double)?
    private var presetOrder: [String] = []
    private var presetCards: [String: EqualizerPresetCard] = [:]
    private var lastPresetStyle: String?
    private var advancedSignature = ""
    private static var builtInThumbnails: [String: [Double]] = [:]
    private var peakGuardActive = false
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let selection = UISelectionFeedbackGenerator()

    private var profile: EqualizerProfile { engine.profileInForce }
    private var mode: EqualizerCurveView.Mode { profile.kind == .graphic ? .simple : .advanced }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        buildLayout()
        curveView.delegate = self
        curveView.spectrumProvider = { [engine] in engine.spectrum() }
        curveView.onFrame = { [weak self] in self?.updateMeter() }
        auditioner.didChange = { [weak self] profile in self?.auditionChanged(to: profile) }
        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged), name: EqualizerEngine.stateDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(trackChanged), name: AudioPlayer.trackDidChange, object: nil)
        updatePalette()
        refresh(animated: false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let share: CGFloat = mode == .simple ? 0.38 : 0.34
        let target = min(max(view.bounds.height * share, Self.minimumCurveHeight), Self.maximumCurveHeight).rounded()
        if abs(curveHeight.constant - target) >= 1 { curveHeight.constant = target }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        engine.beginAnalysis(for: self)
        refresh(animated: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        endHold(keeping: false)
        endAccessibilityPreview()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        engine.endAnalysis(for: self)
        engine.endCompare()
    }

    @objc private func stateChanged() {
        refresh(animated: true)
    }

    @objc private func trackChanged() {
        updatePalette()
    }

    private func updatePalette() {
        let track = AudioPlayer.shared.currentTrack
        let key = track.map { "\($0.albumTitle)\0\($0.artist)" } ?? "flaccy"
        let seed = track.map { "\($0.title)\($0.artist)" } ?? "flaccy"
        ArtworkPaletteExtractor.palette(for: track?.artwork, cacheKey: key, fallbackSeed: seed) { [weak self] palette in
            guard let self else { return }
            self.backdrop.apply(palette, animated: true)
            self.accent = EqualizerTheme.accent(from: palette)
            self.refresh(animated: false)
        }
    }

    // MARK: Layout

    private func buildLayout() {
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
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
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
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
        stack.addArrangedSubview(makePresetsBlock())
        stack.addArrangedSubview(makeAdvancedBlock())
        stack.addArrangedSubview(makeActionRow())
    }

    private func makeHeader() -> UIView {
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

    private func makeStatusRow() -> UIView {
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

    private func makeModeControl() -> UIView {
        modeControl.selectedSegmentTintColor = UIColor.white.withAlphaComponent(0.18)
        modeControl.backgroundColor = UIColor.white.withAlphaComponent(0.07)
        modeControl.setTitleTextAttributes([.foregroundColor: UIColor.white.withAlphaComponent(0.7), .font: UIFont.scaled(.subheadline, size: 13.5, weight: .semibold)], for: .normal)
        modeControl.setTitleTextAttributes([.foregroundColor: UIColor.white, .font: UIFont.scaled(.subheadline, size: 13.5, weight: .semibold)], for: .selected)
        modeControl.addAction(UIAction { [weak self] _ in self?.modeChanged() }, for: .valueChanged)
        modeControl.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return modeControl
    }

    private func makeCurveCard() -> UIView {
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

    private func tagLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text.uppercased()
        label.font = .scaled(.caption2, size: 11, weight: .bold)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = UIColor.white.withAlphaComponent(0.42)
        return label
    }

    private func makePreampBlock() -> UIView {
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

    private func makePresetsBlock() -> UIView {
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

    private func makeAdvancedBlock() -> UIView {
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

    private func horizontalScroller(for content: UIStackView, height: CGFloat) -> UIScrollView {
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

    private func makeActionRow() -> UIView {
        var compare = UIButton.Configuration.plain()
        compare.image = UIImage(systemName: "circle.lefthalf.filled", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        compare.imagePadding = 8
        compare.baseForegroundColor = .white
        compare.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.scaled(.body, size: 15, weight: .semibold, maxSize: 19)
            return outgoing
        }
        compareButton.configuration = compare
        compareButton.addAction(UIAction { [weak self] _ in self?.beginCompare() }, for: .touchDown)
        compareButton.addAction(UIAction { [weak self] _ in self?.endCompare() }, for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        compareButton.accessibilityHint = String(localized: "Hold to hear the original without the equalizer")
        let compareCapsule = LiquidGlass.capsule(hosting: compareButton, height: 48)

        let reset = makePillButton(title: String(localized: "Reset"), symbol: "arrow.counterclockwise") { [weak self] in self?.resetToFlat() }
        let save = makePillButton(title: String(localized: "Save"), symbol: "bookmark") { [weak self] in self?.promptSave() }
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

    private func pin(_ child: UIView, in parent: UIView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        ])
    }

    private func makePillButton(title: String, symbol: String, action: @escaping () -> Void) -> UIView {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        configuration.imagePadding = 7
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        configuration.baseForegroundColor = .white
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.scaled(.body, size: 15, weight: .semibold, maxSize: 19)
            return outgoing
        }
        button.configuration = configuration
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return LiquidGlass.capsule(hosting: button, height: 48)
    }

    private func makeIconButton(symbol: String, label: String, tint: UIColor, action: @escaping () -> Void) -> UIView {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        button.tintColor = tint
        button.accessibilityLabel = label
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return LiquidGlass.capsule(hosting: button, height: 48)
    }

    private func makeMoreButton() -> UIView {
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

    private func moreMenuActions() -> [UIMenuElement] {
        [
            UIAction(title: String(localized: "Import from Text…"), image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in self?.openImport() },
            UIAction(title: String(localized: "Export as Text"), image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.exportProfile() },
            UIAction(title: String(localized: "Save as Preset…"), image: UIImage(systemName: "bookmark")) { [weak self] _ in self?.promptSave() },
            UIAction(title: String(localized: "Reset All Bands"), image: UIImage(systemName: "arrow.counterclockwise"), attributes: .destructive) { [weak self] _ in self?.resetToFlat() },
        ]
    }

    // MARK: Refresh

    private func refresh(animated: Bool) {
        guard isViewLoaded else { return }
        let profile = profile
        let state = engine.state
        let running = state.isEnabled && !engine.isOutputBoundToOff
        let kind = profile.kind

        enableSwitch.setOn(running, animated: animated)
        enableSwitch.onTintColor = accent
        modeControl.selectedSegmentIndex = kind == .graphic ? 0 : 1

        var content = EqualizerCurveView.Content()
        content.mode = mode
        content.targets = profile.targets
        content.bands = profile.bands.map { $0.clamped() }
        content.selectedIndex = clampedSelection()
        content.isEnabled = running
        content.isComparing = engine.isComparing
        content.accent = accent
        curveView.update(content, animated: animated)

        presetsBlock.isHidden = mode != .simple
        advancedBlock.isHidden = mode != .advanced
        resetCapsule.isHidden = mode != .simple
        saveCapsule.isHidden = mode != .simple
        deleteCapsule.isHidden = mode != .advanced
        moreCapsule.isHidden = mode != .advanced
        hintLabel.text = mode == .simple
            ? String(localized: "Drag a point · double-tap or tap its label to reset")
            : String(localized: "Drag a node · pinch to change Q · double-tap empty space to add a band")

        updateStatus(profile: profile, running: running)
        updatePreamp(profile: profile)
        updateOutputButton()
        if mode == .simple { updatePresets(profile: profile) } else { updateAdvanced(profile: profile) }
        updateCompareTitle()
    }

    private func clampedSelection() -> Int {
        let count = mode == .simple ? GraphicSolver.centres.count : max(profile.bands.count, 1)
        selectedIndex = min(max(selectedIndex, 0), count - 1)
        return selectedIndex
    }

    private func updateStatus(profile: EqualizerProfile, running: Bool) {
        let status: EqualizerCopy.Status
        if !running {
            status = .off
        } else if engine.isComparing {
            status = .comparing
        } else if profile.isFlat {
            status = .flat
        } else {
            status = .processing
        }
        let color: UIColor
        let symbol: String
        switch status {
        case .off, .flat:
            color = EqualizerTheme.lossless
            symbol = "checkmark.circle"
        case .processing:
            color = accent
            symbol = "waveform"
        case .comparing:
            color = EqualizerTheme.caution
            symbol = "circle.lefthalf.filled"
        }
        statusLabel.text = EqualizerCopy.status(status)
        statusLabel.textColor = color
        statusIcon.tintColor = color
        statusIcon.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        statusLabel.accessibilityLabel = EqualizerCopy.status(status)
    }

    private func updatePreamp(profile: EqualizerProfile) {
        let preamp = profile.preamp()
        preampValueLabel.text = "\(EqualizerCopy.decibels(preamp)) dB"
        autoChip.set(title: profile.isAutoPreamp ? String(localized: "Auto") : String(localized: "Manual"), active: profile.isAutoPreamp, tint: accent)
        preampSlider.minimumTrackTintColor = profile.isAutoPreamp ? accent.withAlphaComponent(0.55) : accent
        if !preampSlider.isTracking { preampSlider.value = Float(preamp) }
        preampSlider.accessibilityValue = "\(EqualizerCopy.decibels(preamp)) dB"
        updatePreampCaption(profile: profile)
    }

    private func updatePreampCaption(profile: EqualizerProfile) {
        if peakGuardActive {
            preampCaption.text = String(localized: "Peak guard is catching overs. Lower the preamp or return to Auto.")
            preampCaption.textColor = EqualizerTheme.caution
        } else if profile.isAutoPreamp {
            preampCaption.text = String(localized: "Headroom is set for you, so boosts never clip. Drag to take over.")
            preampCaption.textColor = UIColor.white.withAlphaComponent(0.42)
        } else {
            preampCaption.text = String(localized: "Manual preamp. Return to Auto and Flaccy sets it from the curve.")
            preampCaption.textColor = UIColor.white.withAlphaComponent(0.42)
        }
    }

    private func updateOutputButton() {
        var configuration = outputButton.configuration ?? UIButton.Configuration.plain()
        let output = engine.output
        configuration.title = output?.name ?? String(localized: "Output")
        let symbol: String
        switch output?.kind {
        case .headphones: symbol = "headphones"
        case .bluetooth: symbol = "airpods.pro"
        case .airPlay: symbol = "airplayaudio"
        case .usb: symbol = "cable.connector"
        case .display: symbol = "tv"
        case .car: symbol = "car"
        default: symbol = "iphone"
        }
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        outputButton.configuration = configuration
        outputButton.accessibilityLabel = String(localized: "Output \(output?.name ?? String(localized: "Speaker"))")
        outputButton.accessibilityHint = String(localized: "Choose the profile for this output")
    }

    private func updatePresets(profile: EqualizerProfile) {
        let candidates = engine.state.userProfiles + EqualizerPresets.all
        let order = candidates.map(\.id)
        if order != presetOrder {
            presetsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
            presetCards.removeAll()
            for candidate in candidates {
                let card = EqualizerPresetCard()
                card.addAction(UIAction { [weak self] _ in
                    self?.impact.impactOccurred()
                    self?.engine.select(profileID: candidate.id)
                }, for: .touchUpInside)
                card.onPreviewRequested = { [weak self] in self?.previewForAccessibility(candidate) }
                presetCards[candidate.id] = card
                presetsRow.addArrangedSubview(card)
            }
            presetOrder = order
            lastPresetStyle = nil
        }
        let style = "\(profile.id)|\(accent.hash)"
        let currentChanged = style != lastPresetStyle
        for candidate in candidates {
            guard let card = presetCards[candidate.id] else { continue }
            let isCurrent = candidate.id == profile.id
            guard currentChanged || isCurrent else { continue }
            card.configure(
                name: EqualizerCopy.name(of: candidate),
                points: thumbnail(for: candidate),
                isCurrent: isCurrent,
                tint: accent
            )
            card.setHeld(auditioner.current?.id == candidate.id && !holdIsCancelling, animated: false)
        }
        if currentChanged, let card = presetCards[profile.id] {
            lastPresetStyle = style
            view.layoutIfNeeded()
            let target = card.frame.insetBy(dx: -24, dy: 0)
            presetsScroll.scrollRectToVisible(target, animated: lastPresetStyle != nil && isViewLoaded && view.window != nil)
        }
    }

    @objc private func handleHold(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            endAccessibilityPreview()
            setScrolling(enabled: false)
            holdIsCancelling = false
            selection.prepare()
            trackHold(at: gesture.location(in: presetsBlock))
        case .changed:
            trackHold(at: gesture.location(in: presetsBlock))
        case .ended:
            endHold(keeping: !holdIsCancelling)
        case .cancelled, .failed:
            endHold(keeping: false)
        default:
            break
        }
    }

    /// Follows the finger: switches the audition to the card under it, and flips to the
    /// cancelling state once it has slid far enough off the strip.
    private func trackHold(at point: CGPoint) {
        holdPoint = point
        let local = presetsScroll.convert(point, from: presetsBlock)
        let overshoot = max(-local.y, local.y - presetsScroll.bounds.height, 0)
        let cancelling = overshoot > Self.cancelDistance
        if cancelling != holdIsCancelling {
            holdIsCancelling = cancelling
            if cancelling { impact.impactOccurred(intensity: 0.7) } else { selection.selectionChanged() }
            refreshAuditionFeedback()
        }
        if !cancelling, let id = presetID(atContentX: local.x), id != auditioner.current?.id,
           let candidate = engine.allProfiles.first(where: { $0.id == id }) {
            selection.selectionChanged()
            auditioner.begin(candidate)
        }
        updateAutoscroll(visibleX: local.x - presetsScroll.contentOffset.x)
    }

    private func presetID(atContentX x: CGFloat) -> String? {
        let cards = presetsRow.arrangedSubviews
        let half = presetsRow.spacing / 2
        guard let hit = cards.first(where: { x < $0.frame.maxX + half }) ?? cards.last else { return nil }
        return presetCards.first(where: { $0.value === hit })?.key
    }

    private func setScrolling(enabled: Bool) {
        presetsScroll.isScrollEnabled = enabled
        scroll.isScrollEnabled = enabled
        navigationController?.isModalInPresentation = !enabled
    }

    /// Ends a hold, keeping the heard preset as one change when asked to, and always
    /// putting the sound back to what was in force otherwise.
    private func endHold(keeping: Bool) {
        stopAutoscroll()
        let kept = keeping ? auditioner.current : nil
        setScrolling(enabled: true)
        holdIsCancelling = false
        if let kept {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            engine.select(profileID: kept.id)
        }
        auditioner.end()
    }

    private func auditionChanged(to profile: EqualizerProfile?) {
        curveView.setPreview(profile?.resolvedBands())
        refreshAuditionFeedback()
        guard let profile else {
            hasAnnouncedAudition = false
            return
        }
        guard !hasAnnouncedAudition else { return }
        hasAnnouncedAudition = true
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Hearing \(EqualizerCopy.name(of: profile))"))
    }

    private func refreshAuditionFeedback() {
        let profile = auditioner.current
        hearingPill.set(name: profile.map { EqualizerCopy.name(of: $0) }, cancelling: holdIsCancelling, accent: accent)
        for (id, card) in presetCards {
            card.setHeld(id == profile?.id && !holdIsCancelling, animated: true)
        }
    }

    private func updateAutoscroll(visibleX: CGFloat) {
        let edge = Self.autoscrollEdge
        let width = presetsScroll.bounds.width
        if visibleX < edge {
            autoscrollSpeed = -min((edge - visibleX) / edge, 1.5) * 12
        } else if visibleX > width - edge {
            autoscrollSpeed = min((visibleX - (width - edge)) / edge, 1.5) * 12
        } else {
            autoscrollSpeed = 0
        }
        if autoscrollSpeed != 0, autoscrollLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(autoscrollTick))
            link.add(to: .main, forMode: .common)
            autoscrollLink = link
        } else if autoscrollSpeed == 0 {
            stopAutoscroll()
        }
    }

    private func stopAutoscroll() {
        autoscrollLink?.invalidate()
        autoscrollLink = nil
        autoscrollSpeed = 0
    }

    @objc private func autoscrollTick() {
        let maximum = max(presetsScroll.contentSize.width - presetsScroll.bounds.width, 0)
        let offset = min(max(presetsScroll.contentOffset.x + autoscrollSpeed, 0), maximum)
        guard offset != presetsScroll.contentOffset.x else { return }
        presetsScroll.contentOffset.x = offset
        trackHold(at: holdPoint)
    }

    /// VoiceOver cannot hold and slide, so its Preview action plays the preset for a few
    /// seconds and puts the sound back.
    private func previewForAccessibility(_ profile: EqualizerProfile) {
        endAccessibilityPreview()
        auditioner.begin(profile)
        previewTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.accessibilityPreviewSeconds))
            guard !Task.isCancelled else { return }
            self?.previewTimer = nil
            self?.auditioner.end()
        }
    }

    private func endAccessibilityPreview() {
        guard previewTimer != nil else { return }
        previewTimer?.cancel()
        previewTimer = nil
        auditioner.end()
    }

    #if DEBUG
    /// Puts the screen in the state a held finger leaves it in, for the screenshot routes.
    func showAuditionForScreenshot(presetKey: String, cancelling: Bool) {
        guard let profile = EqualizerPresets.profile(forKey: presetKey) else { return }
        view.layoutIfNeeded()
        holdIsCancelling = cancelling
        auditioner.begin(profile)
        if let card = presetCards[profile.id] {
            presetsScroll.scrollRectToVisible(card.frame.insetBy(dx: -24, dy: 0), animated: false)
        }
    }
    #endif

    private func thumbnail(for profile: EqualizerProfile) -> [Double] {
        if profile.isBuiltIn, let cached = Self.builtInThumbnails[profile.id] { return cached }
        let points = BiquadMath.curve(profile.resolvedBands(), points: 40)
        if profile.isBuiltIn { Self.builtInThumbnails[profile.id] = points }
        return points
    }

    private func updateAdvanced(profile: EqualizerProfile) {
        let selected = clampedSelection()
        guard profile.bands.indices.contains(selected) else { return }
        let signature = "\(selected)|\(profile.bands.count)|\(profile.bands[selected].type.rawValue)|\(accent.hash)"
        if signature != advancedSignature {
            advancedSignature = signature
            rebuildAdvancedChips(profile: profile, selected: selected)
        }
        updateAdvancedValues(profile: profile, selected: selected)
    }

    private func rebuildAdvancedChips(profile: EqualizerProfile, selected: Int) {
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

    private func updateAdvancedValues(profile: EqualizerProfile, selected: Int) {
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

    private func updateCompareTitle() {
        var configuration = compareButton.configuration
        configuration?.title = engine.isComparing ? String(localized: "Hearing original") : String(localized: "Hold to compare")
        configuration?.baseForegroundColor = engine.isComparing ? EqualizerTheme.caution : .white
        compareButton.configuration = configuration
    }

    private func updateMeter() {
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

    // MARK: Actions

    private func toggleEnabled() {
        impact.impactOccurred()
        engine.setEnabled(enableSwitch.isOn)
    }

    private func modeChanged() {
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

    private func toggleAutoPreamp() {
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

    private func preampSliderMoved() {
        let value = (Double(preampSlider.value) * 2).rounded() / 2
        if value != Double(preampSlider.value) { preampSlider.value = Float(value) }
        selection.selectionChanged()
        engine.edit { profile in
            profile.isAutoPreamp = false
            profile.manualPreamp = value
        }
    }

    private func beginCompare() {
        impact.impactOccurred()
        engine.beginCompare()
        refresh(animated: false)
    }

    private func endCompare() {
        guard engine.isComparing else { return }
        impact.impactOccurred()
        engine.endCompare()
        refresh(animated: false)
    }

    private func resetToFlat() {
        impact.impactOccurred()
        engine.select(profileID: EqualizerProfile.flatID)
        selectedIndex = 3
    }

    private func setType(_ type: EqualizerFilterType) {
        let index = clampedSelection()
        selection.selectionChanged()
        engine.edit { profile in
            guard profile.bands.indices.contains(index) else { return }
            profile.bands[index].type = type
            profile.bands[index].q = type.defaultQ
            if !type.hasGain { profile.bands[index].gain = 0 }
        }
    }

    private func deleteSelectedBand() {
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

    private func addBand(frequency: Double, gain: Double) {
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

    private func promptSave() {
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

    private func exportProfile() {
        let text = engine.exportText(for: profile)
        let activity = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = moreCapsule
        present(activity, animated: true)
    }

    private func openPresets() {
        navigationController?.pushViewController(EqualizerPresetsViewController(startingOn: .presets, accent: accent), animated: true)
    }

    private func openOutputs() {
        navigationController?.pushViewController(EqualizerPresetsViewController(startingOn: .outputs, accent: accent), animated: true)
    }

    private func openImport() {
        navigationController?.pushViewController(EqualizerImportViewController(accent: accent), animated: true)
    }

    private enum RulerKind {
        case frequency
        case gain
        case q
    }

    private func wireRuler(_ ruler: EqualizerRulerView, kind: RulerKind) {
        ruler.onScrub = { [weak self] dx in self?.scrub(kind, by: dx) }
        ruler.onEnd = { [weak self] in self?.scrubStart = nil }
    }

    private func scrub(_ kind: RulerKind, by dx: CGFloat) {
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

    private func refreshAdvancedValues() {
        guard mode == .advanced else { return }
        updateAdvanced(profile: profile)
    }
}
