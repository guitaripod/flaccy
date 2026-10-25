import AppKit
import FlaccyCore

extension MacLyricShareViewController {

    func buildControls() {
        controlsStack.orientation = .vertical
        controlsStack.alignment = .leading
        controlsStack.spacing = 20
        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        controlsDocument.translatesAutoresizingMaskIntoConstraints = false
        controlsDocument.addSubview(controlsStack)
        controlsScroll.documentView = controlsDocument
        controlsScroll.hasVerticalScroller = true
        controlsScroll.drawsBackground = false
        NSLayoutConstraint.activate([
            controlsStack.topAnchor.constraint(equalTo: controlsDocument.topAnchor, constant: 20),
            controlsStack.leadingAnchor.constraint(equalTo: controlsDocument.leadingAnchor, constant: 12),
            controlsStack.trailingAnchor.constraint(equalTo: controlsDocument.trailingAnchor, constant: -20),
            controlsStack.bottomAnchor.constraint(equalTo: controlsDocument.bottomAnchor, constant: -24),
            controlsDocument.topAnchor.constraint(equalTo: controlsScroll.contentView.topAnchor),
            controlsDocument.leadingAnchor.constraint(equalTo: controlsScroll.contentView.leadingAnchor),
            controlsDocument.widthAnchor.constraint(equalTo: controlsScroll.contentView.widthAnchor),
        ])

        formatControl.target = self
        formatControl.action = #selector(formatChanged)
        formatControl.segmentDistribution = .fillEqually
        typefaceControl.target = self
        typefaceControl.action = #selector(typefaceChanged)
        typefaceControl.segmentDistribution = .fillEqually

        controlsStack.addFullWidth(section(LyricShareCopy.templateHeader, content: templateRow()))
        controlsStack.addFullWidth(section(LyricShareCopy.formatHeader, content: formatControl))
        controlsStack.addFullWidth(section(LyricShareCopy.colorsHeader, content: themeRow()))
        controlsStack.addFullWidth(section(LyricShareCopy.fontHeader, content: typefaceControl))
        controlsStack.addFullWidth(toggleRow())
        controlsStack.addFullWidth(linesSection())
    }

    private func section(_ title: String, content: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.setAccessibilityRole(.staticText)
        let column = NSStackView(views: [label])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.addFullWidth(content)
        return column
    }

    private func chipRow(_ buttons: [NSView], height: CGFloat) -> NSStackView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 8
        row.heightAnchor.constraint(equalToConstant: height).isActive = true
        return row
    }

    private func templateRow() -> NSView {
        var buttons: [NSView] = []
        for template in LyricShareTemplate.allCases {
            let button = LyricShareChipButton()
            button.configure(
                title: LyricShareCopy.template(template), symbol: LyricShareCopy.templateSymbol(template),
                hint: LyricShareCopy.templateHint(template))
            button.target = self
            button.action = #selector(templateTapped(_:))
            templateButtons[template] = button
            buttons.append(button)
        }
        return chipRow(buttons, height: 62)
    }

    private func themeRow() -> NSView {
        var buttons: [NSView] = []
        for theme in LyricShareTheme.allCases {
            let button = LyricShareChipButton()
            button.showsChosenBackground = false
            button.target = self
            button.action = #selector(themeTapped(_:))
            themeButtons[theme] = button
            buttons.append(button)
        }
        return chipRow(buttons, height: 70)
    }

    private func toggleRow() -> NSView {
        let toggles = [(coverToggle, #selector(coverToggled)), (visualizerToggle, #selector(visualizerToggled)), (markToggle, #selector(markToggled))]
        for (toggle, action) in toggles {
            toggle.target = self
            toggle.action = action
        }
        let row = NSStackView(views: toggles.map(\.0))
        row.orientation = .horizontal
        row.distribution = .fillProportionally
        row.spacing = 14
        return row
    }

    private func linesSection() -> NSView {
        linesHint.font = .systemFont(ofSize: 12)
        linesHint.textColor = .secondaryLabelColor
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.addFullWidth(linesHint)
        if !session.isTimed {
            startLabel.font = .systemFont(ofSize: 12, weight: .medium)
            startSlider.minValue = 0
            startSlider.maxValue = max(session.trackDuration - LyricShareClip.plainDuration, 0)
            startSlider.doubleValue = session.plainStart
            startSlider.isContinuous = true
            startSlider.target = self
            startSlider.action = #selector(startSliderMoved)
            column.addFullWidth(startLabel)
            column.addFullWidth(startSlider)
        }
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 2
        for (index, text) in session.pickerLines.enumerated() {
            let row = LyricShareLineRow(text: text, pickable: session.isPickable(index))
            row.onClick = { [weak self] in
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                self?.session.toggle(line: index)
            }
            lineRows[index] = row
            rows.addFullWidth(row)
        }
        column.addFullWidth(rows)
        return section(LyricShareCopy.linesHeader, content: column)
    }

    @objc private func templateTapped(_ sender: NSButton) {
        guard let template = templateButtons.first(where: { $0.value === sender })?.key else { return }
        update { $0.template = template }
    }

    @objc private func themeTapped(_ sender: NSButton) {
        guard let theme = themeButtons.first(where: { $0.value === sender })?.key else { return }
        update { $0.theme = theme }
    }

    @objc private func formatChanged() {
        let index = formatControl.selectedSegment
        guard LyricShareFormat.allCases.indices.contains(index) else { return }
        update { $0.format = LyricShareFormat.allCases[index] }
    }

    @objc private func typefaceChanged() {
        let index = typefaceControl.selectedSegment
        guard LyricShareTypeface.allCases.indices.contains(index) else { return }
        update { $0.typeface = LyricShareTypeface.allCases[index] }
    }

    @objc private func coverToggled() {
        update { $0.showArtwork = coverToggle.state == .on }
    }

    @objc private func visualizerToggled() {
        update { $0.showVisualizer = visualizerToggle.state == .on }
    }

    @objc private func markToggled() {
        update { $0.showMark = markToggle.state == .on }
    }

    @objc private func startSliderMoved() {
        session.setPlainStart(startSlider.doubleValue)
    }

    /// Applies a change to the session's style, with a haptic tick when it
    /// actually changes something.
    func update(_ change: (inout LyricShareStyle) -> Void) {
        var style = session.style
        change(&style)
        guard style != session.style else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        session.style = style
    }

    func applyStyle() {
        let style = session.style
        for (template, button) in templateButtons {
            button.configure(
                title: LyricShareCopy.template(template), symbol: LyricShareCopy.templateSymbol(template),
                hint: LyricShareCopy.templateHint(template))
            button.isChosen = template == style.template
        }
        formatControl.selectedSegment = LyricShareFormat.allCases.firstIndex(of: style.format) ?? 0
        typefaceControl.selectedSegment = LyricShareTypeface.allCases.firstIndex(of: style.typeface) ?? 0
        for (theme, button) in themeButtons {
            button.configure(title: LyricShareCopy.theme(theme), symbol: nil)
            button.image = Self.swatch(session.palette(for: theme), selected: theme == style.theme)
            button.isChosen = theme == style.theme
        }
        coverToggle.state = style.showArtwork ? .on : .off
        visualizerToggle.state = style.showVisualizer ? .on : .off
        markToggle.state = style.showMark ? .on : .off
        well.aspect = CGFloat(style.format.pixelWidth) / CGFloat(style.format.pixelHeight)
    }

    func refreshLines() {
        let current = session.selection
        for (index, row) in lineRows {
            row.setChosen(current.contains(index) && session.isPickable(index))
        }
        linesHint.stringValue = LyricShareCopy.linesHint(duration: session.window.duration, timed: session.isTimed)
        startLabel.stringValue = LyricShareCopy.startsAt(session.plainStart)
    }

    /// Locks or unlocks everything the person can change while a video is
    /// being made.
    func setControlsEnabled(_ enabled: Bool) {
        controlsStack.alphaValue = enabled ? 1 : 0.5
        Self.setEnabled(enabled, in: controlsStack)
        for row in lineRows.values { row.isLocked = !enabled }
    }

    private static func setEnabled(_ enabled: Bool, in view: NSView) {
        for subview in view.subviews {
            (subview as? NSControl)?.isEnabled = enabled
            setEnabled(enabled, in: subview)
        }
    }

    /// A round chip of a theme's background with a dot of its ink, ringed in
    /// the accent colour while chosen.
    private static func swatch(_ palette: LyricSharePalette, selected: Bool) -> NSImage {
        let side: CGFloat = 40
        let top = nsColor(palette.background)
        let bottom = nsColor(palette.backgroundDeep)
        let ink = nsColor(palette.ink)
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let rect = NSRect(x: 2, y: 2, width: side - 4, height: side - 4)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: rect).addClip()
            NSGradient(starting: top, ending: bottom)?.draw(in: NSRect(x: 0, y: 0, width: side, height: side), angle: -90)
            ink.setFill()
            NSBezierPath(ovalIn: NSRect(x: side / 2 - 5, y: side / 2 - 5, width: 10, height: 10)).fill()
            NSGraphicsContext.restoreGraphicsState()
            let ring = selected ? NSColor.controlAccentColor : NSColor.separatorColor
            ring.setStroke()
            let outline = NSBezierPath(ovalIn: rect.insetBy(dx: selected ? 0 : 0.5, dy: selected ? 0 : 0.5))
            outline.lineWidth = selected ? 3 : 1
            outline.stroke()
            return true
        }
    }

    nonisolated private static func nsColor(_ color: LyricShareColor) -> NSColor {
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
    }
}

extension NSStackView {

    /// Adds `view` and makes it as wide as the stack, which `alignment` alone
    /// does not do for a vertical stack.
    func addFullWidth(_ view: NSView) {
        addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
}
