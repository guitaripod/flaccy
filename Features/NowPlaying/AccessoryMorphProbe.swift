#if DEBUG
import MidgarCore
import QuartzCore
import UIKit

/// Logs where the mini player's parts sit on screen on every frame that moves
/// one of them, so a capture shows whether they travel with the tab accessory
/// as it drops inline beside the minimized tab bar and rises again, or jump.
/// On with `FLACCY_ACCESSORY_PROBE=1`; `scripts/accessory-morph-check.py`
/// reads the lines, `ACCESSORY PROBE <ms> <part>=<minX>,<midY>,<width>,<alpha>`.
/// `FLACCY_ACCESSORY_PROBE=drill` also moves the mini player between the two
/// places itself, four times, two seconds apart, by overriding the accessory
/// environment trait: a simulator scrolled by a test never minimizes the bar.
@MainActor
final class AccessoryMorphProbe {

    private static let mode = ProcessInfo.processInfo.environment["FLACCY_ACCESSORY_PROBE"]

    static let shared = mode == "1" || mode == "drill" ? AccessoryMorphProbe() : nil

    private var link: CADisplayLink?
    private var parts: [(name: String, view: UIView)] = []
    private let startedAt = CACurrentMediaTime()
    private var lastLine = ""

    func watch(_ parts: [(name: String, view: UIView)]) {
        self.parts = parts
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        if Self.mode == "drill", let host = parts.first?.view { drill(host, step: 0) }
    }

    private func drill(_ host: UIView, step: Int) {
        guard #available(iOS 26.0, *), step < 4 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak host] in
            guard let self, let host else { return }
            host.traitOverrides.tabAccessoryEnvironment = step.isMultiple(of: 2) ? .inline : .regular
            self.drill(host, step: step + 1)
        }
    }

    func noteEnvironment(inline: Bool) {
        MidgarLog.info(
            "ACCESSORY PROBE \(elapsedMilliseconds) change inline=\(inline) inheritedDuration=\(UIView.inheritedAnimationDuration)",
            category: .ui
        )
    }

    private var elapsedMilliseconds: Int { Int((CACurrentMediaTime() - startedAt) * 1000) }

    @objc private func tick() {
        let line = parts.map { "\($0.name)=\(Self.describe($0.view))" }.joined(separator: " ")
        guard line != lastLine else { return }
        lastLine = line
        MidgarLog.info("ACCESSORY PROBE \(elapsedMilliseconds) \(line)", category: .ui)
    }

    /// The part's on-screen frame and opacity as Core Animation draws them this frame.
    private static func describe(_ view: UIView) -> String {
        guard let window = view.window, let layer = view.layer.presentation() else { return "offscreen" }
        let frame = layer.convert(layer.bounds, to: window.layer.presentation() ?? window.layer)
        var alpha = view.layer.isHidden ? 0 : layer.opacity
        var ancestor = view.superview
        while let current = ancestor, current !== window {
            alpha *= current.layer.isHidden ? 0 : current.layer.presentation()?.opacity ?? current.layer.opacity
            ancestor = current.superview
        }
        return String(format: "%.1f,%.1f,%.1f,%.2f", frame.minX, frame.midY, frame.width, alpha)
    }
}
#endif
