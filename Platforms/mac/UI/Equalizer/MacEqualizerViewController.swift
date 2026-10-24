import AppKit
import FlaccyCore
import UniformTypeIdentifiers

/// The equalizer window's content: the same curve and the same rules as the
/// iPhone, laid out the way a Mac instrument is. A deck of every preset fills
/// the left column: pointing at one plays it, clicking keeps it. A strip across
/// the top of the rest holds the switch, the output this profile follows,
/// Compare and the mode; a preamp rail with level meters sits beside the curve;
/// and under it a row of ten band cells (Simple) or a table of parametric bands
/// (Advanced). Everything edits through `EqualizerEngine`, and every gesture
/// is one undo step.
final class MacEqualizerViewController: NSViewController {

    let engine = EqualizerEngine.shared
    let backdrop = AmbientBackdropView()
    let curveView = MacEqualizerCurveView()
    let enableSwitch = NSSwitch()
    let enableLabel = NSTextField(labelWithString: "")
    let deck = MacEqualizerDeck()
    let profileTitle = NSTextField(labelWithString: "")
    let previewPill = MacEqualizerPreviewPill()
    let saveButton = NSButton()
    let outputButton = NSButton()
    let compareButton = MacHoldButton()
    let modeControl = NSSegmentedControl(labels: [String(localized: "Simple"), String(localized: "Advanced")], trackingMode: .selectOne, target: nil, action: nil)

    let preampValue = NSTextField(labelWithString: "")
    let preampSlider = NSSlider(value: 0, minValue: -24, maxValue: 6, target: nil, action: nil)
    let autoButton = NSButton()
    let meterLeft = MacMeterBar()
    let meterRight = MacMeterBar()
    let peakLabel = NSTextField(labelWithString: "")

    let hintLabel = NSTextField(labelWithString: "")
    let statusIcon = NSImageView()
    let statusLabel = NSTextField(labelWithString: "")
    let keysLabel = NSTextField(labelWithString: "")

    let lowerCard = NSView()
    let simpleStrip = NSStackView()
    let advancedPanel = NSView()
    let table = NSTableView()
    var cells: [MacBandCell] = []

    var accent: NSColor = EqualizerTheme.fallbackAccent
    var selectedIndex = 5
    var undoBase: EqualizerState?
    var guardActive = false
    var lowerHeight: NSLayoutConstraint?
    var auditionID: String?
    var auditionGeneration = 0
    var escapeMonitor: Any?
    var observedWindow: NSWindow?

    var profile: EqualizerProfile { engine.profileInForce }
    var mode: EqualizerPlotMode { profile.kind == .graphic ? .simple : .advanced }

    let zoomHost = InterfaceZoomHostView(frame: .zero)
    var topInset: NSLayoutConstraint?

    var container: NSView { zoomHost.content }

    static let hoverPreviewKey = "flaccy.mac.equalizer.hoverPreview"
    static let dwellSeconds = 0.09
    static let leaveGraceSeconds = 0.16
    static let spokenAuditionSeconds = 4.0

    var hoverPreviewOn: Bool {
        UserDefaults.standard.object(forKey: Self.hoverPreviewKey) as? Bool ?? true
    }

    override func loadView() {
        zoomHost.wantsLayer = true
        view = zoomHost
        buildLayout()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        curveView.delegate = self
        curveView.spectrumProvider = { [engine] in engine.spectrum() }
        curveView.onFrame = { [weak self] in self?.updateMeter() }
        wireDeck()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(stateChanged), name: EqualizerEngine.stateDidChange, object: nil)
        center.addObserver(self, selector: #selector(paletteChanged), name: .flaccyNowPlayingPaletteChanged, object: nil)
        applyPalette(NowPlayingPaletteService.shared.current, animated: false)
        refresh(animated: false)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        engine.beginAnalysis(for: self)
        refresh(animated: false)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(curveView)
        observeWindowForAudition()
        deck.revealCurrent()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        endAudition()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        engine.endAnalysis(for: self)
        engine.endCompare()
    }

    @objc func zoomChanged() {
        topInset?.constant = 40 / MacInterfaceScale.current
    }

    @objc func stateChanged() {
        refresh(animated: true)
    }

    @objc func paletteChanged() {
        applyPalette(NowPlayingPaletteService.shared.current, animated: true)
    }

    func applyPalette(_ palette: ArtworkPalette, animated: Bool) {
        backdrop.apply(palette, animated: animated)
        accent = EqualizerTheme.accent(from: palette)
        refresh(animated: false)
    }

    // MARK: Layout

    // MARK: Refresh

    // MARK: Editing and undo

}
