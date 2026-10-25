import AppKit
import FlaccyCore

/// What Jump Back In needs from the page when a row is used.
struct MacHomeJumpActions {
    var open: (HomeFeed.Item) -> Void
    var play: (HomeFeed.Item, Bool) -> Void
    var remove: (HomeFeed.Item) -> Void
}

/// The panel of the six things most worth going back to.
final class MacHomeJumpBackInPanel: MacHomeSurfaceView {

    static let width: CGFloat = 380

    private let rows = NSStackView()

    init() {
        super.init(cornerRadius: 14)
        let header = NSTextField(labelWithString: HomeCopy.title(for: .jumpBackIn))
        header.font = .systemFont(ofSize: 15, weight: .bold)
        header.textColor = .labelColor
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            rows.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel(HomeCopy.title(for: .jumpBackIn))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(items: [HomeFeed.Item], actions: MacHomeJumpActions) {
        rows.arrangedSubviews.forEach {
            rows.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for item in items.prefix(HomeComposer.jumpBackInLimit) {
            let row = MacHomeJumpRow(item: item, actions: actions)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }
}

/// One 46 pt row: a small cover, two lines, and on hover a play glyph over the
/// cover and a menu button at the end.
final class MacHomeJumpRow: MacHomeInteractiveView {

    static let height: CGFloat = 46

    private let item: HomeFeed.Item
    private let actions: MacHomeJumpActions
    private let cover = MacHomeCoverView(cornerRadius: 6)
    private let playOverlay = NSView()
    private let more: MacHomeCircleButton

    init(item: HomeFeed.Item, actions: MacHomeJumpActions) {
        self.item = item
        self.actions = actions
        more = MacHomeCircleButton(symbol: "ellipsis", label: HomeCopy.more, style: .plain, diameter: 26, pointSize: 13)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous

        cover.translatesAutoresizingMaskIntoConstraints = false
        cover.show(MacHomeCoverView.Subject(
            albums: item.coverAlbums,
            seed: item.context.key,
            playlistID: item.context.kind == .playlist ? Int64(item.context.id) : nil
        ))
        addSubview(cover)

        playOverlay.wantsLayer = true
        playOverlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        playOverlay.layer?.cornerRadius = 6
        playOverlay.layer?.cornerCurve = .continuous
        playOverlay.alphaValue = 0
        playOverlay.translatesAutoresizingMaskIntoConstraints = false
        let play = NSImageView(image: MacSymbolImage.configured("play.fill", pointSize: 13, weight: .bold) ?? NSImage())
        play.contentTintColor = .white
        play.translatesAutoresizingMaskIntoConstraints = false
        playOverlay.addSubview(play)
        addSubview(playOverlay)

        let title = NSTextField(labelWithString: item.context.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        let subtitle = NSTextField(labelWithString: MacHomeCopy.subtitle(for: item))
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(text)

        more.alphaValue = 0
        more.translatesAutoresizingMaskIntoConstraints = false
        more.menuOnClick = { [weak self] in self?.buildMenu() }
        addSubview(more)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            cover.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            cover.centerYAnchor.constraint(equalTo: centerYAnchor),
            cover.widthAnchor.constraint(equalToConstant: 36),
            cover.heightAnchor.constraint(equalToConstant: 36),
            playOverlay.topAnchor.constraint(equalTo: cover.topAnchor),
            playOverlay.leadingAnchor.constraint(equalTo: cover.leadingAnchor),
            playOverlay.trailingAnchor.constraint(equalTo: cover.trailingAnchor),
            playOverlay.bottomAnchor.constraint(equalTo: cover.bottomAnchor),
            play.centerXAnchor.constraint(equalTo: playOverlay.centerXAnchor),
            play.centerYAnchor.constraint(equalTo: playOverlay.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: cover.trailingAnchor, constant: 12),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: more.leadingAnchor, constant: -8),
            more.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            more.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        onClick = { [weak self] in
            guard let self else { return }
            self.actions.open(self.item)
        }
        menuProvider = { [weak self] in self?.buildMenu() }
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(item.context.title), \(MacHomeCopy.subtitle(for: item))")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func stateDidChange() {
        let background: NSColor = isPressed ? MacColors.fill(0.12, light: 0.09) : (isHovered ? MacColors.fill(0.08, light: 0.06) : .clear)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = background.cgColor
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            playOverlay.animator().alphaValue = isHovered ? 1 : 0
            more.animator().alphaValue = isHovered ? 1 : 0
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        stateDidChange()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: HomeCopy.play, systemImage: "play.fill") { [item, actions] in
            actions.play(item, false)
        })
        menu.addItem(ClosureMenuItem(title: HomeCopy.shuffle, systemImage: "shuffle") { [item, actions] in
            actions.play(item, true)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: MacHomeCopy.removeFromJumpBackIn, systemImage: "minus.circle") { [item, actions] in
            actions.remove(item)
        })
        return menu
    }
}
