import AppKit

/// 24-hour radial listening clock ported from the iOS drawing math, upgraded
/// with hover tooltips reporting each hour's play count.
final class MacListeningClockView: NSView {

    private var buckets = [Int](repeating: 0, count: 24)
    private var tint: NSColor = .systemIndigo
    private var tooltipOwners: [NSString] = []

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 220) }

    func configure(buckets: [Int], tint: NSColor) {
        self.buckets = buckets.count == 24 ? buckets : [Int](repeating: 0, count: 24)
        self.tint = tint
        needsDisplay = true
        rebuildTooltips()
        setAccessibilityRole(.image)
        setAccessibilityLabel(accessibilitySummary())
    }

    override func layout() {
        super.layout()
        needsDisplay = true
        rebuildTooltips()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2 - 6
        let inner = outer * 0.42
        let maxCount = max(buckets.max() ?? 0, 1)

        let trackColor = NSColor.white.withAlphaComponent(0.08)
        for hour in 0..<24 {
            let angle = drawAngle(hour: hour)
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
        drawCenter(center: center)
    }

    /// AppKit's default coordinate space is y-up, so noon must point at +π/2
    /// where the iOS port used −π/2, and hours advance clockwise (negative).
    private func drawAngle(hour: Int) -> CGFloat {
        .pi / 2 - CGFloat(hour) / 24 * (.pi * 2)
    }

    private func drawSpoke(_ ctx: CGContext, from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat) {
        ctx.setLineCap(.round)
        ctx.setLineWidth(width)
        ctx.setStrokeColor(color.cgColor)
        ctx.move(to: from)
        ctx.addLine(to: to)
        ctx.strokePath()
    }

    private func drawCenter(center: CGPoint) {
        let total = buckets.reduce(0, +)
        guard total > 0, let peak = buckets.enumerated().max(by: { $0.element < $1.element })?.offset else { return }
        let text = String(format: "%02d:00", peak)
        let caption = "PEAK"
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .bold), .foregroundColor: NSColor.white,
        ]
        let captionAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
        ]
        let valueSize = (text as NSString).size(withAttributes: valueAttrs)
        let captionSize = (caption as NSString).size(withAttributes: captionAttrs)
        let totalHeight = valueSize.height + captionSize.height
        (text as NSString).draw(
            at: CGPoint(x: center.x - valueSize.width / 2, y: center.y - totalHeight / 2),
            withAttributes: valueAttrs
        )
        (caption as NSString).draw(
            at: CGPoint(x: center.x - captionSize.width / 2, y: center.y - totalHeight / 2 + valueSize.height),
            withAttributes: captionAttrs
        )
    }

    private func rebuildTooltips() {
        removeAllToolTips()
        tooltipOwners = []
        guard bounds.width > 0 else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let outer = min(bounds.width, bounds.height) / 2 - 6
        let inner = outer * 0.42
        for hour in 0..<24 {
            let angle = drawAngle(hour: hour)
            let mid = (inner + outer) / 2
            let point = CGPoint(x: center.x + cos(angle) * mid, y: center.y + sin(angle) * mid)
            let rect = NSRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18)
            let plays = buckets[hour]
            let owner = String(format: "%02d:00 — %d play%@", hour, plays, plays == 1 ? "" : "s") as NSString
            tooltipOwners.append(owner)
            addToolTip(rect, owner: owner, userData: nil)
        }
    }

    private func accessibilitySummary() -> String {
        let total = buckets.reduce(0, +)
        guard total > 0, let peak = buckets.enumerated().max(by: { $0.element < $1.element })?.offset else {
            return "Listening clock, no plays yet"
        }
        return "Listening clock. Peak hour \(peak):00 with \(buckets[peak]) plays."
    }
}

/// GitHub-style contribution heatmap: full-width on desktop, with month labels
/// along the top edge and hover tooltips carrying per-day play counts.
final class MacHeatmapView: NSView {

    private var counts: [Date: Int] = [:]
    private var tint: NSColor = .systemGreen
    private var tooltipOwners: [NSString] = []
    private let calendar = Calendar.current
    private let cellSpacing: CGFloat = 3
    private let labelHeight: CGFloat = 16

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 7 * 15 + 6 * cellSpacing + labelHeight)
    }

    func configure(counts: [Date: Int], tint: NSColor) {
        self.counts = counts
        self.tint = tint
        needsDisplay = true
        rebuildTooltips()
        let active = counts.values.filter { $0 > 0 }.count
        setAccessibilityRole(.image)
        setAccessibilityLabel("Listening heatmap, \(active) active days")
    }

    override func layout() {
        super.layout()
        needsDisplay = true
        rebuildTooltips()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let grid = gridMetrics() else { return }
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMM"
        var lastLabeledMonth = -1

        for column in 0..<grid.columns {
            guard let columnStart = calendar.date(byAdding: .day, value: 7 * column, to: grid.firstColumnStart) else { continue }
            let month = calendar.component(.month, from: columnStart)
            let x = CGFloat(column) * (grid.cell + cellSpacing)
            if month != lastLabeledMonth, calendar.component(.day, from: columnStart) <= 7 || column == 0 {
                lastLabeledMonth = month
                (monthFormatter.string(from: columnStart) as NSString).draw(
                    at: CGPoint(x: x, y: 0),
                    withAttributes: [
                        .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                        .foregroundColor: NSColor.white.withAlphaComponent(0.45),
                    ]
                )
            }
            for row in 0..<7 {
                guard let day = calendar.date(byAdding: .day, value: row, to: columnStart) else { continue }
                if day > grid.today { continue }
                let count = counts[day] ?? 0
                let y = labelHeight + CGFloat(row) * (grid.cell + cellSpacing)
                let cellRect = CGRect(x: x, y: y, width: grid.cell, height: grid.cell)
                let path = NSBezierPath(roundedRect: cellRect, xRadius: grid.cell * 0.28, yRadius: grid.cell * 0.28)
                color(for: count, max: grid.maxCount).setFill()
                path.fill()
            }
        }
    }

    private struct GridMetrics {
        let columns: Int
        let cell: CGFloat
        let firstColumnStart: Date
        let today: Date
        let maxCount: Int
    }

    private func gridMetrics() -> GridMetrics? {
        let gridHeight = bounds.height - labelHeight
        let heightCell = (gridHeight - 6 * cellSpacing) / 7
        guard heightCell > 0, bounds.width > 0 else { return nil }

        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today) - 1
        guard let lastColumnStart = calendar.date(byAdding: .day, value: -weekday, to: today) else { return nil }

        let earliest = counts.keys.min().map { calendar.startOfDay(for: $0) } ?? today
        let earliestWeekday = calendar.component(.weekday, from: earliest) - 1
        let firstColumnStart = calendar.date(byAdding: .day, value: -earliestWeekday, to: earliest) ?? lastColumnStart
        let spanDays = calendar.dateComponents([.day], from: firstColumnStart, to: lastColumnStart).day ?? 0
        let columns = max(1, spanDays / 7 + 1)

        let widthCell = (bounds.width - CGFloat(columns - 1) * cellSpacing) / CGFloat(columns)
        let cell = max(1, min(heightCell, widthCell))
        return GridMetrics(
            columns: columns, cell: cell, firstColumnStart: firstColumnStart,
            today: today, maxCount: max(counts.values.max() ?? 0, 1)
        )
    }

    private func rebuildTooltips() {
        removeAllToolTips()
        tooltipOwners = []
        guard let grid = gridMetrics() else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        for column in 0..<grid.columns {
            guard let columnStart = calendar.date(byAdding: .day, value: 7 * column, to: grid.firstColumnStart) else { continue }
            for row in 0..<7 {
                guard let day = calendar.date(byAdding: .day, value: row, to: columnStart) else { continue }
                if day > grid.today { continue }
                let count = counts[day] ?? 0
                let rect = NSRect(
                    x: CGFloat(column) * (grid.cell + cellSpacing),
                    y: labelHeight + CGFloat(row) * (grid.cell + cellSpacing),
                    width: grid.cell, height: grid.cell
                )
                let owner = "\(formatter.string(from: day)) — \(count) play\(count == 1 ? "" : "s")" as NSString
                tooltipOwners.append(owner)
                addToolTip(rect, owner: owner, userData: nil)
            }
        }
    }

    private func color(for count: Int, max: Int) -> NSColor {
        guard count > 0 else { return NSColor.white.withAlphaComponent(0.06) }
        let fraction = min(1, CGFloat(count) / CGFloat(max))
        return tint.withAlphaComponent(0.25 + 0.65 * fraction)
    }
}
