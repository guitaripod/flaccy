import UIKit

/// A GitHub-style contribution grid: seven day-of-week rows by as many recent
/// week-columns as fit the available width, each cell tinted by that day's play
/// count. Purely drawn, so it costs nothing to animate around and honors Reduce
/// Motion by never animating at all.
final class HeatmapView: UIView {

    private var counts: [Date: Int] = [:]
    private var tint: UIColor = .systemGreen
    private let calendar = Calendar.current
    private let cellSpacing: CGFloat = 3
    private var dataVersion = 0
    private var renderedKey = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .image
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 7 * 15 + 6 * cellSpacing) }

    func configure(counts: [Date: Int], tint: UIColor) {
        self.counts = counts
        self.tint = tint
        dataVersion += 1
        let active = counts.values.filter { $0 > 0 }.count
        accessibilityLabel = "Listening heatmap, \(active) active days"
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

    /// Renders the grid into a cached bitmap exactly once per data/size change so
    /// the surrounding collection view never re-runs the per-cell drawing.
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

    private func drawContent(in ctx: CGContext, rect: CGRect) {
        let heightCell = (rect.height - 6 * cellSpacing) / 7
        guard heightCell > 0 else { return }

        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today) - 1
        guard let lastColumnStart = calendar.date(byAdding: .day, value: -weekday, to: today) else { return }

        let earliest = counts.keys.min().map { calendar.startOfDay(for: $0) } ?? today
        let earliestWeekday = calendar.component(.weekday, from: earliest) - 1
        let firstColumnStart = calendar.date(byAdding: .day, value: -earliestWeekday, to: earliest) ?? lastColumnStart
        let spanDays = calendar.dateComponents([.day], from: firstColumnStart, to: lastColumnStart).day ?? 0
        let columns = max(1, spanDays / 7 + 1)

        let widthCell = (rect.width - CGFloat(columns - 1) * cellSpacing) / CGFloat(columns)
        let cell = max(1, min(heightCell, widthCell))
        let maxCount = max(counts.values.max() ?? 0, 1)

        for column in 0..<columns {
            guard let columnStart = calendar.date(byAdding: .day, value: 7 * column, to: firstColumnStart) else { continue }
            for row in 0..<7 {
                guard let day = calendar.date(byAdding: .day, value: row, to: columnStart) else { continue }
                if day > today { continue }
                let count = counts[day] ?? 0
                let x = CGFloat(column) * (cell + cellSpacing)
                let y = CGFloat(row) * (cell + cellSpacing)
                let cellRect = CGRect(x: x, y: y, width: cell, height: cell)
                let path = UIBezierPath(roundedRect: cellRect, cornerRadius: cell * 0.28)
                color(for: count, max: maxCount).setFill()
                path.fill()
            }
        }
    }

    private func color(for count: Int, max: Int) -> UIColor {
        guard count > 0 else { return UIColor.white.withAlphaComponent(0.06) }
        let fraction = min(1, CGFloat(count) / CGFloat(max))
        return tint.withAlphaComponent(0.25 + 0.65 * fraction)
    }
}
