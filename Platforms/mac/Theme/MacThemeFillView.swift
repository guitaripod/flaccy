import AppKit
import FlaccyCore

/// A plain fill in one of the worn theme's surfaces, laid behind a part of
/// the window the system would otherwise draw in its own material: the
/// sidebar, the strip under the toolbar. Under Flaccy's own theme it draws
/// nothing at all and the system's material shows as it always did.
final class MacThemeFillView: NSView {

    private let surface: MacThemedColor

    init(_ surface: MacThemedColor) {
        self.surface = surface
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = ThemePalettes.isPainting ? surface.color.cgColor : nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Lays the fill behind everything else in `host`, edge to edge.
    func install(behind host: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(self, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: host.topAnchor),
            leadingAnchor.constraint(equalTo: host.leadingAnchor),
            trailingAnchor.constraint(equalTo: host.trailingAnchor),
            bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }
}
