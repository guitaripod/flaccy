import AppKit
import MidgarCore
import AVFoundation
import AVKit
import Combine

/// Shared sleep-timer menu used by the immersive view, the transport bar, and
/// the menu bar extra; items dispatch straight to the player.
@MainActor
enum SleepTimerMenuBuilder {

    static func build() -> NSMenu {
        let menu = NSMenu()
        for minutes in [15, 30, 45, 60, 90] {
            let item = menu.addItem(
                withTitle: String(localized: "\(minutes) minutes"), action: #selector(SleepTimerMenuTarget.setMinutes(_:)), keyEquivalent: ""
            )
            item.tag = minutes
            item.target = SleepTimerMenuTarget.shared
        }
        menu.addItem(.separator())
        let endOfTrack = menu.addItem(
            withTitle: String(localized: "End of Track"), action: #selector(SleepTimerMenuTarget.endOfTrack(_:)), keyEquivalent: ""
        )
        endOfTrack.target = SleepTimerMenuTarget.shared
        endOfTrack.state = AudioPlayer.shared.sleepAtEndOfTrack ? .on : .off
        let active = AudioPlayer.shared.sleepTimerRemaining != nil || AudioPlayer.shared.sleepAtEndOfTrack
        if active {
            menu.addItem(.separator())
            let cancel = menu.addItem(
                withTitle: String(localized: "Cancel Timer"), action: #selector(SleepTimerMenuTarget.cancel(_:)), keyEquivalent: ""
            )
            cancel.target = SleepTimerMenuTarget.shared
        }
        return menu
    }
}

final class SleepTimerMenuTarget: NSObject {

    @MainActor static let shared = SleepTimerMenuTarget()

    @MainActor @objc func setMinutes(_ sender: NSMenuItem) {
        AudioPlayer.shared.setSleepTimer(minutes: sender.tag)
        MidgarLog.info("Sleep timer set: \(sender.tag) minutes", category: .playback)
    }

    @MainActor @objc func endOfTrack(_ sender: NSMenuItem) {
        AudioPlayer.shared.setSleepTimerEndOfTrack()
        MidgarLog.info("Sleep timer set: end of track", category: .playback)
    }

    @MainActor @objc func cancel(_ sender: NSMenuItem) {
        AudioPlayer.shared.cancelSleepTimer()
        MidgarLog.info("Sleep timer cancelled", category: .playback)
    }
}

/// Glass action capsule with an SF Symbol and a short title; highlights while
/// toggled active.
final class CapsuleButton: NSControl {

    var onTap: ((CapsuleButton) -> Void)?

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    var isActiveToggle = false {
        didSet { refreshBackground() }
    }

    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    let background = NSView()
    var isHovered = false

    init(symbolName: String, title: String, onTap: @escaping (CapsuleButton) -> Void) {
        self.onTap = onTap
        super.init(frame: .zero)
        wantsLayer = true

        background.wantsLayer = true
        background.layer?.cornerRadius = 15
        background.layer?.cornerCurve = .continuous
        background.layer?.backgroundColor = MacColors.fill(0.1).cgColor
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        icon.contentTintColor = .labelColor
        label.stringValue = title
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .labelColor

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refreshBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refreshBackground()
    }

    override func mouseDown(with event: NSEvent) {
        onTap?(self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    func refreshBackground() {
        let alpha: CGFloat = isActiveToggle ? 0.28 : (isHovered ? 0.18 : 0.1)
        background.layer?.backgroundColor = MacColors.fill(alpha).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBackground()
    }
}

/// A container that runs a callback whenever the effective appearance flips, so
/// layer-backed colors (which don't auto-resolve) can be recomputed.
final class AppearanceReactiveView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// Borderless text button that underlines on hover, used for the artist name.
final class HoverUnderlineButton: NSButton {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        setButtonType(.momentaryChange)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        applyUnderline(true)
    }

    override func mouseExited(with event: NSEvent) {
        applyUnderline(false)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    func applyUnderline(_ underlined: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 15),
            .foregroundColor: contentTintColor ?? .labelColor,
            .underlineStyle: underlined ? NSUnderlineStyle.single.rawValue : 0,
        ]
        attributedTitle = NSAttributedString(string: title, attributes: attributes)
    }
}

extension NSLayoutConstraint {
    func with(priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
