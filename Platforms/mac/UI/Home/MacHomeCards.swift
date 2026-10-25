import AppKit
import FlaccyCore

/// A square cover with a title and a line under it, as Made for You and
/// Recently Added show them. Pointing at one lifts it, deepens its shadow and
/// reveals a play button at the bottom right and, when there is a menu, a
/// menu button at the bottom left.
final class MacHomeCard: MacHomeInteractiveView {

    static let lift: CGFloat = 3

    var onPlay: (() -> Void)?

    let side: CGFloat
    private let lifted = NSView()
    private let cover: MacHomeCoverView
    private let play: MacHomeCircleButton
    private let more: MacHomeCircleButton
    private let badge: MacHomeBadge?

    init(
        side: CGFloat,
        cornerRadius: CGFloat,
        subject: MacHomeCoverView.Subject,
        title: String,
        subtitle: String,
        badge: String? = nil,
        hasMenu: Bool,
        glyph: String? = nil
    ) {
        self.side = side
        cover = MacHomeCoverView(cornerRadius: cornerRadius, shadow: true)
        play = MacHomeCircleButton(symbol: "play.fill", label: HomeCopy.play, style: .solid, diameter: side > 150 ? 32 : 28, pointSize: 12)
        more = MacHomeCircleButton(symbol: "ellipsis", label: HomeCopy.more, style: .scrim, diameter: side > 150 ? 32 : 28, pointSize: 13)
        self.badge = badge.map { MacHomeBadge(text: $0) }
        super.init(frame: .zero)
        wantsLayer = true

        lifted.wantsLayer = true
        lifted.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lifted)

        cover.translatesAutoresizingMaskIntoConstraints = false
        cover.show(subject)
        lifted.addSubview(cover)
        cover.layer?.shadowOpacity = 0.2
        cover.layer?.shadowRadius = 6
        cover.layer?.shadowOffset = CGSize(width: 0, height: -3)

        if let glyph { addGlyph(glyph) }

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.isHidden = subtitle.isEmpty
        let text = NSStackView(views: [titleLabel, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false
        lifted.addSubview(text)

        for button in [play, more] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.alphaValue = 0
            lifted.addSubview(button)
        }
        more.isHidden = !hasMenu
        if let badge = self.badge {
            badge.translatesAutoresizingMaskIntoConstraints = false
            lifted.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.leadingAnchor.constraint(equalTo: cover.leadingAnchor, constant: 8),
                badge.bottomAnchor.constraint(equalTo: cover.bottomAnchor, constant: -8),
            ])
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            lifted.topAnchor.constraint(equalTo: topAnchor),
            lifted.leadingAnchor.constraint(equalTo: leadingAnchor),
            lifted.trailingAnchor.constraint(equalTo: trailingAnchor),
            lifted.bottomAnchor.constraint(equalTo: bottomAnchor),
            cover.topAnchor.constraint(equalTo: lifted.topAnchor),
            cover.leadingAnchor.constraint(equalTo: lifted.leadingAnchor),
            cover.widthAnchor.constraint(equalToConstant: side),
            cover.heightAnchor.constraint(equalToConstant: side),
            text.topAnchor.constraint(equalTo: cover.bottomAnchor, constant: 9),
            text.leadingAnchor.constraint(equalTo: lifted.leadingAnchor, constant: 1),
            text.trailingAnchor.constraint(equalTo: lifted.trailingAnchor, constant: -1),
            text.bottomAnchor.constraint(equalTo: lifted.bottomAnchor),
            play.trailingAnchor.constraint(equalTo: cover.trailingAnchor, constant: -10),
            play.bottomAnchor.constraint(equalTo: cover.bottomAnchor, constant: -10),
            more.leadingAnchor.constraint(equalTo: cover.leadingAnchor, constant: 10),
            more.bottomAnchor.constraint(equalTo: cover.bottomAnchor, constant: -10),
        ])
        play.onClick = { [weak self] in
            guard let self else { return }
            (self.onPlay ?? self.onClick)?()
        }
        more.menuOnClick = { [weak self] in self?.menuProvider?() }
        setAccessibilityRole(.button)
        setAccessibilityLabel(subtitle.isEmpty ? title : "\(title), \(subtitle)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func addGlyph(_ symbol: String) {
        let scrim = NSView()
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        scrim.layer?.cornerRadius = cover.cornerRadius
        scrim.layer?.cornerCurve = .continuous
        scrim.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: MacSymbolImage.configured(symbol, pointSize: 38, weight: .light) ?? NSImage())
        icon.contentTintColor = .white
        icon.translatesAutoresizingMaskIntoConstraints = false
        scrim.addSubview(icon)
        lifted.addSubview(scrim)
        NSLayoutConstraint.activate([
            scrim.topAnchor.constraint(equalTo: cover.topAnchor),
            scrim.leadingAnchor.constraint(equalTo: cover.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: cover.trailingAnchor),
            scrim.bottomAnchor.constraint(equalTo: cover.bottomAnchor),
            icon.centerXAnchor.constraint(equalTo: scrim.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: scrim.centerYAnchor),
        ])
    }

    override func stateDidChange() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let raised = isHovered && !reduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            play.animator().alphaValue = isHovered ? 1 : 0
            more.animator().alphaValue = isHovered ? 1 : 0
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        lifted.layer?.transform = CATransform3DMakeTranslation(0, raised ? Self.lift : 0, 0)
        cover.layer?.shadowOpacity = isHovered ? 0.42 : 0.2
        cover.layer?.shadowRadius = isHovered ? 14 : 6
        cover.layer?.shadowOffset = CGSize(width: 0, height: isHovered ? -8 : -3)
        CATransaction.commit()
    }
}

/// The empty slot at the end of Made for You while there are fewer than two
/// mixes: a dashed outline and a promise.
final class MacHomePlaceholderCard: NSView {

    private let outline = CAShapeLayer()

    init(side: CGFloat, text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        outline.fillColor = nil
        outline.lineWidth = 1.5
        outline.lineDashPattern = [6, 5]
        layer?.addSublayer(outline)

        let icon = NSImageView(image: MacSymbolImage.configured("sparkles", pointSize: 24, weight: .light) ?? NSImage())
        icon.contentTintColor = .tertiaryLabelColor
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.maximumNumberOfLines = 3
        label.isSelectable = false
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
        setAccessibilityLabel(text)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.frame = bounds
        outline.path = CGPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 10, cornerHeight: 10, transform: nil
        )
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            outline.strokeColor = MacColors.fill(0.22, light: 0.2).cgColor
        }
    }
}

/// A row of cards that scrolls sideways when it overflows, with room above
/// and below for the lift and the shadow.
final class MacHomeShelf: NSView {

    private let scroll = MacHomeShelfScrollView()
    private let stack = NSStackView()

    static let verticalPadding: (top: CGFloat, bottom: CGFloat) = (6, 16)

    init(cards: [NSView], spacing: CGFloat) {
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: Self.verticalPadding.top, left: 0, bottom: Self.verticalPadding.bottom, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        cards.forEach(stack.addArrangedSubview)

        scroll.documentView = stack
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            heightAnchor.constraint(equalTo: stack.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
