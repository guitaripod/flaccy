import AppKit

/// The shape of the Mac's Home while its first frame is built: the hero's
/// cover and words, the Jump Back In panel when the window is wide enough for
/// it, and a shelf of mixes, as soft blocks that breathe in a wave. It waits
/// `patience` before showing, so a quick launch never sees it.
final class MacHomeLaunchPlaceholderView: NSView {

    static let patience: TimeInterval = 0.25

    private static let coverSide = MacHomeHeroView.coverSide
    private static let textGap = MacHomeHeroView.spacing
    private static let cardSide: CGFloat = 164
    private static let cardGap: CGFloat = 18
    private static let pulseKey = "home.placeholder.pulse"

    private var blocks: [CALayer] = []
    private var arrangedWidth: CGFloat = -1
    private var pendingAppearance: DispatchWorkItem?
    private var isShowing = false

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard bounds.width != arrangedWidth, bounds.width > 0 else { return }
        arrangedWidth = bounds.width
        rebuild()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        arrangedWidth = -1
        needsLayout = true
    }

    /// Fades the blocks up once `patience` has passed, unless the page was
    /// ready first.
    func appear() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isShowing = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                self.animator().alphaValue = 1
            }
            self.startPulse()
        }
        pendingAppearance = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.patience, execute: work)
    }

    /// Fades out under the arriving page and leaves the hierarchy.
    func dismiss() {
        pendingAppearance?.cancel()
        pendingAppearance = nil
        guard isShowing else {
            removeFromSuperview()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.removeFromSuperview() }
        })
    }

    private func rebuild() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blocks.forEach { $0.removeFromSuperlayer() }
        blocks = []
        let width = bounds.width
        let side = Self.coverSide
        addBlock(CGRect(x: 0, y: 0, width: side, height: side), radius: 12)

        let textX = side + Self.textGap
        let textWidth = min(MacHomeHeroView.textWidth, max(width - textX, 0))
        addBlock(CGRect(x: textX, y: 24, width: textWidth * 0.35, height: 12), radius: 4)
        addBlock(CGRect(x: textX, y: 48, width: textWidth * 0.85, height: 28), radius: 6)
        addBlock(CGRect(x: textX, y: 88, width: textWidth * 0.6, height: 14), radius: 4)
        addBlock(CGRect(x: textX, y: side - 40, width: 132, height: 36), radius: 18)
        addBlock(CGRect(x: textX + 144, y: side - 40, width: 36, height: 36), radius: 18)

        let panelWidth = MacHomeJumpBackInPanel.width
        if width >= textX + MacHomeHeroView.textWidth + 24 + panelWidth {
            addBlock(CGRect(x: width - panelWidth, y: 0, width: panelWidth, height: side), radius: 14)
        }

        let shelfTop = side + 40
        addBlock(CGRect(x: 0, y: shelfTop, width: 150, height: 18), radius: 5)
        var x: CGFloat = 0
        while x + Self.cardSide <= width {
            addBlock(CGRect(x: x, y: shelfTop + 34, width: Self.cardSide, height: Self.cardSide), radius: 10)
            x += Self.cardSide + Self.cardGap
        }
        CATransaction.commit()
        if isShowing { startPulse() }
    }

    private func addBlock(_ frame: CGRect, radius: CGFloat) {
        let block = CALayer()
        block.frame = frame
        block.cornerRadius = radius
        block.cornerCurve = .continuous
        effectiveAppearance.performAsCurrentDrawingAppearance {
            block.backgroundColor = MacColors.fill(0.08, light: 0.06).cgColor
        }
        layer?.addSublayer(block)
        blocks.append(block)
    }

    /// Each block dims and returns a beat after the one before it, so the
    /// light seems to travel across the page.
    private func startPulse() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let now = CACurrentMediaTime()
        for (index, block) in blocks.enumerated() {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.45
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pulse.beginTime = now + Double(index) * 0.06
            pulse.fillMode = .backwards
            block.add(pulse, forKey: Self.pulseKey)
        }
    }
}
