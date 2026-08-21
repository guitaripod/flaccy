import FlaccyCore
import UIKit

/// Act III's curtain: what the scan actually built, on one glass card over the
/// still-live mosaic. Every number is read from the database rather than counted
/// in the view, so the card cannot disagree with the library behind it.
final class LibraryDebutSummaryCard: UIView {

    var onPrimaryAction: (() -> Void)?
    var onSecondaryAction: (() -> Void)?

    private enum Metrics {
        static let cornerRadius: CGFloat = 28
        static let contentInset: CGFloat = 22
        static let statSpacing: CGFloat = 14
    }

    private let glass = LiquidGlass.view(cornerRadius: Metrics.cornerRadius)
    private let aiSkippedForEntitlement: Bool

    /// `aiSkippedForEntitlement` turns the card's grey paywall footnote into the
    /// one line an expired trial has earned the right to read: the tag cleanup
    /// did not run, and here is the button that runs it.
    init(summary: LibraryDebutSummary, aiSkippedForEntitlement: Bool) {
        self.aiSkippedForEntitlement = aiSkippedForEntitlement
        super.init(frame: .zero)
        layer.cornerRadius = Metrics.cornerRadius
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.45
        layer.shadowOffset = CGSize(width: 0, height: 18)
        layer.shadowRadius = 34

        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        let content = makeContent(for: summary)
        content.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(content)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: Metrics.contentInset),
            content.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: Metrics.contentInset),
            content.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -Metrics.contentInset),
            content.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -Metrics.contentInset),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeContent(for summary: LibraryDebutSummary) -> UIView {
        let stack = UIStackView(arrangedSubviews: [
            makeTitle(),
            makeStatGrid(for: summary),
            makeDivider(),
            makeFactLines(for: summary),
            makePaywallLine(),
            makeActions(),
        ])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 18
        stack.setCustomSpacing(20, after: stack.arrangedSubviews[1])
        stack.setCustomSpacing(14, after: stack.arrangedSubviews[2])
        stack.setCustomSpacing(12, after: stack.arrangedSubviews[3])
        stack.setCustomSpacing(20, after: stack.arrangedSubviews[4])
        return stack
    }

    private func makeTitle() -> UILabel {
        let title = UILabel()
        title.text = LibraryDebutCopy.cardTitle
        title.font = .scaled(.title2, size: 24, weight: .bold)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 2
        title.accessibilityTraits = .header
        return title
    }

    /// The four figures a person actually repeats to someone else, two by two so
    /// the eye pairs them: how much music, and how many people made it.
    private func makeStatGrid(for summary: LibraryDebutSummary) -> UIView {
        let cells = [
            SummaryStatCell(value: LibraryLoadPhaseCopy.number(summary.trackCount), label: LibraryDebutCopy.statLabel(.tracks)),
            SummaryStatCell(value: LibraryLoadPhaseCopy.number(summary.albumCount), label: LibraryDebutCopy.statLabel(.albums)),
            SummaryStatCell(value: LibraryLoadPhaseCopy.number(summary.artistCount), label: LibraryDebutCopy.statLabel(.artists)),
            SummaryStatCell(value: Self.duration(summary.totalDurationSeconds), label: LibraryDebutCopy.statLabel(.duration)),
        ]
        let top = UIStackView(arrangedSubviews: [cells[0], cells[1]])
        let bottom = UIStackView(arrangedSubviews: [cells[2], cells[3]])
        for row in [top, bottom] {
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.alignment = .top
            row.spacing = Metrics.statSpacing
        }
        let grid = UIStackView(arrangedSubviews: [top, bottom])
        grid.axis = .vertical
        grid.spacing = Metrics.statSpacing
        return grid
    }

    private func makeFactLines(for summary: LibraryDebutSummary) -> UIView {
        let lines = UIStackView()
        lines.axis = .vertical
        lines.spacing = 5
        lines.addArrangedSubview(makeFactLine(
            LibraryDebutCopy.coversLine(coversResolved: summary.coversResolved, albumsDated: summary.albumsDated)
        ))
        if summary.aiCleanedTracks > 0 {
            lines.addArrangedSubview(makeFactLine(LibraryDebutCopy.aiLine(cleanedTracks: summary.aiCleanedTracks)))
        }
        lines.addArrangedSubview(makeFactLine(LibraryDebutCopy.qualityLine(
            losslessPercent: Self.losslessPercent(of: summary),
            averageBitrate: summary.averageBitrate
        )))
        return lines
    }

    private func makeFactLine(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .scaled(.subheadline, size: 15, weight: .regular).monospacedDigits
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 2
        return label
    }

    /// The paywall footnote, or — when the trial ran out before the AI pass could
    /// run — a readable line saying so, because that is the only thing on this
    /// card the reader can act on.
    private func makePaywallLine() -> UILabel {
        let label = UILabel()
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 3
        guard aiSkippedForEntitlement else {
            label.text = LibraryDebutCopy.paywallLine
            label.font = .preferredFont(forTextStyle: .footnote)
            label.textColor = .tertiaryLabel
            return label
        }
        label.text = LibraryDebutCopy.aiSkippedHeadline
        label.font = .scaled(.subheadline, size: 15, weight: .medium)
        label.textColor = .label
        return label
    }

    private func makeDivider() -> UIView {
        let container = UIView()
        let line = UIView()
        line.backgroundColor = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 1),
            line.topAnchor.constraint(equalTo: container.topAnchor),
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    /// The primary action is the only prominent thing on the card; the paywall
    /// sits beside it in plain grey, because a first launch that gates the
    /// library behind an offer is a first launch that gets deleted.
    private func makeActions() -> UIView {
        var primary = UIButton.Configuration.filled()
        primary.title = LibraryDebutCopy.primaryAction
        primary.cornerStyle = .capsule
        primary.baseBackgroundColor = .tintColor
        primary.baseForegroundColor = .white
        primary.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)
        primary.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .scaled(.headline, size: 17, weight: .semibold)
            return outgoing
        }
        let primaryButton = UIButton(configuration: primary)
        primaryButton.addAction(UIAction { [weak self] _ in
            self?.onPrimaryAction?()
        }, for: .touchUpInside)

        var secondary = UIButton.Configuration.plain()
        secondary.title = aiSkippedForEntitlement
            ? LibraryDebutCopy.aiSkippedAction
            : LibraryDebutCopy.secondaryAction
        secondary.baseForegroundColor = .secondaryLabel
        secondary.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8)
        secondary.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .scaled(.subheadline, size: 15, weight: .regular)
            return outgoing
        }
        let secondaryButton = UIButton(configuration: secondary)
        secondaryButton.addAction(UIAction { [weak self] _ in
            self?.onSecondaryAction?()
        }, for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [primaryButton, secondaryButton])
        row.axis = .vertical
        row.alignment = .fill
        row.spacing = 4
        return row
    }

    private static func losslessPercent(of summary: LibraryDebutSummary) -> Int {
        guard summary.trackCount > 0 else { return 0 }
        return Int((Double(summary.losslessTrackCount) / Double(summary.trackCount) * 100).rounded())
    }

    /// Days and hours for a real library, hours and minutes for a small one, so
    /// a first launch with one album never reports an empty string where a
    /// headline figure belongs.
    private static func duration(_ seconds: Double) -> String {
        let interval = max(0, seconds)
        if let long = formatter(units: [.day, .hour]).string(from: interval), !long.isEmpty {
            return long
        }
        return formatter(units: [.hour, .minute]).string(from: interval) ?? ""
    }

    private static func formatter(units: NSCalendar.Unit) -> DateComponentsFormatter {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = units
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }
}

/// One figure of the summary grid: the number in a large monospaced face so the
/// four cells line up, and the word under it in the same voice every client uses.
private final class SummaryStatCell: UIView {

    init(value: String, label: String) {
        super.init(frame: .zero)

        let valueLabel = UILabel()
        valueLabel.text = value
        valueLabel.font = .scaled(.title2, size: 22, weight: .semibold).monospacedDigits
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.numberOfLines = 2
        valueLabel.minimumScaleFactor = 0.7
        valueLabel.adjustsFontSizeToFitWidth = true

        let titleLabel = UILabel()
        titleLabel.text = label
        titleLabel.font = .scaled(.caption2, size: 11, weight: .medium)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .secondaryLabel
        titleLabel.numberOfLines = 1

        let stack = UIStackView(arrangedSubviews: [valueLabel, titleLabel])
        stack.axis = .vertical
        stack.spacing = 1
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        isAccessibilityElement = true
        accessibilityLabel = "\(value) \(label)"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
