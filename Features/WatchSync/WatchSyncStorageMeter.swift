import UIKit

/// How the watch's storage divides up, as reported by its last heartbeat.
struct WatchStorageBreakdown: Equatable {

    let flaccy: Int64
    let other: Int64
    let free: Int64
    let total: Int64

    /// Nil until the watch has reported a capacity, so the meter stays hidden
    /// rather than drawing a bar that means nothing.
    @MainActor
    static func current(service: WatchSyncService) -> WatchStorageBreakdown? {
        let total = service.watchTotalBytes
        guard total > 0 else { return nil }
        let free = min(max(0, service.watchFreeBytes), total)
        let flaccy = min(max(0, service.watchUsedBytes), total - free)
        return WatchStorageBreakdown(flaccy: flaccy, other: max(0, total - free - flaccy), free: free, total: total)
    }
}

/// A rounded, segmented bar with a legend: what Flaccy's music takes on the
/// watch, what everything else takes, and what is left.
final class WatchSyncStorageMeterView: UIView {

    private let titleLabel = UILabel()
    private let freeLabel = UILabel()
    private let bar = SegmentedBarView()
    private let legend = UIStackView()
    private let legendItems = [LegendItemView(), LegendItemView(), LegendItemView()]
    private var breakdown: WatchStorageBreakdown?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        titleLabel.text = String(localized: "Watch Storage")
        titleLabel.font = .watchSyncFont(.subheadline, weight: .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0

        freeLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        freeLabel.adjustsFontForContentSizeCategory = true
        freeLabel.textColor = .secondaryLabel
        freeLabel.textAlignment = .right
        freeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let header = UIStackView(arrangedSubviews: [titleLabel, freeLabel])
        header.axis = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8

        legend.distribution = .fillEqually
        legend.spacing = 8
        legendItems.forEach { legend.addArrangedSubview($0) }

        let stack = UIStackView(arrangedSubviews: [header, bar, legend])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 12),
        ])

        applyLegendAxis()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: WatchSyncStorageMeterView, _) in
            self.applyLegendAxis()
        }
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    /// Three columns normally; one stacked list once text is large enough that
    /// the columns would truncate.
    private func applyLegendAxis() {
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        legend.axis = large ? .vertical : .horizontal
        legend.distribution = large ? .fill : .fillEqually
        legend.spacing = large ? 6 : 8
    }

    func apply(_ breakdown: WatchStorageBreakdown) {
        let animate = self.breakdown != nil && window != nil && !UIAccessibility.isReduceMotionEnabled
        self.breakdown = breakdown
        freeLabel.text = String(localized: "\(SyncFormat.size(breakdown.free)) free")
        bar.setFractions(
            [
                CGFloat(breakdown.flaccy) / CGFloat(breakdown.total),
                CGFloat(breakdown.other) / CGFloat(breakdown.total),
                CGFloat(breakdown.free) / CGFloat(breakdown.total),
            ],
            animated: animate
        )
        legendItems[0].apply(name: String(localized: "Flaccy"), size: SyncFormat.size(breakdown.flaccy), color: .tintColor, outlined: false)
        legendItems[1].apply(name: String(localized: "Other"), size: SyncFormat.size(breakdown.other), color: .systemGray3, outlined: false)
        legendItems[2].apply(name: String(localized: "Free"), size: SyncFormat.size(breakdown.free), color: .tertiarySystemFill, outlined: true)
        accessibilityLabel = String(localized: "Watch Storage")
        accessibilityValue = String(
            localized: "Flaccy \(SyncFormat.size(breakdown.flaccy)), other \(SyncFormat.size(breakdown.other)), \(SyncFormat.size(breakdown.free)) free of \(SyncFormat.size(breakdown.total))"
        )
    }
}

private final class SegmentedBarView: UIView {

    private static let gap: CGFloat = 2
    private let segments: [UIView] = [UIColor.tintColor, .systemGray3, .tertiarySystemFill].map { color in
        let view = UIView()
        view.backgroundColor = color
        return view
    }
    private var fractions: [CGFloat] = [0, 0, 1]

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerCurve = .continuous
        isUserInteractionEnabled = false
        segments.forEach { addSubview($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        applyFrames()
    }

    func setFractions(_ values: [CGFloat], animated: Bool) {
        fractions = values
        guard animated else {
            applyFrames()
            return
        }
        UIView.animate(withDuration: 0.4, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.applyFrames()
        }
    }

    /// Lays the segments edge to edge with a hairline gap between the visible
    /// ones, so a thin Flaccy slice still reads as its own colour.
    private func applyFrames() {
        let visible = fractions.filter { $0 > 0 }.count
        let usable = max(0, bounds.width - Self.gap * CGFloat(max(0, visible - 1)))
        var x: CGFloat = 0
        for (index, segment) in segments.enumerated() {
            let width = usable * fractions[index]
            segment.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            if width > 0 { x += width + Self.gap }
        }
    }
}

private final class LegendItemView: UIView {

    private let dot = UIView()
    private let nameLabel = UILabel()
    private let sizeLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        dot.layer.cornerRadius = 4.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        applyBorderColor()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: LegendItemView, _) in
            self.applyBorderColor()
        }

        nameLabel.font = .preferredFont(forTextStyle: .caption1)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .secondaryLabel
        nameLabel.numberOfLines = 0

        sizeLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        sizeLabel.adjustsFontForContentSizeCategory = true
        sizeLabel.numberOfLines = 0

        let nameRow = UIStackView(arrangedSubviews: [dot, nameLabel])
        nameRow.axis = .horizontal
        nameRow.alignment = .center
        nameRow.spacing = 6

        let stack = UIStackView(arrangedSubviews: [nameRow, sizeLabel])
        stack.axis = .vertical
        stack.spacing = 1
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 9),
            dot.heightAnchor.constraint(equalToConstant: 9),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func applyBorderColor() {
        dot.layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
    }

    func apply(name: String, size: String, color: UIColor, outlined: Bool) {
        nameLabel.text = name
        sizeLabel.text = size
        dot.backgroundColor = color
        dot.layer.borderWidth = outlined ? 1 : 0
    }
}
