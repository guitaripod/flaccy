import AppKit
import FlaccyCore

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// What the panel needs from each row of lyrics, whether it is a sung line or
/// an instrumental stretch.
protocol LyricRowView: NSView {
    var onClick: (() -> Void)? { get set }
    var contextMenuProvider: (() -> NSMenu?)? { get set }
    func setCurrent(_ current: Bool, reduceMotion: Bool)
    func show(_ line: LyricsLine, time: TimeInterval)
    func clearProgress()
}

/// Draws the line being sung with the sung part in one colour and the rest in
/// another, the edge following the words. It sits over the line's label while
/// a line with timed words is current, and is hidden otherwise.
private final class LyricWipeView: NSView {

    private var layoutCache: LyricWipeLayout?
    private var edge: LyricWipeEdge = .nothing
    private var text = ""
    private var words: [LyricsWord] = []
    private var font = NSFont.systemFont(ofSize: 17, weight: .bold)

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(text: String, words: [LyricsWord], font: NSFont) {
        self.text = text
        self.words = words
        self.font = font
        layoutCache = nil
        edge = .nothing
    }

    /// Moves the edge to a clock position, or hides the view for `nil`.
    func show(_ progress: LyricsLineProgress?) {
        guard let progress, !words.isEmpty else {
            isHidden = true
            return
        }
        guard let layout = currentLayout() else { return }
        let next = layout.edge(for: progress)
        if isHidden || next != edge {
            edge = next
            isHidden = false
            needsDisplay = true
        }
    }

    override func layout() {
        super.layout()
        if let layoutCache, abs(layoutCache.width - bounds.width) > 0.5 {
            self.layoutCache = nil
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let layout = currentLayout() else { return }
        layout.draw(edge: edge, in: context)
    }

    private func currentLayout() -> LyricWipeLayout? {
        if let layoutCache { return layoutCache }
        guard bounds.width > 1 else { return nil }
        let built = LyricWipeLayout(
            text: text, words: words, font: font, width: bounds.width,
            bright: .labelColor, dim: NSColor.labelColor.withAlphaComponent(0.4)
        )
        layoutCache = built
        return built
    }
}

/// One clickable lyric line; current-line emphasis animates alpha and a
/// leading-anchored scale, and a line with timed words fills as it is sung.
final class LyricLineView: NSView, LyricRowView {

    var onClick: (() -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?

    private let label = NSTextField(wrappingLabelWithString: "")
    private let wipeView = LyricWipeView()

    init(line: LyricsLine) {
        super.init(frame: .zero)
        wantsLayer = true
        label.stringValue = line.text
        label.font = .systemFont(ofSize: line.background ? 15 : 17, weight: line.background ? .semibold : .bold)
        label.textColor = .labelColor
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(wipeView)
        wipeView.configure(text: line.text, words: line.words, font: label.font ?? .systemFont(ofSize: 17))
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        addGestureRecognizer(click)
        setAccessibilityLabel(line.text)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let textRect = label.cell?.titleRect(forBounds: label.bounds) ?? label.bounds
        wipeView.frame = CGRect(
            x: label.frame.minX + textRect.minX, y: label.frame.minY,
            width: textRect.width, height: label.frame.height
        )
    }

    func setCurrent(_ current: Bool, reduceMotion: Bool) {
        alphaValue = current ? 1 : 0.35
        guard let layer else { return }
        layer.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer.position = CGPoint(x: frame.minX, y: frame.midY)
        let scale: CGFloat = current || reduceMotion ? 1 : 0.86
        layer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
    }

    func show(_ line: LyricsLine, time: TimeInterval) {
        wipeView.show(line.progress(at: time))
        label.isHidden = !wipeView.isHidden
    }

    func clearProgress() {
        wipeView.show(nil)
        label.isHidden = false
    }

    @objc private func clicked() {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?() ?? super.menu(for: event)
    }
}

/// An instrumental stretch: three beats that light one after another across
/// the gap, so a pause in the singing reads as part of the song.
final class InterludeLineView: NSView, LyricRowView {

    var onClick: (() -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?

    private let beats: [NSView] = (0..<LyricsDocument.interludeBeats).map { _ in
        let beat = NSView()
        beat.wantsLayer = true
        beat.layer?.cornerRadius = 4
        beat.layer?.backgroundColor = NSColor.labelColor.cgColor
        beat.alphaValue = InterludeLineView.unlitAlpha
        return beat
    }
    private static let unlitAlpha: CGFloat = 0.25

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        let stack = NSStackView(views: beats)
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
        ])
        for beat in beats {
            beat.widthAnchor.constraint(equalToConstant: 8).isActive = true
            beat.heightAnchor.constraint(equalToConstant: 8).isActive = true
        }
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setCurrent(_ current: Bool, reduceMotion: Bool) {
        alphaValue = current ? 1 : 0.35
    }

    func show(_ line: LyricsLine, time: TimeInterval) {
        let lit = line.litBeats(at: time)
        for (index, beat) in beats.enumerated() {
            let target = index < lit ? 1 : Self.unlitAlpha
            guard beat.alphaValue != target else { continue }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                beat.alphaValue = target
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.26
                    beat.animator().alphaValue = target
                }
            }
        }
    }

    func clearProgress() {
        for beat in beats { beat.alphaValue = Self.unlitAlpha }
    }

    @objc private func clicked() {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?() ?? super.menu(for: event)
    }
}
