import AppKit

/// Everything the hero shows for one of its three faces, prepared by the page
/// so the view only lays it out.
struct MacHomeHeroModel {

    struct Action {
        enum Kind {
            case primary(title: String, symbol: String)
            case secondary(title: String, symbol: String)
            case circle(symbol: String, label: String)
            case menu(symbol: String, label: String)
        }

        var kind: Kind
        var run: (() -> Void)?
        var menu: (() -> NSMenu?)?
    }

    var cover: MacHomeCoverView.Subject
    var onCoverClick: (() -> Void)?
    var kicker: String
    var title: String
    var subtitle: String?
    var onSubtitleClick: (() -> Void)?
    var badge: String?
    var metaText: String?
    var lines: [String] = []
    var segments: [Double]?
    var trackLine: String?
    var remaining: String?
    var actions: [Action] = []
}

/// The top-left of Home: a cover with a column of words and buttons beside it.
final class MacHomeHeroView: NSView {

    static let coverSide: CGFloat = 260
    static let textWidth: CGFloat = 360
    static let spacing: CGFloat = 28

    private let cover = MacHomeCoverView(cornerRadius: 12, tier: .large, shadow: true)
    private let coverButton = MacHomeInteractiveView()
    private let column = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cover.translatesAutoresizingMaskIntoConstraints = false
        coverButton.translatesAutoresizingMaskIntoConstraints = false
        coverButton.addSubview(cover)
        addSubview(coverButton)

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        let preferredWidth = column.widthAnchor.constraint(equalToConstant: Self.textWidth)
        preferredWidth.priority = NSLayoutConstraint.Priority(749)
        NSLayoutConstraint.activate([
            cover.topAnchor.constraint(equalTo: coverButton.topAnchor),
            cover.leadingAnchor.constraint(equalTo: coverButton.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: coverButton.trailingAnchor),
            cover.bottomAnchor.constraint(equalTo: coverButton.bottomAnchor),
            coverButton.topAnchor.constraint(equalTo: topAnchor),
            coverButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            coverButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            coverButton.widthAnchor.constraint(equalToConstant: Self.coverSide),
            coverButton.heightAnchor.constraint(equalToConstant: Self.coverSide),
            column.leadingAnchor.constraint(equalTo: coverButton.trailingAnchor, constant: Self.spacing),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            column.centerYAnchor.constraint(equalTo: coverButton.centerYAnchor),
            column.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            column.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            preferredWidth,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    func configure(_ model: MacHomeHeroModel) {
        cover.show(model.cover)
        coverButton.onClick = model.onCoverClick
        coverButton.setAccessibilityElement(model.onCoverClick != nil)
        coverButton.setAccessibilityLabel(model.title)
        column.arrangedSubviews.forEach {
            column.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let kicker = label(model.kicker, size: 13, weight: .semibold, color: .secondaryLabelColor)
        addFull(kicker)
        column.setCustomSpacing(6, after: kicker)
        addFull(titleLabel(model.title))
        if let subtitle = model.subtitle, !subtitle.isEmpty {
            addSubtitle(subtitle, onClick: model.onSubtitleClick)
        }
        if model.badge != nil || model.metaText != nil {
            column.addArrangedSubview(metaRow(badge: model.badge, text: model.metaText))
        }
        for line in model.lines {
            addFull(label(line, size: 13, weight: .regular, color: .secondaryLabelColor))
        }
        if let segments = model.segments {
            addProgress(segments, trackLine: model.trackLine, remaining: model.remaining)
        }
        if !model.actions.isEmpty {
            let row = buttonRow(model.actions)
            column.addArrangedSubview(row)
            if let previous = column.arrangedSubviews.dropLast().last {
                column.setCustomSpacing(18, after: previous)
            }
        }
    }

    private func addFull(_ view: NSView) {
        column.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.maximumNumberOfLines = 2
        field.lineBreakMode = .byTruncatingTail
        field.isSelectable = false
        return field
    }

    private func titleLabel(_ text: String) -> NSTextField {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 42
        style.maximumLineHeight = 42
        style.lineBreakMode = .byTruncatingTail
        let field = NSTextField(wrappingLabelWithString: "")
        field.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 36, weight: .heavy),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
            .baselineOffset: 0,
        ])
        field.maximumNumberOfLines = 2
        field.isSelectable = false
        field.setAccessibilityRole(.staticText)
        return field
    }

    private func addSubtitle(_ text: String, onClick: (() -> Void)?) {
        if let onClick {
            let link = MacHomeLinkButton(title: text, size: 17, weight: .medium, color: .secondaryLabelColor)
            link.onClick = onClick
            column.addArrangedSubview(link)
            link.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor).isActive = true
        } else {
            addFull(label(text, size: 17, weight: .medium, color: .secondaryLabelColor))
        }
    }

    private func metaRow(badge: String?, text: String?) -> NSView {
        var views: [NSView] = []
        if let badge { views.append(MacHomeBadge(text: badge)) }
        if let text {
            views.append(label(text, size: 13, weight: .regular, color: .secondaryLabelColor))
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func addProgress(_ segments: [Double], trackLine: String?, remaining: String?) {
        let bar = MacHomeSegmentedBar()
        bar.segments = segments
        bar.translatesAutoresizingMaskIntoConstraints = false
        addFull(bar)
        if let previous = column.arrangedSubviews.dropLast().last {
            column.setCustomSpacing(16, after: previous)
        }
        guard trackLine != nil || remaining != nil else { return }
        let left = label(trackLine ?? "", size: 13, weight: .semibold, color: .labelColor)
        left.maximumNumberOfLines = 1
        left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let right = label(remaining ?? "", size: 13, weight: .regular, color: .secondaryLabelColor)
        right.maximumNumberOfLines = 1
        right.setContentCompressionResistancePriority(.required, for: .horizontal)
        right.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [left, right])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 12
        addFull(row)
    }

    private func buttonRow(_ actions: [MacHomeHeroModel.Action]) -> NSView {
        var views: [NSView] = []
        for action in actions {
            switch action.kind {
            case .primary(let title, let symbol):
                let button = MacHomeFilledButton(title: title, symbol: symbol)
                button.onClick = action.run
                views.append(button)
            case .secondary(let title, let symbol):
                let button = GlassCapsuleButton(title: title, symbolName: symbol)
                button.onClick = { action.run?() }
                views.append(button)
            case .circle(let symbol, let label):
                let button = MacHomeCircleButton(symbol: symbol, label: label, style: .glass)
                button.onClick = action.run
                views.append(button)
            case .menu(let symbol, let label):
                let button = MacHomeCircleButton(symbol: symbol, label: label, style: .glass)
                button.menuOnClick = action.menu
                views.append(button)
            }
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return MacLiquidGlass.grouping(row, spacing: 10)
    }
}

/// A small solid capsule carrying the quality of a hi-res album.
final class MacHomeBadge: NSView {

    private let label: NSTextField

    init(text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        restyle()
        setAccessibilityLabel(text)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = MacColors.fill(0.16, light: 0.1).cgColor
            label.textColor = .labelColor
        }
    }
}
