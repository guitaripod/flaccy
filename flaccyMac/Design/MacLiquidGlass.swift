import AppKit

/// Liquid Glass material factory for the mac app, mirroring the iOS
/// `LiquidGlass` helper: real glass by default, a solid vibrancy material when
/// the user reduces transparency.
enum MacLiquidGlass {

    static var prefersReducedTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    /// A glass surface hosting the given content view, clipped to the corner
    /// radius, with an `NSVisualEffectView` fallback under Reduce Transparency.
    static func surface(hosting content: NSView, cornerRadius: CGFloat, tint: NSColor? = nil) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
        guard !prefersReducedTransparency else {
            let fallback = NSVisualEffectView()
            fallback.material = .hudWindow
            fallback.blendingMode = .withinWindow
            fallback.state = .active
            fallback.wantsLayer = true
            fallback.layer?.cornerRadius = cornerRadius
            fallback.layer?.cornerCurve = .continuous
            fallback.layer?.masksToBounds = true
            fallback.addSubview(content)
            pin(content, to: fallback)
            return fallback
        }
        let glass = NSGlassEffectView()
        glass.cornerRadius = cornerRadius
        if let tint { glass.tintColor = tint }
        glass.contentView = content
        return glass
    }

    /// A grouping container that lets adjacent glass shapes merge and morph as
    /// one; returns the content unchanged when transparency is reduced.
    static func grouping(_ content: NSView, spacing: CGFloat = 8) -> NSView {
        guard !prefersReducedTransparency else { return content }
        let container = NSGlassEffectContainerView()
        container.spacing = spacing
        container.contentView = content
        return container
    }

    /// A capsule-shaped solid fill matching the iOS reduced-transparency
    /// capsule look, used for badges over artwork where glass would be noise.
    static func solidCapsule(cornerRadius: CGFloat) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    private static func pin(_ content: NSView, to host: NSView) {
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: host.topAnchor),
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }
}
