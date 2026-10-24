import AppKit
import FlaccyCore
import UniformTypeIdentifiers

extension MacEqualizerViewController {

    func buildLayout() {
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

    func makeTopBar() -> NSView {
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

    func glassCard(hosting content: NSView, radius: CGFloat = 20) -> NSView {
        let card = MacLiquidGlass.surface(hosting: content, cornerRadius: radius)
        card.translatesAutoresizingMaskIntoConstraints = false
        return card
    }

    func makeDeckCard() -> NSView {
        deck.translatesAutoresizingMaskIntoConstraints = false
        deck.footerMenu = makeDeckFooterMenu()
        deck.setHoverPreview(hoverPreviewOn)
        return glassCard(hosting: deck)
    }

    func makeDeckFooterMenu() -> NSMenu {
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

    func makePreampRail() -> NSView {
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

    func makeCurveCard() -> NSView {
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

    func makeLowerCard() -> NSView {
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

    func buildTable() {
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

    func makeStatusBar() -> NSView {
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
}
