import AppKit
import FlaccyCore

/// The panel that drops from the transport bar's equalizer button: the switch,
/// a small look at the curve, the presets, and a way into the full window.
final class MacEqualizerQuickPanel: NSViewController {

    private let engine = EqualizerEngine.shared
    private let enableSwitch = NSSwitch()
    private let statusLabel = NSTextField(labelWithString: "")
    private let thumbnail = MacCurveThumbnailView()
    private let rows = NSStackView()
    private let outputLabel = NSTextField(labelWithString: "")
    private var accent = NowPlayingPaletteService.shared.current.dominant

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        view = root

        let title = NSTextField(labelWithString: EqualizerCopy.title)
        title.font = .systemFont(ofSize: 17, weight: .bold)
        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        let titles = NSStackView(views: [title, statusLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        enableSwitch.target = self
        enableSwitch.action = #selector(toggle)
        enableSwitch.setAccessibilityLabel(EqualizerCopy.title)
        let header = NSStackView(views: [titles, NSView(), enableSwitch])
        header.orientation = .horizontal
        header.alignment = .centerY

        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.heightAnchor.constraint(equalToConstant: 96).isActive = true
        thumbnail.onClick = { [weak self] in self?.openWindow() }

        rows.orientation = .vertical
        rows.spacing = 1
        rows.alignment = .leading
        rows.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.documentView = rows
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 200).isActive = true
        rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        outputLabel.font = .systemFont(ofSize: 12)
        outputLabel.textColor = .secondaryLabelColor
        let open = NSButton(title: String(localized: "Open Equalizer…"), target: self, action: #selector(openWindow))
        open.bezelStyle = .rounded
        let footer = NSStackView(views: [outputLabel, NSView(), open])
        footer.orientation = .horizontal
        footer.alignment = .centerY

        let column = NSStackView(views: [header, thumbnail, scroll, footer])
        column.orientation = .vertical
        column.spacing = 12
        column.alignment = .leading
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            column.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
            column.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            header.widthAnchor.constraint(equalTo: column.widthAnchor),
            thumbnail.widthAnchor.constraint(equalTo: column.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: column.widthAnchor),
            footer.widthAnchor.constraint(equalTo: column.widthAnchor),
            view.widthAnchor.constraint(equalToConstant: 360),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged), name: EqualizerEngine.stateDidChange, object: nil)
        refresh()
    }

    @objc private func stateChanged() {
        refresh()
    }

    private func refresh() {
        let profile = engine.profileInForce
        let running = engine.state.isEnabled && !engine.isOutputBoundToOff
        enableSwitch.state = running ? .on : .off
        let status: EqualizerCopy.Status = !running ? .off : (profile.isFlat ? .flat : .processing)
        statusLabel.stringValue = EqualizerCopy.status(status)
        statusLabel.textColor = status == .processing ? accent : EqualizerTheme.lossless
        thumbnail.set(bands: profile.resolvedBands(), accent: accent, isEnabled: running)
        outputLabel.stringValue = engine.output?.name ?? ""
        rebuildRows(current: profile.id)
    }

    private func rebuildRows(current: String) {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for profile in engine.state.userProfiles + EqualizerPresets.all {
            let row = MacPresetRow(
                name: EqualizerCopy.name(of: profile),
                points: BiquadMath.curve(profile.resolvedBands(), points: 40),
                isCurrent: profile.id == current,
                accent: accent
            ) { [weak self] in self?.engine.select(profileID: profile.id) }
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }

    @objc private func toggle() {
        engine.setEnabled(enableSwitch.state == .on)
    }

    @objc private func openWindow() {
        MacEqualizerWindowController.shared.show()
        view.window?.close()
    }
}

/// A preset in the quick panel: its curve, its name, a tick when it is in force.
private final class MacPresetRow: NSView {

    private let onClick: () -> Void
    private let hover = NSView()

    init(name: String, points: [Double], isCurrent: Bool, accent: NSColor, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = isCurrent ? accent.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor

        let thumb = MacCurveThumbnailView()
        thumb.setPoints(points, accent: isCurrent ? accent : .white.withAlphaComponent(0.7))
        thumb.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 13.5, weight: .medium)
        let tick = NSImageView(image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil) ?? NSImage())
        tick.contentTintColor = accent
        tick.isHidden = !isCurrent
        let row = NSStackView(views: [thumb, label, NSView(), tick])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            thumb.widthAnchor.constraint(equalToConstant: 40),
            thumb.heightAnchor.constraint(equalToConstant: 20),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(name)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        onClick()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        if layer?.backgroundColor == NSColor.clear.cgColor { layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor }
    }

    override func mouseExited(with event: NSEvent) {
        if layer?.backgroundColor == NSColor.white.withAlphaComponent(0.06).cgColor { layer?.backgroundColor = NSColor.clear.cgColor }
    }
}

/// A small non-interactive picture of a curve.
final class MacCurveThumbnailView: NSView {

    var onClick: (() -> Void)?

    private var points: [Double] = []
    private var accent: NSColor = .white
    private var isEnabled = true
    private var showsGrid = false

    override var isFlipped: Bool { true }

    func set(bands: [EqualizerBand], accent: NSColor, isEnabled: Bool) {
        points = BiquadMath.curve(bands, points: 120)
        self.accent = accent
        self.isEnabled = isEnabled
        showsGrid = true
        needsDisplay = true
    }

    func setPoints(_ points: [Double], accent: NSColor) {
        self.points = points
        self.accent = accent
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard points.count > 1 else { return }
        let rect = bounds.insetBy(dx: showsGrid ? 0 : 1, dy: showsGrid ? 8 : 2)
        if showsGrid {
            NSColor.white.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
            NSColor.white.withAlphaComponent(0.16).setStroke()
            let zero = NSBezierPath()
            zero.move(to: NSPoint(x: 0, y: rect.midY))
            zero.line(to: NSPoint(x: rect.width, y: rect.midY))
            zero.lineWidth = 1
            zero.stroke()
        }
        let range = showsGrid ? 12.0 : 9.0
        let path = NSBezierPath()
        for (index, decibels) in points.enumerated() {
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(points.count - 1)
            let clamped = min(max(decibels, -range), range)
            let y = rect.midY - CGFloat(clamped / range) * rect.height / 2
            index == 0 ? path.move(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
        }
        path.lineWidth = showsGrid ? 2.2 : 1.8
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        (isEnabled ? accent : accent.withAlphaComponent(0.4)).setStroke()
        path.stroke()
    }
}
