import FlaccyCore
import UIKit

/// The Sound page's card: the file, what Flaccy does to it and where it goes, as three stages
/// joined by a line, with the verdict in a coloured line beneath.
final class SignalPathCell: UITableViewCell {

    static let reuseID = "SignalPathCell"

    private let fileStage = Stage()
    private let flaccyStage = Stage()
    private let outputStage = Stage()
    private let verdictDot = UIView()
    private let verdictLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        accessibilityIdentifier = "settings.signalPath"

        verdictDot.layer.cornerRadius = 5
        verdictDot.translatesAutoresizingMaskIntoConstraints = false
        verdictLabel.font = .preferredFont(forTextStyle: .subheadline)
        verdictLabel.adjustsFontForContentSizeCategory = true
        verdictLabel.numberOfLines = 0
        let verdict = UIStackView(arrangedSubviews: [verdictDot, verdictLabel])
        verdict.spacing = 10
        verdict.alignment = .firstBaseline

        let divider = UIView()
        divider.backgroundColor = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [
            fileStage, Self.connector(), flaccyStage, Self.connector(), outputStage, divider, verdict,
        ])
        stack.axis = .vertical
        stack.spacing = 4
        stack.setCustomSpacing(14, after: outputStage)
        stack.setCustomSpacing(12, after: divider)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            divider.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            verdictDot.widthAnchor.constraint(equalToConstant: 10),
            verdictDot.heightAnchor.constraint(equalToConstant: 10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ path: SignalPathSummary) {
        fileStage.configure(
            symbol: "waveform", tint: .systemCyan, caption: String(localized: "File"),
            title: path.source, detail: path.sourceDetail
        )
        let untouched = path.isUntouched
        flaccyStage.configure(
            symbol: untouched ? "checkmark" : "slider.vertical.3", tint: untouched ? .systemGreen : .systemBlue,
            caption: "Flaccy", title: path.processing, detail: path.processingDetail
        )
        outputStage.configure(
            symbol: SignalPathSummary.symbolName(for: path.outputKind), tint: .systemIndigo, caption: String(localized: "Output"),
            title: path.output, detail: path.outputDetail
        )
        verdictDot.backgroundColor = Self.color(for: path.verdict)
        verdictLabel.text = SignalPathSummary.sentence(for: path.verdict)
        accessibilityElements = [fileStage, flaccyStage, outputStage, verdictLabel]
    }

    private static func color(for verdict: SignalPathVerdict) -> UIColor {
        switch verdict {
        case .idle: .tertiaryLabel
        case .untouched: .systemGreen
        case .shaped: .systemBlue
        case .reencodedForBluetooth: .systemOrange
        case .lossySource: .systemGray
        }
    }

    /// The short line joining two stages, centred under their icons.
    private static func connector() -> UIView {
        let holder = UIView()
        let line = UIView()
        line.backgroundColor = .tertiaryLabel
        line.layer.cornerRadius = 1
        line.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(line)
        NSLayoutConstraint.activate([
            holder.heightAnchor.constraint(equalToConstant: 12),
            line.widthAnchor.constraint(equalToConstant: 2),
            line.topAnchor.constraint(equalTo: holder.topAnchor),
            line.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            line.centerXAnchor.constraint(equalTo: holder.leadingAnchor, constant: SettingsViewController.RowIcon.side / 2),
        ])
        return holder
    }

    /// One stage of the path: an icon tile, a small caption and what the stage is doing.
    private final class Stage: UIView {
        private let icon = UIImageView()
        private let captionLabel = UILabel()
        private let titleLabel = UILabel()
        private let detailLabel = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isAccessibilityElement = true
            captionLabel.font = .preferredFont(forTextStyle: .caption2).withSymbolicTraits(.traitBold)
            captionLabel.textColor = .secondaryLabel
            titleLabel.font = .preferredFont(forTextStyle: .headline)
            titleLabel.numberOfLines = 0
            detailLabel.font = .preferredFont(forTextStyle: .footnote)
            detailLabel.textColor = .secondaryLabel
            detailLabel.numberOfLines = 0
            for label in [captionLabel, titleLabel, detailLabel] { label.adjustsFontForContentSizeCategory = true }
            let labels = UIStackView(arrangedSubviews: [captionLabel, titleLabel, detailLabel])
            labels.axis = .vertical
            labels.spacing = 1
            let row = UIStackView(arrangedSubviews: [icon, labels])
            row.spacing = 12
            row.alignment = .top
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: SettingsViewController.RowIcon.side),
                icon.heightAnchor.constraint(equalToConstant: SettingsViewController.RowIcon.side),
                row.leadingAnchor.constraint(equalTo: leadingAnchor),
                row.trailingAnchor.constraint(equalTo: trailingAnchor),
                row.topAnchor.constraint(equalTo: topAnchor),
                row.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(symbol: String, tint: UIColor, caption: String, title: String, detail: String?) {
            icon.image = SettingsViewController.RowIcon.image(systemName: symbol, tint: tint)
            captionLabel.text = caption.uppercased()
            titleLabel.text = title
            detailLabel.text = detail
            detailLabel.isHidden = detail == nil
            accessibilityLabel = caption
            accessibilityValue = [title, detail].compactMap { $0 }.joined(separator: ", ")
        }
    }
}

/// The top of the Library page: how much music there is, in which formats, and how much of it
/// is lossless and hi-res, drawn as numbers, a bar of formats and three tags.
final class LibraryOverviewCell: UITableViewCell {

    static let reuseID = "LibraryOverviewCell"

    private let numbers = UIStackView()
    private let bar = FormatBar()
    private let legend = UILabel()
    private let tags = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        accessibilityIdentifier = "settings.libraryOverview"
        numbers.distribution = .fillEqually
        legend.font = .preferredFont(forTextStyle: .footnote)
        legend.adjustsFontForContentSizeCategory = true
        legend.numberOfLines = 0
        tags.spacing = 8
        let stack = UIStackView(arrangedSubviews: [numbers, bar, legend, tags])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(16, after: numbers)
        stack.setCustomSpacing(6, after: bar)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            bar.heightAnchor.constraint(equalToConstant: 10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ overview: LibraryOverviewSummary) {
        numbers.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let grouped = { (value: Int) in value.formatted(.number) }
        for (value, caption) in [
            (grouped(overview.songs), String(localized: "Songs")),
            (grouped(overview.albums), String(localized: "Albums")),
            (grouped(overview.artists), String(localized: "Artists")),
            (grouped(overview.hours), String(localized: "Hours")),
        ] {
            numbers.addArrangedSubview(Self.number(value, caption: caption))
        }

        let shares = overview.formatShares
        bar.segments = shares.map { (fraction: $0.fraction, color: Self.color(for: $0.codec)) }
        bar.isHidden = shares.isEmpty
        legend.attributedText = Self.legend(for: shares)
        legend.isHidden = shares.isEmpty

        tags.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if overview.songs > 0 {
            tags.addArrangedSubview(Self.tag(String(localized: "\(overview.losslessPercent)% lossless"), color: QualityBadgeView.losslessTint))
            if overview.hiRes > 0 {
                tags.addArrangedSubview(Self.tag(String(localized: "\(overview.hiRes.formatted()) hi-res"), color: .systemPurple))
            }
            if overview.serverSongs > 0 {
                tags.addArrangedSubview(Self.tag(String(localized: "\(overview.serverSongs) from servers"), color: .systemTeal))
            }
            if overview.musicBytes > 0 {
                tags.addArrangedSubview(Self.tag(ByteCountFormatter.string(fromByteCount: overview.musicBytes, countStyle: .file), color: .systemGray))
            }
            tags.addArrangedSubview(UIView())
        }
        tags.isHidden = overview.songs == 0

        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Library overview")
        accessibilityValue = overview.accessibilitySummary
    }

    private static func number(_ value: String, caption: String) -> UIView {
        let valueLabel = UILabel()
        valueLabel.text = value
        valueLabel.font = UIFont.preferredFont(forTextStyle: .title2).withSymbolicTraits(.traitBold)
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.6
        valueLabel.textAlignment = .center
        let captionLabel = UILabel()
        captionLabel.text = caption.uppercased()
        captionLabel.font = .preferredFont(forTextStyle: .caption2)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.textColor = .secondaryLabel
        captionLabel.textAlignment = .center
        captionLabel.adjustsFontSizeToFitWidth = true
        captionLabel.minimumScaleFactor = 0.7
        let stack = UIStackView(arrangedSubviews: [valueLabel, captionLabel])
        stack.axis = .vertical
        stack.spacing = 2
        return stack
    }

    private static func legend(for shares: [(codec: String, fraction: Double)]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for (index, share) in shares.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "   ")) }
            text.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: color(for: share.codec)]))
            let percent = share.fraction.formatted(.percent.precision(.fractionLength(0)))
            text.append(NSAttributedString(string: "\(share.codec) \(percent)", attributes: [.foregroundColor: UIColor.secondaryLabel]))
        }
        return text
    }

    private static func color(for codec: String) -> UIColor {
        switch codec {
        case "FLAC": .systemCyan
        case "ALAC": .systemTeal
        case "WAV": .systemIndigo
        case "AIFF": .systemPurple
        case "MP3": .systemOrange
        case "AAC": .systemPink
        default: .systemGray
        }
    }

    private static func tag(_ text: String, color: UIColor) -> UIView {
        var configuration = UIButton.Configuration.filled()
        configuration.title = text
        configuration.baseBackgroundColor = color.withAlphaComponent(0.16)
        configuration.baseForegroundColor = color
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .caption1).withSymbolicTraits(.traitBold)
            return attributes
        }
        let button = UIButton(configuration: configuration)
        button.isUserInteractionEnabled = false
        return button
    }

    /// A rounded bar split into coloured segments by fraction.
    private final class FormatBar: UIView {
        var segments: [(fraction: Double, color: UIColor)] = [] {
            didSet { setNeedsLayout() }
        }
        private var segmentViews: [UIView] = []

        override init(frame: CGRect) {
            super.init(frame: frame)
            layer.cornerRadius = 5
            clipsToBounds = true
            backgroundColor = .tertiarySystemFill
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            segmentViews.forEach { $0.removeFromSuperview() }
            segmentViews = []
            var x: CGFloat = 0
            for segment in segments {
                let width = bounds.width * segment.fraction
                let view = UIView(frame: CGRect(x: x, y: 0, width: width, height: bounds.height))
                view.backgroundColor = segment.color
                addSubview(view)
                segmentViews.append(view)
                x += width
            }
        }
    }
}

private extension UIFont {
    func withSymbolicTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
