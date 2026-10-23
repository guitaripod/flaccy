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

    private let engine = EqualizerEngine.shared
    private let backdrop = AmbientBackdropView()
    private let curveView = MacEqualizerCurveView()
    private let enableSwitch = NSSwitch()
    private let enableLabel = NSTextField(labelWithString: "")
    private let deck = MacEqualizerDeck()
    private let profileTitle = NSTextField(labelWithString: "")
    private let previewPill = MacEqualizerPreviewPill()
    private let saveButton = NSButton()
    private let outputButton = NSButton()
    private let compareButton = MacHoldButton()
    private let modeControl = NSSegmentedControl(labels: [String(localized: "Simple"), String(localized: "Advanced")], trackingMode: .selectOne, target: nil, action: nil)

    private let preampValue = NSTextField(labelWithString: "")
    private let preampSlider = NSSlider(value: 0, minValue: -24, maxValue: 6, target: nil, action: nil)
    private let autoButton = NSButton()
    private let meterLeft = MacMeterBar()
    private let meterRight = MacMeterBar()
    private let peakLabel = NSTextField(labelWithString: "")

    private let hintLabel = NSTextField(labelWithString: "")
    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let keysLabel = NSTextField(labelWithString: "")

    private let lowerCard = NSView()
    private let simpleStrip = NSStackView()
    private let advancedPanel = NSView()
    private let table = NSTableView()
    private var cells: [MacBandCell] = []

    private var accent: NSColor = EqualizerTheme.fallbackAccent
    private var selectedIndex = 5
    private var undoBase: EqualizerState?
    private var guardActive = false
    private var lowerHeight: NSLayoutConstraint?
    private var auditionID: String?
    private var auditionGeneration = 0
    private var escapeMonitor: Any?
    private var observedWindow: NSWindow?

    private var profile: EqualizerProfile { engine.profileInForce }
    private var mode: EqualizerPlotMode { profile.kind == .graphic ? .simple : .advanced }

    private let zoomHost = InterfaceZoomHostView(frame: .zero)
    private var topInset: NSLayoutConstraint?

    private var container: NSView { zoomHost.content }

    private static let hoverPreviewKey = "flaccy.mac.equalizer.hoverPreview"
    private static let dwellSeconds = 0.09
    private static let leaveGraceSeconds = 0.16
    private static let spokenAuditionSeconds = 4.0

    private var hoverPreviewOn: Bool {
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

    @objc private func zoomChanged() {
        topInset?.constant = 40 / MacInterfaceScale.current
    }

    @objc private func stateChanged() {
        refresh(animated: true)
    }

    @objc private func paletteChanged() {
        applyPalette(NowPlayingPaletteService.shared.current, animated: true)
    }

    private func applyPalette(_ palette: ArtworkPalette, animated: Bool) {
        backdrop.apply(palette, animated: animated)
        accent = EqualizerTheme.accent(from: palette)
        refresh(animated: false)
    }

    // MARK: Layout

    private func buildLayout() {
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(backdrop)

        let top = makeTopBar()
        let deckCard = makeDeckCard()
        let rail = makePreampRail()
        let curveCard = makeCurveCard()
        let lower = makeLowerCard()
        let status = makeStatusBar()

        let middle = NSView()
        middle.translatesAutoresizingMaskIntoConstraints = false
        for card in [rail, curveCard] {
            card.translatesAutoresizingMaskIntoConstraints = false
            middle.addSubview(card)
            card.topAnchor.constraint(equalTo: middle.topAnchor).isActive = true
            card.bottomAnchor.constraint(equalTo: middle.bottomAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: middle.leadingAnchor),
            curveCard.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: 16),
            curveCard.trailingAnchor.constraint(equalTo: middle.trailingAnchor),
        ])
        rail.setContentHuggingPriority(.required, for: .horizontal)
        curveCard.setContentHuggingPriority(.defaultLow, for: .horizontal)

        container.addSubview(deckCard)
        for view in [top, middle, lower] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            view.leadingAnchor.constraint(equalTo: deckCard.trailingAnchor, constant: 16).isActive = true
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24).isActive = true
        }
        status.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(status)
        status.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24).isActive = true
        status.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24).isActive = true
        let topAnchorInset = top.topAnchor.constraint(equalTo: container.topAnchor, constant: 36)
        topInset = topAnchorInset
        NotificationCenter.default.addObserver(self, selector: #selector(zoomChanged), name: .flaccyInterfaceScaleChanged, object: nil)
        zoomChanged()

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: container.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            topAnchorInset,
            deckCard.topAnchor.constraint(equalTo: top.topAnchor),
            deckCard.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            deckCard.widthAnchor.constraint(equalToConstant: 236),
            deckCard.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -14),
            middle.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 14),
            lower.topAnchor.constraint(equalTo: middle.bottomAnchor, constant: 14),
            status.topAnchor.constraint(equalTo: lower.bottomAnchor, constant: 14),
            status.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            top.heightAnchor.constraint(equalToConstant: 30),
            status.heightAnchor.constraint(equalToConstant: 16),
            curveCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 340),
        ])
        lowerHeight = lower.heightAnchor.constraint(equalToConstant: 168)
        lowerHeight?.isActive = true
    }

    private func makeTopBar() -> NSView {
        enableSwitch.target = self
        enableSwitch.action = #selector(toggleEnabled)
        enableSwitch.setAccessibilityLabel(EqualizerCopy.title)
        enableLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        enableLabel.textColor = .white.withAlphaComponent(0.7)

        saveButton.title = String(localized: "Save…")
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(promptSave)

        outputButton.bezelStyle = .rounded
        outputButton.imagePosition = .imageLeading
        outputButton.target = self
        outputButton.action = #selector(showOutputMenu(_:))
        outputButton.setAccessibilityHelp(String(localized: "Choose the profile for this output"))

        compareButton.title = String(localized: "Hold to compare")
        compareButton.bezelStyle = .rounded
        compareButton.onPress = { [weak self] in self?.beginCompare() }
        compareButton.onRelease = { [weak self] in self?.endCompare() }
        compareButton.setAccessibilityHelp(String(localized: "Hold to hear the original without the equalizer"))

        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.segmentStyle = .rounded
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let leading = NSStackView(views: [enableSwitch, enableLabel, saveButton, outputButton])
        leading.orientation = .horizontal
        leading.spacing = 10
        leading.alignment = .centerY
        let trailing = NSStackView(views: [compareButton, modeControl])
        trailing.orientation = .horizontal
        trailing.spacing = 10
        trailing.alignment = .centerY
        let spacer = NSView()
        let bar = NSStackView(views: [leading, spacer, trailing])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.distribution = .fill
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return bar
    }

    private func glassCard(hosting content: NSView, radius: CGFloat = 20) -> NSView {
        let card = MacLiquidGlass.surface(hosting: content, cornerRadius: radius)
        card.translatesAutoresizingMaskIntoConstraints = false
        return card
    }

    private func makeDeckCard() -> NSView {
        deck.translatesAutoresizingMaskIntoConstraints = false
        deck.footerMenu = makeDeckFooterMenu()
        deck.setHoverPreview(hoverPreviewOn)
        return glassCard(hosting: deck)
    }

    private func makeDeckFooterMenu() -> NSMenu {
        let menu = NSMenu()
        let entries: [(String, Selector)] = [
            (String(localized: "Export as Text…"), #selector(exportProfile)),
            (String(localized: "Copy as Text"), #selector(copyProfile)),
            (String(localized: "Find Headphones on AutoEq"), #selector(openAutoEq)),
        ]
        for (title, action) in entries {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    private func makePreampRail() -> NSView {
        let tag = NSTextField(labelWithString: String(localized: "Preamp").uppercased())
        tag.font = .systemFont(ofSize: 10.5, weight: .bold)
        tag.textColor = .white.withAlphaComponent(0.45)
        preampValue.font = .monospacedDigitSystemFont(ofSize: 15, weight: .bold)
        preampValue.textColor = .white

        preampSlider.isVertical = true
        preampSlider.target = self
        preampSlider.action = #selector(preampMoved)
        preampSlider.controlSize = .regular
        preampSlider.translatesAutoresizingMaskIntoConstraints = false
        preampSlider.setAccessibilityLabel(String(localized: "Preamp"))

        meterLeft.translatesAutoresizingMaskIntoConstraints = false
        meterRight.translatesAutoresizingMaskIntoConstraints = false
        let meters = NSStackView(views: [meterLeft, meterRight])
        meters.orientation = .horizontal
        meters.spacing = 4
        meters.distribution = .fillEqually
        meters.translatesAutoresizingMaskIntoConstraints = false
        meters.widthAnchor.constraint(equalToConstant: 16).isActive = true

        let faderRow = NSStackView(views: [preampSlider, meters])
        faderRow.orientation = .horizontal
        faderRow.spacing = 10
        faderRow.alignment = .top
        faderRow.distribution = .fill

        peakLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        autoButton.setButtonType(.pushOnPushOff)
        autoButton.bezelStyle = .rounded
        autoButton.controlSize = .small
        autoButton.target = self
        autoButton.action = #selector(toggleAutoPreamp)

        let rail = NSStackView(views: [tag, preampValue, faderRow, peakLabel, autoButton])
        rail.orientation = .vertical
        rail.spacing = 8
        rail.alignment = .centerX
        rail.edgeInsets = NSEdgeInsets(top: 14, left: 12, bottom: 12, right: 12)
        rail.translatesAutoresizingMaskIntoConstraints = false

        let card = glassCard(hosting: rail)
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 96),
            preampSlider.heightAnchor.constraint(greaterThanOrEqualToConstant: 170),
            meterLeft.heightAnchor.constraint(equalTo: preampSlider.heightAnchor),
        ])
        return card
    }

    private func makeCurveCard() -> NSView {
        curveView.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = .systemFont(ofSize: 11.5)
        hintLabel.textColor = .white.withAlphaComponent(0.42)
        hintLabel.alignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        profileTitle.font = .systemFont(ofSize: 17, weight: .bold)
        profileTitle.textColor = .white
        profileTitle.lineBreakMode = .byTruncatingTail
        profileTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewPill.translatesAutoresizingMaskIntoConstraints = false
        previewPill.setContentHuggingPriority(.required, for: .horizontal)
        previewPill.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let titleRow = NSStackView(views: [profileTitle, NSView(), previewPill])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 10
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(titleRow)
        holder.addSubview(curveView)
        holder.addSubview(hintLabel)
        NSLayoutConstraint.activate([
            titleRow.topAnchor.constraint(equalTo: holder.topAnchor, constant: 14),
            titleRow.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 20),
            titleRow.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -16),
            titleRow.heightAnchor.constraint(equalToConstant: 26),
            curveView.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 4),
            curveView.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            curveView.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            hintLabel.topAnchor.constraint(equalTo: curveView.bottomAnchor, constant: -6),
            hintLabel.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 12),
            hintLabel.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -12),
            hintLabel.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -10),
        ])
        return glassCard(hosting: holder)
    }

    private func makeLowerCard() -> NSView {
        simpleStrip.orientation = .horizontal
        simpleStrip.spacing = 6
        simpleStrip.distribution = .fillEqually
        simpleStrip.translatesAutoresizingMaskIntoConstraints = false
        for index in 0..<GraphicSolver.centres.count {
            let cell = MacBandCell()
            cell.onReset = { [weak self] in self?.resetBand(index) }
            cell.onStep = { [weak self] delta in self?.stepBand(index, by: delta) }
            cell.onType = { [weak self] value in self?.setTarget(value, at: index) }
            cell.onFocus = { [weak self] in self?.select(index) }
            cells.append(cell)
            simpleStrip.addArrangedSubview(cell)
        }

        advancedPanel.translatesAutoresizingMaskIntoConstraints = false
        buildTable()

        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(simpleStrip)
        holder.addSubview(advancedPanel)
        NSLayoutConstraint.activate([
            simpleStrip.topAnchor.constraint(equalTo: holder.topAnchor, constant: 12),
            simpleStrip.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -12),
            simpleStrip.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 14),
            simpleStrip.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -14),
            advancedPanel.topAnchor.constraint(equalTo: holder.topAnchor),
            advancedPanel.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            advancedPanel.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            advancedPanel.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
        ])
        lowerCard.translatesAutoresizingMaskIntoConstraints = false
        return glassCard(hosting: holder)
    }

    private func buildTable() {
        let columns: [(String, String, CGFloat)] = [
            ("index", String(localized: "Band"), 64),
            ("enabled", String(localized: "On"), 48),
            ("type", String(localized: "Type"), 140),
            ("frequency", String(localized: "Frequency"), 120),
            ("gain", String(localized: "Gain"), 110),
            ("q", "Q", 90),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 24
        table.backgroundColor = .clear
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = false
        table.selectionHighlightStyle = .regular
        table.headerView = NSTableHeaderView()
        table.setAccessibilityLabel(String(localized: "Equalizer bands"))

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "Add band"))!, target: self, action: #selector(addBandPressed))
        let remove = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: String(localized: "Remove band"))!, target: self, action: #selector(removeBandPressed))
        for button in [add, remove] {
            button.bezelStyle = .smallSquare
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        }
        let buttons = NSStackView(views: [add, remove])
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false

        advancedPanel.addSubview(scroll)
        advancedPanel.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: advancedPanel.topAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: advancedPanel.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: advancedPanel.bottomAnchor, constant: -6),
            buttons.topAnchor.constraint(equalTo: advancedPanel.topAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: advancedPanel.trailingAnchor, constant: -14),
        ])
    }

    private func makeStatusBar() -> NSView {
        statusIcon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        keysLabel.font = .systemFont(ofSize: 11.5)
        keysLabel.textColor = .white.withAlphaComponent(0.4)
        keysLabel.stringValue = String(localized: "← → select band · ↑ ↓ ±0.5 dB · ⇧ ±2 · ⌥ ±0.1 · 0 reset · ⌘Z undo · ⌥⌘E show or hide")
        let left = NSStackView(views: [statusIcon, statusLabel])
        left.spacing = 6
        let spacer = NSView()
        let bar = NSStackView(views: [left, spacer, keysLabel])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return bar
    }

    // MARK: Refresh

    private func refresh(animated: Bool) {
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

    private func clampedSelection() -> Int {
        let count = mode == .simple ? GraphicSolver.centres.count : max(profile.bands.count, 1)
        selectedIndex = min(max(selectedIndex, 0), count - 1)
        return selectedIndex
    }

    private func updateOutputButton() {
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

    private func updatePreamp(profile: EqualizerProfile) {
        let preamp = profile.preamp()
        preampValue.stringValue = "\(EqualizerCopy.decibels(preamp)) dB"
        if !preampSlider.isHighlighted { preampSlider.doubleValue = preamp }
        autoButton.title = profile.isAutoPreamp ? String(localized: "Auto") : String(localized: "Manual")
        autoButton.state = profile.isAutoPreamp ? .on : .off
        preampSlider.trackFillColor = profile.isAutoPreamp ? accent.withAlphaComponent(0.6) : accent
        preampSlider.setAccessibilityValue("\(EqualizerCopy.decibels(preamp)) dB")
    }

    private func updateStatus(profile: EqualizerProfile, running: Bool) {
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

    private func updateCells(profile: EqualizerProfile) {
        for (index, cell) in cells.enumerated() where index < profile.targets.count {
            cell.configure(
                frequency: EqualizerCopy.hertz(GraphicSolver.centres[index]),
                value: profile.targets[index],
                isSelected: index == selectedIndex,
                accent: accent
            )
        }
    }

    private func syncTableSelection() {
        let index = clampedSelection()
        if profile.bands.indices.contains(index), table.selectedRow != index {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    private func updateMeter() {
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

    private func wireDeck() {
        deck.onPointed = { [weak self] id in self?.deckPointed(at: id) }
        deck.onLeft = { [weak self] in self?.deckLeft() }
        deck.onKeep = { [weak self] id in self?.keepPreset(id) }
        deck.onCancel = { [weak self] in self?.cancelAudition() }
        deck.onAuditionBriefly = { [weak self] id in self?.auditionBriefly(id) }
        deck.onHoverPreviewChanged = { [weak self] on in self?.hoverPreviewChanged(on) }
        deck.onImport = { [weak self] in self?.importProfile() }
        deck.onRowAction = { [weak self] action, id in self?.performRowAction(action, id: id) }
    }

    private func performRowAction(_ action: MacDeckRowAction, id: String) {
        guard let target = engine.state.userProfiles.first(where: { $0.id == id }) else { return }
        switch action {
        case .rename: promptRename(id)
        case .export: export(target)
        case .copy: copyAsText(target)
        case .delete: confirmDelete(id)
        }
    }

    private func hoverPreviewChanged(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.hoverPreviewKey)
        deck.setHoverPreview(on)
        if !on { endAudition() }
    }

    /// The pointer or keyboard focus has come to a preset. While one is already
    /// playing as a preview the switch is at once, so a sweep down the list
    /// plays each in turn; otherwise the pointer has to rest a moment first.
    private func deckPointed(at id: String) {
        guard hoverPreviewOn else { return }
        auditionGeneration += 1
        if auditionID != nil {
            beginAudition(id)
            return
        }
        let generation = auditionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwellSeconds) { [weak self] in
            guard let self, self.auditionGeneration == generation else { return }
            self.beginAudition(id)
        }
    }

    /// The pointer left a preset. The preview ends after a short grace unless
    /// it reaches another preset first.
    private func deckLeft() {
        auditionGeneration += 1
        let generation = auditionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.leaveGraceSeconds) { [weak self] in
            guard let self, self.auditionGeneration == generation else { return }
            self.endAudition()
        }
    }

    /// VoiceOver cannot hover, so its Audition action plays a preset for a few seconds.
    private func auditionBriefly(_ id: String) {
        beginAudition(id)
        let generation = auditionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.spokenAuditionSeconds) { [weak self] in
            guard let self, self.auditionGeneration == generation else { return }
            self.endAudition()
        }
    }

    private func beginAudition(_ id: String) {
        guard auditionID != id, let candidate = engine.allProfiles.first(where: { $0.id == id }) else { return }
        engine.beginAudition(candidate)
        auditionID = id
        curveView.setPreview(candidate.resolvedBands())
        deck.setHearing(id)
        previewPill.show(EqualizerCopy.name(of: candidate))
        installEscapeMonitor()
    }

    private func endAudition() {
        auditionGeneration += 1
        guard auditionID != nil else { return }
        auditionID = nil
        engine.endAudition()
        curveView.setPreview(nil)
        deck.setHearing(nil)
        previewPill.show(nil)
        removeEscapeMonitor()
    }

    private func cancelAudition() {
        endAudition()
        view.window?.makeFirstResponder(curveView)
    }

    private func endAuditionIfPresetVanished() {
        guard let id = auditionID, !engine.allProfiles.contains(where: { $0.id == id }) else { return }
        endAudition()
    }

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, self?.view.window === event.window, self?.auditionID != nil else { return event }
            self?.cancelAudition()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        guard let monitor = escapeMonitor else { return }
        NSEvent.removeMonitor(monitor)
        escapeMonitor = nil
    }

    private func observeWindowForAudition() {
        guard let window = view.window, window !== observedWindow else { return }
        let center = NotificationCenter.default
        if let previous = observedWindow {
            center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: previous)
            center.removeObserver(self, name: NSWindow.willCloseNotification, object: previous)
        }
        observedWindow = window
        center.addObserver(self, selector: #selector(windowStoppedListening), name: NSWindow.didResignKeyNotification, object: window)
        center.addObserver(self, selector: #selector(windowStoppedListening), name: NSWindow.willCloseNotification, object: window)
    }

    @objc private func windowStoppedListening() {
        endAudition()
    }

#if DEBUG
    /// Starts an audition without a pointer, for the debug screenshot.
    func auditionForCapture(profileID: String) {
        beginAudition(profileID)
        deck.reveal(profileID)
    }

    /// The preset being auditioned, for the debug exercise.
    var auditionedPresetID: String? { auditionID }

    /// Whether the curve is drawing a previewed line, for the debug exercise.
    var curveIsPreviewing: Bool { curveView.isPreviewing }

    /// Runs the deck's own pointer callbacks as a hovering pointer would.
    func exercisePointer(at id: String?) {
        if let id { deckPointed(at: id) } else { deckLeft() }
    }

    /// Runs the deck's click callback.
    func exerciseKeep(_ id: String) {
        keepPreset(id)
    }
#endif

    // MARK: Editing and undo

    private func beginEditing() {
        if undoBase == nil { undoBase = engine.state }
    }

    private func finishEditing() {
        guard let base = undoBase else { return }
        undoBase = nil
        guard base != engine.state else { return }
        registerUndo(restoring: base)
    }

    private func registerUndo(restoring previous: EqualizerState) {
        view.window?.undoManager?.registerUndo(withTarget: self) { target in
            let current = target.engine.state
            target.engine.restore(previous)
            target.registerUndo(restoring: current)
        }
        view.window?.undoManager?.setActionName(String(localized: "Equalizer"))
    }

    private func select(_ index: Int) {
        selectedIndex = index
        if !engine.state.isEnabled { engine.setEnabled(true) }
        refresh(animated: false)
    }

    private func setTarget(_ value: Double, at index: Int) {
        beginEditing()
        engine.edit { profile in
            guard profile.targets.indices.contains(index) else { return }
            profile.targets[index] = min(max(value, -12), 12)
        }
        finishEditing()
    }

    private func stepBand(_ index: Int, by delta: Double) {
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

    private func resetBand(_ index: Int) {
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

    private func editBand(_ index: Int, _ change: (inout EqualizerBand) -> Void) {
        beginEditing()
        engine.edit { profile in
            guard profile.bands.indices.contains(index) else { return }
            change(&profile.bands[index])
            profile.bands[index] = profile.bands[index].clamped()
        }
        finishEditing()
    }

    // MARK: Actions

    @objc private func toggleEnabled() {
        beginEditing()
        engine.setEnabled(enableSwitch.state == .on)
        finishEditing()
    }

    private func keepPreset(_ id: String) {
        endAudition()
        beginEditing()
        engine.select(profileID: id)
        finishEditing()
        refresh(animated: false)
        view.window?.makeFirstResponder(curveView)
    }

    @objc private func modeChanged() {
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

    @objc private func preampMoved() {
        beginEditing()
        let value = (preampSlider.doubleValue * 2).rounded() / 2
        engine.edit { profile in
            profile.isAutoPreamp = false
            profile.manualPreamp = value
        }
        if NSApp.currentEvent?.type == .leftMouseUp { finishEditing() }
    }

    @objc private func toggleAutoPreamp() {
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

    private func beginCompare() {
        engine.beginCompare()
        refresh(animated: false)
    }

    private func endCompare() {
        engine.endCompare()
        refresh(animated: false)
    }

    @objc private func promptSave() {
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

    @objc private func importProfile() {
        guard let window = view.window else { return }
        let sheet = MacEqualizerImportViewController(accent: accent)
        sheet.onFinish = { [weak self] in self?.refresh(animated: false) }
        presentAsSheet(sheet)
        _ = window
    }

    @objc private func exportProfile() {
        export(profile)
    }

    @objc private func copyProfile() {
        copyAsText(profile)
    }

    private func export(_ profile: EqualizerProfile) {
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

    private func copyAsText(_ profile: EqualizerProfile) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(engine.exportText(for: profile), forType: .string)
        if let window = view.window { MacToast.show(String(localized: "Copied to the clipboard"), in: window) }
    }

    private func promptRename(_ id: String) {
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

    private func confirmDelete(_ id: String) {
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

    @objc private func openAutoEq() {
        if let url = URL(string: "https://autoeq.app") { NSWorkspace.shared.open(url) }
    }

    @objc private func addBandPressed() {
        addBand(frequency: 1_000, gain: 0)
    }

    @objc private func removeBandPressed() {
        deleteSelectedBand()
    }

    private func addBand(frequency: Double, gain: Double) {
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

    private func deleteSelectedBand() {
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

    @objc private func showOutputMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let output = engine.output
        let header = NSMenuItem(title: output?.name ?? String(localized: "Speaker"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let remember = NSMenuItem(title: String(localized: "Remember for this Output"), action: #selector(toggleRemember), keyEquivalent: "")
        remember.target = self
        remember.state = engine.keepsOwnProfileForOutput ? .on : .off
        remember.isEnabled = output != nil
        menu.addItem(remember)

        let use = NSMenuItem(title: String(localized: "Use Profile"), action: nil, keyEquivalent: "")
        use.submenu = profileSubmenu(includeOff: true) { [weak self] choice in
            guard let self, let id = self.engine.outputID else { return }
            self.apply(choice, toOutput: id)
        }
        menu.addItem(use)

        let others = engine.rememberedOutputs.filter { $0.id != engine.outputID }
        if !others.isEmpty {
            menu.addItem(.separator())
            let title = NSMenuItem(title: String(localized: "Other Outputs"), action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            for other in others {
                let profileName = other.binding == EqualizerState.offBinding
                    ? String(localized: "Off · bit-perfect")
                    : (engine.state.profile(withID: other.binding).map { EqualizerCopy.name(of: $0) } ?? "")
                let item = NSMenuItem(title: "\(other.name) · \(profileName)", action: nil, keyEquivalent: "")
                item.submenu = profileSubmenu(includeOff: true, includeForget: true) { [weak self] choice in
                    self?.apply(choice, toOutput: other.id)
                }
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let defaultItem = NSMenuItem(title: String(localized: "Other Outputs Use"), action: nil, keyEquivalent: "")
        defaultItem.submenu = profileSubmenu(includeOff: false) { [weak self] choice in
            if case .profile(let id) = choice { self?.engine.setDefaultProfile(id) }
        }
        menu.addItem(defaultItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    private enum Choice {
        case off
        case profile(String)
        case forget
    }

    private func profileSubmenu(includeOff: Bool, includeForget: Bool = false, handler: @escaping (Choice) -> Void) -> NSMenu {
        let menu = NSMenu()
        if includeOff {
            menu.addItem(MacClosureMenuItem(title: String(localized: "Off · bit-perfect")) { handler(.off) })
            menu.addItem(.separator())
        }
        for candidate in engine.state.userProfiles {
            menu.addItem(MacClosureMenuItem(title: candidate.name) { handler(.profile(candidate.id)) })
        }
        if !engine.state.userProfiles.isEmpty { menu.addItem(.separator()) }
        for candidate in EqualizerPresets.all {
            menu.addItem(MacClosureMenuItem(title: EqualizerCopy.name(of: candidate)) { handler(.profile(candidate.id)) })
        }
        if includeForget {
            menu.addItem(.separator())
            menu.addItem(MacClosureMenuItem(title: String(localized: "Forget this Output")) { handler(.forget) })
        }
        return menu
    }

    private func apply(_ choice: Choice, toOutput id: String) {
        beginEditing()
        switch choice {
        case .off: engine.bindOutputToOff(id)
        case .profile(let profileID): engine.setBinding(profileID, forOutput: id)
        case .forget: engine.forgetOutput(id)
        }
        finishEditing()
    }

    @objc private func toggleRemember() {
        beginEditing()
        engine.setRemembering(!engine.keepsOwnProfileForOutput)
        finishEditing()
    }
}

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

    private func contentForCurve() -> EqualizerCurveContent {
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
    private func verticallyCentered(_ control: NSView) -> NSView {
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

    private enum FieldKind: Int {
        case frequency
        case gain
        case q
    }

    private func field(text: String, row: Int, kind: FieldKind, enabled: Bool) -> NSTextField {
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

    @objc private func enabledToggled(_ sender: NSButton) {
        editBand(sender.tag) { $0.isEnabled = sender.state == .on }
    }

    @objc private func typeChosen(_ sender: NSPopUpButton) {
        let type = EqualizerFilterType.allCases[sender.indexOfSelectedItem]
        editBand(sender.tag) { band in
            band.type = type
            band.q = type.defaultQ
            if !type.hasGain { band.gain = 0 }
        }
    }

    @objc private func fieldCommitted(_ sender: NSTextField) {
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

/// A band in the Simple strip: its frequency (click to reset), an editable gain, and a pair of steppers.
private final class MacBandCell: NSStackView, NSTextFieldDelegate {

    var onReset: (() -> Void)?
    var onStep: ((Double) -> Void)?
    var onType: ((Double) -> Void)?
    var onFocus: (() -> Void)?

    private let frequencyButton = NSButton()
    private let valueField = NSTextField()
    private let up = NSButton()
    private let down = NSButton()
    private let selectionLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .vertical
        spacing = 6
        alignment = .centerX
        edgeInsets = NSEdgeInsets(top: 8, left: 2, bottom: 8, right: 2)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous

        frequencyButton.isBordered = false
        frequencyButton.font = .systemFont(ofSize: 12, weight: .semibold)
        frequencyButton.target = self
        frequencyButton.action = #selector(resetPressed)
        frequencyButton.setAccessibilityHelp(String(localized: "Resets this band"))

        valueField.alignment = .center
        valueField.font = .monospacedDigitSystemFont(ofSize: 15, weight: .bold)
        valueField.isBordered = true
        valueField.bezelStyle = .roundedBezel
        valueField.delegate = self
        valueField.target = self
        valueField.action = #selector(valueCommitted)
        valueField.translatesAutoresizingMaskIntoConstraints = false
        valueField.widthAnchor.constraint(equalToConstant: 62).isActive = true

        for (button, symbol, label) in [(up, "chevron.up", String(localized: "Raise 0.5 dB")), (down, "chevron.down", String(localized: "Lower 0.5 dB"))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.bezelStyle = .smallSquare
            button.target = self
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        }
        up.action = #selector(stepUp)
        down.action = #selector(stepDown)
        let steppers = NSStackView(views: [up, down])
        steppers.spacing = 4

        addArrangedSubview(frequencyButton)
        addArrangedSubview(valueField)
        addArrangedSubview(steppers)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(frequency: String, value: Double, isSelected: Bool, accent: NSColor) {
        frequencyButton.title = frequency
        frequencyButton.contentTintColor = isSelected ? .white : .white.withAlphaComponent(0.6)
        if window?.firstResponder !== valueField.currentEditor() {
            valueField.stringValue = EqualizerCopy.decibels(value)
        }
        layer?.backgroundColor = isSelected ? accent.withAlphaComponent(0.14).cgColor : NSColor.clear.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = (isSelected ? accent.withAlphaComponent(0.55) : NSColor.clear).cgColor
    }

    @objc private func resetPressed() { onReset?() }
    @objc private func stepUp() { onStep?(0.5) }
    @objc private func stepDown() { onStep?(-0.5) }

    @objc private func valueCommitted() {
        if let value = MacEqualizerViewController.parseNumber(valueField.stringValue) { onType?(value) }
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        onFocus?()
    }

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        super.mouseDown(with: event)
    }
}

/// A button that reports the press and the release separately, for Hold to compare.
final class MacHoldButton: NSButton {

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onPress?()
        highlight(true)
        window?.trackEvents(matching: [.leftMouseUp], timeout: .infinity, mode: .eventTracking) { _, stop in
            stop.pointee = true
        }
        highlight(false)
        onRelease?()
    }
}

/// A thin vertical level bar for the preamp rail.
final class MacMeterBar: NSView {

    private var fraction: CGFloat = 0
    private var color: NSColor = EqualizerTheme.lossless

    override var isFlipped: Bool { true }

    func set(peakDecibels: Float, color: NSColor) {
        fraction = CGFloat(min(max((peakDecibels + 30) / 30, 0), 1))
        self.color = color
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        color.setFill()
        let height = bounds.height * fraction
        NSBezierPath(roundedRect: NSRect(x: 0, y: bounds.height - height, width: bounds.width, height: height), xRadius: 3, yRadius: 3).fill()
    }
}

/// A menu item that runs a closure, so menus built on the fly need no selectors.
nonisolated final class MacClosureMenuItem: NSMenuItem {

    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func run() {
        let handler = handler
        MainActor.assumeIsolated { handler() }
    }
}
