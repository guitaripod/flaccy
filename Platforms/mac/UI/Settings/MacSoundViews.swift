import AppKit
import FlaccyCore

/// A Settings-style icon: a white symbol on a rounded tile of one colour, as on the iPhone's rows.
enum MacSettingsIcon {
    static let side: CGFloat = 26

    static func image(symbol: String, tint: NSColor, side: CGFloat = side) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { @Sendable rect in
            tint.setFill()
            NSBezierPath(roundedRect: rect, xRadius: side * 0.24, yRadius: side * 0.24).fill()
            let configuration = NSImage.SymbolConfiguration(pointSize: side * 0.5, weight: .semibold)
                .applying(.init(paletteColors: [.white]))
            guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return true }
            let size = glyph.size
            glyph.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
            return true
        }
    }
}

/// The Sound pane's card: the file, what Flaccy does to it and where it goes, as three stages
/// joined by a line, with the verdict beneath.
final class MacSignalPathView: NSView {

    private let fileStage = Stage()
    private let flaccyStage = Stage()
    private let outputStage = Stage()
    private let verdictDot = FilledView(color: .tertiaryLabelColor, cornerRadius: 4)
    private let verdictLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        setAccessibilityIdentifier("settings.signalPath")

        verdictDot.translatesAutoresizingMaskIntoConstraints = false
        verdictLabel.font = .systemFont(ofSize: 13)
        verdictLabel.textColor = .labelColor
        let verdict = NSStackView(views: [verdictDot, verdictLabel])
        verdict.orientation = .horizontal
        verdict.alignment = .firstBaseline
        verdict.spacing = 8

        let divider = NSBox()
        divider.boxType = .separator

        let stack = NSStackView(views: [fileStage, Self.connector(), flaccyStage, Self.connector(), outputStage, divider, verdict])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.setCustomSpacing(12, after: outputStage)
        stack.setCustomSpacing(10, after: divider)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            verdictDot.widthAnchor.constraint(equalToConstant: 8),
            verdictDot.heightAnchor.constraint(equalToConstant: 8),
            verdictLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    func configure(_ path: SignalPathSummary) {
        fileStage.configure(
            symbol: "waveform", tint: .systemCyan, caption: String(localized: "File"),
            title: path.source, detail: path.sourceDetail
        )
        flaccyStage.configure(
            symbol: path.isUntouched ? "checkmark" : "slider.vertical.3",
            tint: path.isUntouched ? .systemGreen : .systemBlue,
            caption: "Flaccy", title: path.processing, detail: path.processingDetail
        )
        outputStage.configure(
            symbol: SignalPathSummary.symbolName(for: path.outputKind), tint: .systemIndigo,
            caption: String(localized: "Output"), title: path.output, detail: path.outputDetail
        )
        verdictDot.color = Self.color(for: path.verdict)
        verdictLabel.stringValue = SignalPathSummary.sentence(for: path.verdict)
    }

    private static func color(for verdict: SignalPathVerdict) -> NSColor {
        switch verdict {
        case .idle: .tertiaryLabelColor
        case .untouched: .systemGreen
        case .shaped: .systemBlue
        case .reencodedForBluetooth: .systemOrange
        case .lossySource: .systemGray
        }
    }

    /// The short line joining two stages, centred under their icons.
    private static func connector() -> NSView {
        let holder = NSView()
        let line = FilledView(color: .tertiaryLabelColor, cornerRadius: 1)
        line.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(line)
        NSLayoutConstraint.activate([
            holder.heightAnchor.constraint(equalToConstant: 10),
            holder.widthAnchor.constraint(equalToConstant: MacSettingsIcon.side),
            line.widthAnchor.constraint(equalToConstant: 2),
            line.topAnchor.constraint(equalTo: holder.topAnchor),
            line.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            line.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
        ])
        return holder
    }

    /// A rounded patch of one dynamic colour, re-resolved whenever the appearance changes.
    private final class FilledView: NSView {
        var color: NSColor {
            didSet { needsDisplay = true }
        }
        private let cornerRadius: CGFloat

        init(color: NSColor, cornerRadius: CGFloat) {
            self.color = color
            self.cornerRadius = cornerRadius
            super.init(frame: .zero)
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            layer?.cornerRadius = cornerRadius
            layer?.backgroundColor = color.cgColor
        }
    }

    /// One stage of the path: an icon tile, a small caption and what the stage is doing.
    private final class Stage: NSView {
        private let icon = NSImageView()
        private let captionLabel = NSTextField(labelWithString: "")
        private let titleLabel = NSTextField(wrappingLabelWithString: "")
        private let detailLabel = NSTextField(wrappingLabelWithString: "")

        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true)
            setAccessibilityRole(.group)
            captionLabel.font = .systemFont(ofSize: 10, weight: .bold)
            captionLabel.textColor = .secondaryLabelColor
            titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
            detailLabel.font = .systemFont(ofSize: 11)
            detailLabel.textColor = .secondaryLabelColor
            let labels = NSStackView(views: [captionLabel, titleLabel, detailLabel])
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 1
            let row = NSStackView(views: [icon, labels])
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: MacSettingsIcon.side),
                icon.heightAnchor.constraint(equalToConstant: MacSettingsIcon.side),
                row.leadingAnchor.constraint(equalTo: leadingAnchor),
                row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                row.topAnchor.constraint(equalTo: topAnchor),
                row.bottomAnchor.constraint(equalTo: bottomAnchor),
                titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
                detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(symbol: String, tint: NSColor, caption: String, title: String, detail: String?) {
            icon.image = MacSettingsIcon.image(symbol: symbol, tint: tint)
            captionLabel.stringValue = caption.uppercased()
            titleLabel.stringValue = title
            detailLabel.stringValue = detail ?? ""
            detailLabel.isHidden = detail == nil
            setAccessibilityLabel(caption)
            setAccessibilityValue([title, detail].compactMap { $0 }.joined(separator: ", "))
        }
    }
}

/// The top of the Library pane: how much music there is, in which formats, and how much of it is
/// lossless and hi-res.
final class MacLibraryOverviewView: NSView {

    private let numbers = NSStackView()
    private let bar = FormatBar()
    private let legend = NSTextField(wrappingLabelWithString: "")
    private let tags = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("settings.libraryOverview")
        numbers.orientation = .horizontal
        numbers.distribution = .fillEqually
        numbers.spacing = 8
        legend.font = .systemFont(ofSize: 11)
        tags.font = .systemFont(ofSize: 11, weight: .semibold)
        let stack = NSStackView(views: [numbers, bar, legend, tags])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(12, after: numbers)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            numbers.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bar.heightAnchor.constraint(equalToConstant: 8),
            legend.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ overview: LibraryOverviewSummary) {
        numbers.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (value, caption) in [
            (overview.songs, String(localized: "Songs")),
            (overview.albums, String(localized: "Albums")),
            (overview.artists, String(localized: "Artists")),
            (overview.hours, String(localized: "Hours")),
        ] {
            numbers.addArrangedSubview(Self.number(value.formatted(.number), caption: caption))
        }

        let shares = overview.formatShares
        bar.segments = shares.map { (fraction: $0.fraction, color: Self.color(for: $0.codec)) }
        bar.isHidden = shares.isEmpty
        legend.attributedStringValue = Self.legend(for: shares)
        legend.isHidden = shares.isEmpty

        var tagParts: [String] = []
        if overview.songs > 0 {
            tagParts.append(String(localized: "\(overview.losslessPercent)% lossless"))
            if overview.hiRes > 0 { tagParts.append(String(localized: "\(overview.hiRes.formatted()) hi-res")) }
            if overview.serverSongs > 0 { tagParts.append(String(localized: "\(overview.serverSongs) from servers")) }
            if overview.musicBytes > 0 {
                tagParts.append(ByteCountFormatter.string(fromByteCount: overview.musicBytes, countStyle: .file))
            }
        }
        tags.stringValue = tagParts.joined(separator: "  ·  ")
        tags.textColor = .secondaryLabelColor
        tags.isHidden = tagParts.isEmpty
        setAccessibilityLabel(String(localized: "Library overview"))
        setAccessibilityValue(overview.accessibilitySummary)
    }

    private static func number(_ value: String, caption: String) -> NSView {
        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .systemFont(ofSize: 22, weight: .bold)
        valueLabel.alignment = .center
        let captionLabel = NSTextField(labelWithString: caption.uppercased())
        captionLabel.font = .systemFont(ofSize: 10, weight: .medium)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.alignment = .center
        let stack = NSStackView(views: [valueLabel, captionLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 1
        return stack
    }

    private static func legend(for shares: [(codec: String, fraction: Double)]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 11)
        for (index, share) in shares.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "   ", attributes: [.font: font])) }
            text.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: color(for: share.codec), .font: font]))
            let percent = share.fraction.formatted(.percent.precision(.fractionLength(0)))
            text.append(NSAttributedString(
                string: "\(share.codec) \(percent)",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: font]
            ))
        }
        return text
    }

    private static func color(for codec: String) -> NSColor {
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

    /// A rounded bar split into coloured segments by fraction.
    private final class FormatBar: NSView {
        var segments: [(fraction: Double, color: NSColor)] = [] {
            didSet { needsDisplay = true }
        }

        override func draw(_ dirtyRect: NSRect) {
            let clip = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
            clip.addClip()
            NSColor.quaternaryLabelColor.setFill()
            bounds.fill()
            var x: CGFloat = 0
            for segment in segments {
                let width = bounds.width * segment.fraction
                segment.color.setFill()
                NSRect(x: x, y: 0, width: width, height: bounds.height).fill()
                x += width
            }
        }
    }
}
