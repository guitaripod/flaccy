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

    let engine = EqualizerEngine.shared
    let backdrop = AmbientPaletteBackdropView()
    let scroll = UIScrollView()
    let stack = UIStackView()

    let titleLabel = UILabel()
    let enableSwitch = UISwitch()
    let statusIcon = UIImageView()
    let statusLabel = UILabel()
    let outputButton = UIButton(type: .system)
    let modeControl = UISegmentedControl(items: [String(localized: "Simple"), String(localized: "Advanced")])
    let curveCard = UIView()
    let curveView = EqualizerCurveView()
    let hintLabel = UILabel()
    lazy var curveHeight = curveView.heightAnchor.constraint(equalToConstant: Self.minimumCurveHeight)

    static let minimumCurveHeight: CGFloat = 262
    static let maximumCurveHeight: CGFloat = 400
    static let holdDuration: TimeInterval = 0.18
    static let cancelDistance: CGFloat = 70
    static let autoscrollEdge: CGFloat = 44
    static let accessibilityPreviewSeconds = 4.0

    let preampValueLabel = UILabel()
    let autoChip = EqualizerChip(title: "")
    let meterBar = EqualizerMeterBar()
    let peakLabel = UILabel()
    let preampSlider = UISlider()
    let preampCaption = UILabel()

    let presetsBlock = UIStackView()
    let presetsRow = UIStackView()
    let presetsScroll = UIScrollView()
    let presetsHintLabel = UILabel()
    let hearingPill = EqualizerHearingPill()
    let auditioner = EqualizerAuditioner()
    var holdPoint = CGPoint.zero
    var holdIsCancelling = false
    var autoscrollLink: CADisplayLink?
    var autoscrollSpeed: CGFloat = 0
    var previewTimer: Task<Void, Never>?
    var hasAnnouncedAudition = false

    let advancedBlock = UIStackView()
    let bandChipsRow = UIStackView()
    let typeChipsRow = UIStackView()
    let freqValue = UILabel()
    let gainValue = UILabel()
    let qValue = UILabel()
    let freqRuler = EqualizerRulerView()
    let gainRuler = EqualizerRulerView()
    let qRuler = EqualizerRulerView()
    let gainColumn = UIStackView()

    let actionRow = UIStackView()
    let resetCapsule = UIView()
    let deleteCapsule = UIView()
    let compareButton = UIButton(type: .system)
    let saveCapsule = UIView()
    let moreCapsule = UIView()

    var accent: UIColor = EqualizerTheme.fallbackAccent
    var selectedIndex = 3
    var scrubStart: (frequency: Double, gain: Double, q: Double)?
    var presetOrder: [String] = []
    var presetCards: [String: EqualizerPresetCard] = [:]
    var lastPresetStyle: String?
    var advancedSignature = ""
    static var builtInThumbnails: [String: [Double]] = [:]
    var peakGuardActive = false
    let impact = UIImpactFeedbackGenerator(style: .light)
    let selection = UISelectionFeedbackGenerator()

    var profile: EqualizerProfile { engine.profileInForce }
    var mode: EqualizerCurveView.Mode { profile.kind == .graphic ? .simple : .advanced }

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

    @objc func stateChanged() {
        refresh(animated: true)
    }

    @objc func trackChanged() {
        updatePalette()
    }

    func updatePalette() {
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

    // MARK: Refresh

    func refresh(animated: Bool) {
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

    func clampedSelection() -> Int {
        let count = mode == .simple ? GraphicSolver.centres.count : max(profile.bands.count, 1)
        selectedIndex = min(max(selectedIndex, 0), count - 1)
        return selectedIndex
    }

    func updateStatus(profile: EqualizerProfile, running: Bool) {
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

    func updatePreamp(profile: EqualizerProfile) {
        let preamp = profile.preamp()
        preampValueLabel.text = "\(EqualizerCopy.decibels(preamp)) dB"
        autoChip.set(title: profile.isAutoPreamp ? String(localized: "Auto") : String(localized: "Manual"), active: profile.isAutoPreamp, tint: accent)
        preampSlider.minimumTrackTintColor = profile.isAutoPreamp ? accent.withAlphaComponent(0.55) : accent
        if !preampSlider.isTracking { preampSlider.value = Float(preamp) }
        preampSlider.accessibilityValue = "\(EqualizerCopy.decibels(preamp)) dB"
        updatePreampCaption(profile: profile)
    }

    func updatePreampCaption(profile: EqualizerProfile) {
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

    func updateOutputButton() {
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

    // MARK: Actions

}
