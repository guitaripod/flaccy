import AppKit
import FlaccyCore

/// What the context menu of one of the person's own presets can do.
enum MacDeckRowAction {
    case rename
    case export
    case copy
    case delete
}

/// The preset deck: every preset always in view beside the curve instead of
/// behind a menu. It only reports what the pointer, the keys and the buttons
/// did; the screen decides what to play, so rows are restyled in place and
/// rebuilt only when the person's own presets change, never under the pointer.
final class MacEqualizerDeck: NSView {

    var onPointed: ((String) -> Void)?
    var onLeft: (() -> Void)?
    var onKeep: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onAuditionBriefly: ((String) -> Void)?
    var onHoverPreviewChanged: ((Bool) -> Void)?
    var onRowAction: ((MacDeckRowAction, String) -> Void)?
    var onImport: (() -> Void)?
    var footerMenu: NSMenu?

    private let hoverSwitch = NSSwitch()
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var rows: [MacDeckRow] = []
    private var signature = ""
    private var currentID = ""
    private var hearingID: String?
    private var accent = EqualizerTheme.fallbackAccent
    private var moreButton: NSButton?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        let caption = NSTextField(labelWithString: String(localized: "Presets").uppercased())
        caption.font = .systemFont(ofSize: 10.5, weight: .bold)
        caption.textColor = .white.withAlphaComponent(0.45)

        hoverSwitch.controlSize = .mini
        hoverSwitch.target = self
        hoverSwitch.action = #selector(hoverSwitchChanged)
        hoverSwitch.setAccessibilityLabel(String(localized: "Hover to preview"))
        hoverSwitch.toolTip = String(localized: "Hover a preset to hear it")

        let header = NSStackView(views: [caption, NSView(), hoverSwitch])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.font = .systemFont(ofSize: 11.5)
        hintLabel.textColor = .white.withAlphaComponent(0.42)
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = MacDeckDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setAccessibilityLabel(String(localized: "Presets"))

        let importButton = NSButton(title: String(localized: "Import…"), target: self, action: #selector(importPressed))
        importButton.isBordered = false
        importButton.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
        importButton.imagePosition = .imageLeading
        importButton.contentTintColor = .white.withAlphaComponent(0.8)
        importButton.font = .systemFont(ofSize: 12.5, weight: .medium)
        importButton.translatesAutoresizingMaskIntoConstraints = false

        let more = NSButton(image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: String(localized: "More"))!, target: self, action: #selector(morePressed(_:)))
        more.isBordered = false
        more.contentTintColor = .white.withAlphaComponent(0.8)
        more.toolTip = String(localized: "More")
        more.translatesAutoresizingMaskIntoConstraints = false
        moreButton = more

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSStackView(views: [importButton, NSView(), more])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.translatesAutoresizingMaskIntoConstraints = false

        for subview in [header, hintLabel, scroll, divider, footer] { addSubview(subview) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            hintLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: divider.topAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            divider.heightAnchor.constraint(equalToConstant: 1),
            divider.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            footer.heightAnchor.constraint(equalToConstant: 24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    /// Reflects the hover-to-preview setting in the switch and the line under the header.
    func setHoverPreview(_ on: Bool) {
        hoverSwitch.state = on ? .on : .off
        hintLabel.stringValue = on
            ? String(localized: "Hover to hear it · click to keep it")
            : String(localized: "Click a preset to hear it")
    }

    /// Brings the list in line with the presets that exist and the one in
    /// force. Rows are rebuilt only when a name or a preset of the person's
    /// own appeared or went; everything else is restyled where it stands.
    func sync(userProfiles: [EqualizerProfile], currentID: String, accent: NSColor) {
        self.currentID = currentID
        self.accent = accent
        let wanted = userProfiles.map { "\($0.id):\($0.name)" }.joined(separator: "|")
        if rows.isEmpty || wanted != signature {
            rebuild(userProfiles)
            signature = wanted
        }
        for profile in userProfiles {
            rows.first { $0.profileID == profile.id }?.updateThumbnail(for: profile)
        }
        restyle()
    }

    /// Marks the preset being auditioned, or clears the mark.
    func setHearing(_ id: String?) {
        hearingID = id
        restyle()
    }

    /// Scrolls so the preset in force is on screen, for when the window opens.
    func revealCurrent() {
        layoutSubtreeIfNeeded()
        reveal(currentID)
    }

    /// Scrolls so the preset with `id` is on screen.
    func reveal(_ id: String) {
        layoutSubtreeIfNeeded()
        guard let row = rows.first(where: { $0.profileID == id }) else { return }
        row.scrollToVisible(row.bounds.insetBy(dx: 0, dy: -26))
    }

    private func restyle() {
        for row in rows {
            row.apply(isCurrent: row.profileID == currentID, isHearing: row.profileID == hearingID, accent: accent)
        }
    }

    private func rebuild(_ userProfiles: [EqualizerProfile]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = []
        for (title, profiles) in Self.sections(userProfiles) {
            let header = MacDeckSectionHeader(title: title)
            stack.addArrangedSubview(header)
            header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            for profile in profiles {
                let row = MacDeckRow(profile: profile, isUser: !profile.isBuiltIn)
                wire(row)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                rows.append(row)
            }
        }
    }

    private func wire(_ row: MacDeckRow) {
        let id = row.profileID
        row.onEnter = { [weak self] in self?.onPointed?(id) }
        row.onExit = { [weak self] in self?.onLeft?() }
        row.onKeep = { [weak self] in self?.onKeep?(id) }
        row.onCancel = { [weak self] in self?.onCancel?() }
        row.onAuditionBriefly = { [weak self] in self?.onAuditionBriefly?(id) }
        row.onMove = { [weak self, weak row] offset in
            guard let self, let row else { return }
            self.moveFocus(from: row, by: offset)
        }
        if row.isUser {
            row.menu = menu(for: id)
            row.onMore = { [weak self, weak row] button in
                guard let self, let row else { return }
                self.menu(for: row.profileID).popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
            }
        }
    }

    private func menu(for id: String) -> NSMenu {
        let menu = NSMenu()
        let entries: [(String, MacDeckRowAction)] = [
            (String(localized: "Rename…"), .rename),
            (String(localized: "Export as Text…"), .export),
            (String(localized: "Copy as Text"), .copy),
            (String(localized: "Delete"), .delete),
        ]
        for (title, action) in entries {
            menu.addItem(MacClosureMenuItem(title: title) { [weak self] in self?.onRowAction?(action, id) })
        }
        return menu
    }

    private func moveFocus(from row: MacDeckRow, by offset: Int) {
        guard let index = rows.firstIndex(where: { $0 === row }) else { return }
        let target = min(max(index + offset, 0), rows.count - 1)
        guard target != index else { return }
        window?.makeFirstResponder(rows[target])
        rows[target].scrollToVisible(rows[target].bounds.insetBy(dx: 0, dy: -26))
    }

    @objc private func hoverSwitchChanged() {
        onHoverPreviewChanged?(hoverSwitch.state == .on)
    }

    @objc private func importPressed() {
        onImport?()
    }

    @objc private func morePressed(_ sender: NSButton) {
        footerMenu?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    /// The sections of the list in the order every screen shows them.
    private static func sections(_ userProfiles: [EqualizerProfile]) -> [(String, [EqualizerProfile])] {
        var sections: [(String, [EqualizerProfile])] = [(String(localized: "Bit-perfect"), [EqualizerPresets.flat])]
        if !userProfiles.isEmpty { sections.append((String(localized: "Yours"), userProfiles)) }
        sections.append((String(localized: "Tune"), EqualizerPresets.tuneKeys.compactMap(EqualizerPresets.profile(forKey:))))
        sections.append((String(localized: "Genres"), EqualizerPresets.genreKeys.compactMap(EqualizerPresets.profile(forKey:))))
        return sections
    }
}

/// The scrolling list's document: flipped, so the first row sits at the top.
private final class MacDeckDocumentView: NSView {

    override var isFlipped: Bool { true }
}

/// A section's small caption between groups of presets.
private final class MacDeckSectionHeader: NSView {

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 10.5, weight: .bold)
        label.textColor = .white.withAlphaComponent(0.4)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// One preset: its curve, its name, what it is for. The profile in force wears
/// an accent bar and a tick; the one being auditioned is washed in the accent
/// and shows the animated bars in the tick's place.
final class MacDeckRow: NSView {

    let profileID: String
    let isUser: Bool

    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onKeep: (() -> Void)?
    var onCancel: (() -> Void)?
    var onAuditionBriefly: (() -> Void)?
    var onMove: ((Int) -> Void)?
    var onMore: ((NSButton) -> Void)?

    private let thumbnail = MacCurveThumbnailView()
    private let bars = PlayingBarsView()
    private let tick = NSImageView()
    private let moreButton = NSButton()
    private let accentBar = CALayer()
    private var isPointed = false
    private var isCurrent = false
    private var isHearing = false
    private var accent = EqualizerTheme.fallbackAccent
    private var thumbnailSource: EqualizerProfile?
    private var thumbnailPoints: [Double] = []

    init(profile: EqualizerProfile, isUser: Bool) {
        profileID = profile.id
        self.isUser = isUser
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        accentBar.cornerRadius = 1.5
        accentBar.isHidden = true
        layer?.addSublayer(accentBar)

        let name = EqualizerCopy.name(of: profile)
        let note = Self.note(for: profile)
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .white.withAlphaComponent(0.95)
        nameLabel.lineBreakMode = .byTruncatingTail
        let noteLabel = NSTextField(labelWithString: note)
        noteLabel.font = .systemFont(ofSize: 11.5)
        noteLabel.textColor = .white.withAlphaComponent(0.5)
        noteLabel.lineBreakMode = .byTruncatingTail
        let texts = NSStackView(views: [nameLabel, noteLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 0
        texts.setHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        for label in [nameLabel, noteLabel] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }

        thumbnailPoints = Self.points(for: profile)
        thumbnail.setPoints(thumbnailPoints, accent: .white.withAlphaComponent(0.7))
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        thumbnailSource = profile

        bars.isHidden = true
        bars.translatesAutoresizingMaskIntoConstraints = false
        tick.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        tick.symbolConfiguration = .init(pointSize: 12, weight: .bold)
        tick.isHidden = true
        tick.translatesAutoresizingMaskIntoConstraints = false

        moreButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: String(localized: "More for \(name)"))
        moreButton.isBordered = false
        moreButton.contentTintColor = .white.withAlphaComponent(0.6)
        moreButton.target = self
        moreButton.action = #selector(morePressed)
        moreButton.isHidden = !isUser
        moreButton.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [thumbnail, texts, bars, tick, moreButton])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.distribution = .fill
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            thumbnail.widthAnchor.constraint(equalToConstant: 56),
            thumbnail.heightAnchor.constraint(equalToConstant: 26),
            bars.widthAnchor.constraint(equalToConstant: 16),
            bars.heightAnchor.constraint(equalToConstant: 14),
            tick.widthAnchor.constraint(equalToConstant: 16),
            moreButton.widthAnchor.constraint(equalToConstant: 20),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(name)
        setAccessibilityHelp(note)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: String(localized: "Audition")) { [weak self] in
                self?.onAuditionBriefly?()
                return true
            }
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 44) }

    /// Redraws the thumbnail when the preset's own curve was edited.
    func updateThumbnail(for profile: EqualizerProfile) {
        guard thumbnailSource != profile else { return }
        thumbnailSource = profile
        thumbnailPoints = Self.points(for: profile)
        thumbnail.setPoints(thumbnailPoints, accent: thumbnailColor)
    }

    /// Restyles the row for the profile in force and the one being auditioned.
    func apply(isCurrent: Bool, isHearing: Bool, accent: NSColor) {
        guard isCurrent != self.isCurrent || isHearing != self.isHearing || accent != self.accent else { return }
        self.isCurrent = isCurrent
        self.isHearing = isHearing
        self.accent = accent
        restyle()
        bars.tint = accent
        bars.setPlaying(isHearing)
        setAccessibilitySelected(isCurrent)
    }

    private var thumbnailColor: NSColor {
        isCurrent || isHearing ? accent : .white.withAlphaComponent(0.7)
    }

    private func restyle() {
        let wash: NSColor
        if isHearing {
            wash = accent.withAlphaComponent(0.28)
        } else if isCurrent {
            wash = accent.withAlphaComponent(0.14)
        } else if isPointed {
            wash = NSColor.white.withAlphaComponent(0.06)
        } else {
            wash = .clear
        }
        layer?.backgroundColor = wash.cgColor
        accentBar.backgroundColor = accent.cgColor
        accentBar.isHidden = !isCurrent
        bars.isHidden = !isHearing
        tick.isHidden = !(isCurrent && !isHearing)
        tick.contentTintColor = accent
        thumbnail.setPoints(thumbnailPoints, accent: thumbnailColor)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        accentBar.frame = CGRect(x: 0, y: 8, width: 3, height: max(bounds.height - 16, 0))
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === moreButton ? hit : self
    }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        isPointed = true
        restyle()
        onEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        isPointed = false
        restyle()
        onExit?()
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onKeep?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: onMove?(1)
        case 126: onMove?(-1)
        case 36, 76, 49: onKeep?()
        case 53: onCancel?()
        default: super.keyDown(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        onEnter?()
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        onExit?()
        return super.resignFirstResponder()
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 11, yRadius: 11).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func accessibilityPerformPress() -> Bool {
        onKeep?()
        return true
    }

    @objc private func morePressed() {
        onMore?(moreButton)
    }

    private static func points(for profile: EqualizerProfile) -> [Double] {
        BiquadMath.curve(profile.resolvedBands(), points: 40)
    }

    private static func note(for profile: EqualizerProfile) -> String {
        if let key = EqualizerPresets.key(forID: profile.id) { return EqualizerCopy.presetSubtitle(forKey: key) }
        return profile.kind == .graphic ? String(localized: "Simple") : String(localized: "Advanced · \(profile.bands.count) bands")
    }
}

/// The capsule on the curve card that names the preset being heard: animated
/// bars and "Hearing <name>", faded in while an audition lasts and out after.
/// It is information only, so it never takes focus or a click.
final class MacEqualizerPreviewPill: NSView {

    private let bars = PlayingBarsView()
    private let label = NSTextField(labelWithString: "")
    private var accent = EqualizerTheme.fallbackAccent
    private var isShown = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1
        alphaValue = 0
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bars.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [bars, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 13)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            bars.widthAnchor.constraint(equalToConstant: 16),
            bars.heightAnchor.constraint(equalToConstant: 14),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        setAccessibilityElement(false)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    /// Tints the capsule and its bars with the accent.
    func setAccent(_ color: NSColor) {
        guard color != accent else { return }
        accent = color
        restyle()
    }

    /// Fades the pill in for `name`, or out when `name` is nil.
    func show(_ name: String?) {
        isShown = name != nil
        if let name {
            label.stringValue = String(localized: "Hearing \(name)")
            label.setAccessibilityLabel(label.stringValue)
            bars.setPlaying(true)
        }
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            animator().alphaValue = name == nil ? 0 : 1
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if self?.isShown == false { self?.bars.setPlaying(false) }
            }
        }
    }

    private func restyle() {
        layer?.backgroundColor = accent.withAlphaComponent(0.22).cgColor
        layer?.borderColor = accent.withAlphaComponent(0.55).cgColor
        bars.tint = accent
    }
}
