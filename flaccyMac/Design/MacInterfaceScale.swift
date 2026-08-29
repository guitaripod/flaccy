import AppKit

extension Notification.Name {
    static let flaccyInterfaceScaleChanged = Notification.Name("flaccy.mac.interfaceScaleChanged")
}

/// Whole-window zoom driven by ⌘= / ⌘- / ⌘0, persisted the way the Linux
/// client keeps `ui_scale`: same 75–200 % range, same 10 % step. Lyrics keep
/// their own Dynamic Type sizing on top of this.
enum MacInterfaceScale {

    static let minimum: CGFloat = 0.75
    static let maximum: CGFloat = 2.0
    static let step: CGFloat = 0.1
    static let standard: CGFloat = 1.0

    private static let key = "flaccy.mac.interfaceScale"

    static var current: CGFloat {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return standard }
        return clamp(CGFloat(defaults.double(forKey: key)))
    }

    static var percent: Int { Int((current * 100).rounded()) }

    /// Snaps onto the step grid inside the range so repeated ⌘= / ⌘- never
    /// accumulate float drift.
    static func clamp(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else { return standard }
        let bounded = min(max(scale, minimum), maximum)
        return ((bounded / step).rounded() * step * 100).rounded() / 100
    }

    @discardableResult
    static func set(_ scale: CGFloat) -> CGFloat {
        let scale = clamp(scale)
        if scale != current {
            UserDefaults.standard.set(Double(scale), forKey: key)
            NotificationCenter.default.post(name: .flaccyInterfaceScaleChanged, object: nil)
        }
        return scale
    }

    static func zoomIn() -> CGFloat { set(current + step) }
    static func zoomOut() -> CGFloat { set(current - step) }
    static func reset() -> CGFloat { set(standard) }
}

/// The one view that carries the zoom. It fills its superview by autoresizing
/// mask — never by constraints, since the window's own content view lays out
/// at frame size and would fight a scaled bounds — and every zoomed surface
/// (split view, transport, status strip, the Now Playing overlay) lives inside
/// it. Scaling the unit square keeps Auto Layout, hit-testing and text
/// rendering consistent: children lay out in a smaller coordinate space and
/// are drawn larger.
final class InterfaceZoomHostView: NSView {

    /// Where zoomed content goes. Its frame is set by hand to the host's
    /// scaled bounds on every layout pass — Auto Layout against the host itself
    /// resolves at frame size and ignores the bounds transform, so the
    /// constraints inside must hang off this view instead.
    let content = InterfaceZoomContentView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        content.autoresizingMask = []
        addSubview(content)
        NotificationCenter.default.addObserver(
            self, selector: #selector(scaleChanged), name: .flaccyInterfaceScaleChanged, object: nil
        )
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyScale()
    }

    override func layout() {
        super.layout()
        if content.frame != bounds {
            content.frame = bounds
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyScale()
    }

    @objc private func scaleChanged() {
        applyScale()
    }

    private func applyScale() {
        let scale = MacInterfaceScale.current
        let target = NSSize(width: frame.width / scale, height: frame.height / scale)
        guard frame.width > 0, frame.height > 0,
              abs(bounds.width - target.width) > 0.01 || abs(bounds.height - target.height) > 0.01
        else { return }
        setBoundsOrigin(.zero)
        setBoundsSize(target)
        content.frame = bounds
        needsLayout = true
        AppLogger.info("Interface scale \(Int(scale * 100))% — frame \(frame.size), bounds \(bounds.size)", category: .ui)
    }
}

/// The view zoomed content is constrained against.
final class InterfaceZoomContentView: NSView {

    /// Reports every view added on top, so the owner can keep a floating
    /// surface in front of a full-window overlay it does not install itself.
    var onSubviewAdded: ((NSView) -> Void)?

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        onSubviewAdded?(subview)
    }
}
