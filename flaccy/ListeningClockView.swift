import UIKit

/// A 24-hour radial visualization of listening activity: one spoke per hour of
/// the day, its length proportional to that hour's share of plays. Palette
/// tinted, redrawn on trait changes, and static under Reduce Motion.
final class ListeningClockView: UIView {

    private var buckets = [Int](repeating: 0, count: 24)
    private var tint: UIColor = .systemIndigo
    private var dataVersion = 0
    private var renderedKey = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .image
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 220) }

    func configure(buckets: [Int], tint: UIColor) {
        self.buckets = buckets.count == 24 ? buckets : [Int](repeating: 0, count: 24)
        self.tint = tint
        dataVersion += 1
        accessibilityLabel = accessibilitySummary()
        setNeedsLayout()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        renderIfNeeded()
    }

    /// Renders the clock into a cached bitmap exactly once per data/size change
    /// so scrolling never re-runs the vector drawing.
    private func renderIfNeeded() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        var hasher = Hasher()
        hasher.combine(dataVersion)
        hasher.combine(Int(bounds.width.rounded()))
        hasher.combine(Int(bounds.height.rounded()))
        hasher.combine(traitCollection.userInterfaceStyle.rawValue)
        let key = hasher.finalize()
        guard key != renderedKey else { return }
        renderedKey = key

        let bounds = self.bounds
        let format = UIGraphicsImageRendererFormat.preferred()
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            self.drawContent(in: context.cgContext, rect: bounds)
        }
        layer.contents = image.cgImage
        layer.contentsScale = image.scale
    }

    private func accessibilitySummary() -> String {
        let total = buckets.reduce(0, +)
        guard total > 0, let peak = buckets.enumerated().max(by: { $0.element < $1.element })?.offset else {
            return "Listening clock, no plays yet"
        }
        return "Listening clock. Peak hour \(peak) hundred hours, with \(buckets[peak]) plays."
    }

    private func drawContent(in ctx: CGContext, rect: CGRect) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2 - 6
        let inner = outer * 0.42
        let maxCount = max(buckets.max() ?? 0, 1)

        let trackColor = UIColor.white.withAlphaComponent(0.08)
        for hour in 0..<24 {
            let angle = CGFloat(hour) / 24 * (.pi * 2) - .pi / 2
            let fraction = CGFloat(buckets[hour]) / CGFloat(maxCount)
            let tipRadius = inner + (outer - inner) * fraction

            let start = CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner)
            let trackEnd = CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer)
            drawSpoke(ctx, from: start, to: trackEnd, color: trackColor, width: 3)

            if buckets[hour] > 0 {
                let end = CGPoint(x: center.x + cos(angle) * tipRadius, y: center.y + sin(angle) * tipRadius)
                let color = tint.withAlphaComponent(0.45 + 0.55 * fraction)
                drawSpoke(ctx, from: start, to: end, color: color, width: 5)
            }
        }

        drawCenter(ctx, center: center, radius: inner - 6)
    }

    private func drawSpoke(_ ctx: CGContext, from: CGPoint, to: CGPoint, color: UIColor, width: CGFloat) {
        ctx.setLineCap(.round)
        ctx.setLineWidth(width)
        ctx.setStrokeColor(color.cgColor)
        ctx.move(to: from)
        ctx.addLine(to: to)
        ctx.strokePath()
    }

    private func drawCenter(_ ctx: CGContext, center: CGPoint, radius: CGFloat) {
        let total = buckets.reduce(0, +)
        guard total > 0, let peak = buckets.enumerated().max(by: { $0.element < $1.element })?.offset else { return }
        let text = String(format: "%02d:00", peak)
        let caption = "peak"
        let valueFont = UIFont.scaled(.title3, size: 20, weight: .bold)
        let captionFont = UIFont.scaled(.caption2, size: 11, weight: .semibold)
        let valueAttrs: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: UIColor.white]
        let captionAttrs: [NSAttributedString.Key: Any] = [.font: captionFont, .foregroundColor: UIColor.white.withAlphaComponent(0.6)]
        let valueSize = (text as NSString).size(withAttributes: valueAttrs)
        let captionSize = (caption as NSString).size(withAttributes: captionAttrs)
        let totalHeight = valueSize.height + captionSize.height
        (caption.uppercased() as NSString).draw(
            at: CGPoint(x: center.x - captionSize.width / 2, y: center.y - totalHeight / 2),
            withAttributes: captionAttrs
        )
        (text as NSString).draw(
            at: CGPoint(x: center.x - valueSize.width / 2, y: center.y - totalHeight / 2 + captionSize.height),
            withAttributes: valueAttrs
        )
    }
}
