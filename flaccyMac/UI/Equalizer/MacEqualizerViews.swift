import AppKit
import FlaccyCore
import UniformTypeIdentifiers

/// A band in the Simple strip: its frequency (click to reset), an editable gain, and a pair of steppers.
final class MacBandCell: NSStackView, NSTextFieldDelegate {

    var onReset: (() -> Void)?
    var onStep: ((Double) -> Void)?
    var onType: ((Double) -> Void)?
    var onFocus: (() -> Void)?

    let frequencyButton = NSButton()
    let valueField = NSTextField()
    let up = NSButton()
    let down = NSButton()
    let selectionLayer = CALayer()

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

    @objc func resetPressed() { onReset?() }
    @objc func stepUp() { onStep?(0.5) }
    @objc func stepDown() { onStep?(-0.5) }

    @objc func valueCommitted() {
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

    var fraction: CGFloat = 0
    var color: NSColor = EqualizerTheme.lossless

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

    let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func run() {
        let handler = handler
        MainActor.assumeIsolated { handler() }
    }
}
