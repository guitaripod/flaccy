import AppKit

/// Lets a view that takes picture drops stay out of the way of the window-wide
/// drop that imports music: anything that is not a picture is handed to the
/// window's `AudioDropView`, because a registered descendant that refuses a
/// drag ends it instead of letting the ancestor have it.
@MainActor
final class ArtworkDropRelay {

    private weak var view: NSView?
    private var isRelaying = false
    private(set) var operation: NSDragOperation = []

    init(view: NSView) {
        self.view = view
    }

    private var audioDestination: AudioDropView? {
        var current = view?.superview
        while let candidate = current {
            if let drop = candidate as? AudioDropView { return drop }
            current = candidate.superview
        }
        return nil
    }

    func carriesPicture(_ sender: NSDraggingInfo) -> Bool {
        ArtworkInputReader.input(from: sender.draggingPasteboard) != nil
    }

    func relayEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isRelaying = true
        operation = audioDestination?.draggingEntered(sender) ?? []
        return operation
    }

    func relayExited(_ sender: NSDraggingInfo?) {
        guard isRelaying else { return }
        isRelaying = false
        audioDestination?.draggingExited(sender)
    }

    func relayPerform(_ sender: NSDraggingInfo) -> Bool {
        guard isRelaying else { return false }
        isRelaying = false
        return audioDestination?.performDragOperation(sender) ?? false
    }

    func relayEnded(_ sender: NSDraggingInfo) {
        isRelaying = false
        audioDestination?.draggingEnded(sender)
    }

    var isActive: Bool { isRelaying }

    func endRelay() {
        isRelaying = false
        operation = []
    }
}

/// A button that says out loud when keyboard focus reaches it, so a control
/// that only shows on hover can also show on focus.
final class FocusReportingButton: NSButton {

    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }
}

/// Sits over an album's cover: a pencil that fades in under the pointer or on
/// keyboard focus, a drop target for a picture, and the cover's own context
/// menu.
final class ArtworkEditOverlayView: NSView {

    var onEdit: (() -> Void)?
    var onDrop: ((ArtworkInput) -> Void)?
    var onMenu: (() -> NSMenu?)?

    var ringCornerRadius: CGFloat = 14 {
        didSet { dropRing.layer?.cornerRadius = ringCornerRadius }
    }

    var editLabel = String(localized: "Edit Artwork") {
        didSet {
            pencil.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: editLabel)
            pencil.toolTip = editLabel
            pencil.setAccessibilityLabel(editLabel)
        }
    }

    private let pencil = FocusReportingButton()
    private let dropRing = NSView()
    private lazy var relay = ArtworkDropRelay(view: self)
    private var isHovering = false
    private var hasFocus = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes(ArtworkInputReader.pasteboardTypes)

        dropRing.wantsLayer = true
        dropRing.layer?.borderColor = NSColor.controlAccentColor.cgColor
        dropRing.layer?.borderWidth = 3
        dropRing.layer?.cornerRadius = 14
        dropRing.layer?.cornerCurve = .continuous
        dropRing.isHidden = true
        dropRing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dropRing)

        let label = editLabel
        pencil.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: label)
        pencil.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        pencil.imagePosition = .imageOnly
        pencil.isBordered = false
        pencil.contentTintColor = MacColors.onArtwork()
        pencil.wantsLayer = true
        pencil.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        pencil.layer?.cornerRadius = 15
        pencil.focusRingType = .exterior
        pencil.toolTip = label
        pencil.setAccessibilityLabel(label)
        pencil.target = self
        pencil.action = #selector(editTapped)
        pencil.alphaValue = 0
        pencil.onFocusChange = { [weak self] focused in
            self?.hasFocus = focused
            self?.updatePencil()
        }
        pencil.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pencil)

        NSLayoutConstraint.activate([
            dropRing.topAnchor.constraint(equalTo: topAnchor),
            dropRing.leadingAnchor.constraint(equalTo: leadingAnchor),
            dropRing.trailingAnchor.constraint(equalTo: trailingAnchor),
            dropRing.bottomAnchor.constraint(equalTo: bottomAnchor),
            pencil.widthAnchor.constraint(equalToConstant: 30),
            pencil.heightAnchor.constraint(equalToConstant: 30),
            pencil.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            pencil.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func editTapped() {
        onEdit?()
    }

    private func updatePencil() {
        let visible = isHovering || hasFocus
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            pencil.animator().alphaValue = visible ? 1 : 0
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updatePencil()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updatePencil()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onMenu?()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard relay.carriesPicture(sender) else { return relay.relayEntered(sender) }
        relay.endRelay()
        dropRing.isHidden = false
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        relay.isActive ? relay.operation : (relay.carriesPicture(sender) ? .copy : [])
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropRing.isHidden = true
        relay.relayExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropRing.isHidden = true
        relay.relayEnded(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropRing.isHidden = true
        if relay.isActive { return relay.relayPerform(sender) }
        guard let input = ArtworkInputReader.input(from: sender.draggingPasteboard) else { return false }
        onDrop?(input)
        return true
    }
}
