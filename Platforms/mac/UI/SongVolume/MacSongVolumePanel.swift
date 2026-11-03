import AppKit
import FlaccyCore
import FlaccyEngine

/// The popover that sets one song's own volume on the Mac: the song, the level
/// in large figures, a slider from −12 to +12 dB with a step either side, and
/// Reset. Every step is heard at once; the level is saved when it rests.
final class MacSongVolumePanel: NSViewController {

    private let track: Track
    private lazy var session = SongVolumeEditSession(track: track) { [weak self] message in
        MacToast.show(message, style: .error, in: self?.presentingWindow ?? NSApp.mainWindow)
    }
    private weak var presentingWindow: NSWindow?
    private let readout = NSTextField(labelWithString: "")
    private let slider = NSSlider()
    private let quieterButton = NSButton()
    private let louderButton = NSButton()
    private let resetButton = NSButton()

    init(track: Track, window: NSWindow?) {
        self.track = track
        presentingWindow = window
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView()
        view = root

        let heading = NSTextField(labelWithString: SongVolumeCopy.title)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        let song = NSTextField(labelWithString: track.title)
        song.font = .systemFont(ofSize: 15, weight: .bold)
        song.lineBreakMode = .byTruncatingTail
        let artist = NSTextField(labelWithString: track.artist)
        artist.font = .systemFont(ofSize: 12)
        artist.textColor = .secondaryLabelColor
        artist.lineBreakMode = .byTruncatingTail
        let titles = NSStackView(views: [heading, song, artist])
        titles.orientation = .vertical
        titles.alignment = .centerX
        titles.spacing = 2

        readout.font = .monospacedDigitSystemFont(ofSize: 34, weight: .bold)
        readout.alignment = .center
        readout.setAccessibilityRole(.staticText)

        let limit = SongGain.decibels(SongGain.maxTenths)
        slider.minValue = -limit
        slider.maxValue = limit
        slider.numberOfTickMarks = 5
        slider.tickMarkPosition = .below
        slider.isContinuous = true
        slider.controlSize = .regular
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.doubleValue = SongGain.decibels(session.level)
        slider.setAccessibilityLabel(SongVolumeCopy.title)
        slider.translatesAutoresizingMaskIntoConstraints = false

        configure(quieterButton, symbol: "minus", label: SongVolumeCopy.quieter, action: #selector(stepDown))
        configure(louderButton, symbol: "plus", label: SongVolumeCopy.louder, action: #selector(stepUp))
        let controls = NSStackView(views: [quieterButton, slider, louderButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 10

        let marks = NSStackView(views: [-SongGain.maxTenths, 0, SongGain.maxTenths].map { tenths in
            let mark = NSTextField(labelWithString: SongVolumeCopy.level(tenths))
            mark.font = .systemFont(ofSize: 10, weight: .medium)
            mark.textColor = .tertiaryLabelColor
            return mark
        })
        marks.orientation = .horizontal
        marks.distribution = .equalSpacing

        let explanation = NSTextField(wrappingLabelWithString: SongVolumeCopy.explanation)
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        explanation.alignment = .center

        resetButton.title = SongVolumeCopy.reset
        resetButton.bezelStyle = .rounded
        resetButton.target = self
        resetButton.action = #selector(resetLevel)

        let column = NSStackView(views: [titles, readout, controls, marks, explanation, resetButton])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 10
        column.setCustomSpacing(2, after: controls)
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            column.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
            column.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            column.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            view.widthAnchor.constraint(equalToConstant: 320),
            controls.widthAnchor.constraint(equalTo: column.widthAnchor),
            marks.leadingAnchor.constraint(equalTo: slider.leadingAnchor),
            marks.trailingAnchor.constraint(equalTo: slider.trailingAnchor),
            explanation.widthAnchor.constraint(equalTo: column.widthAnchor),
            titles.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor),
        ])
        render()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        session.save()
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.bezelStyle = .circular
        button.isBordered = true
        button.imagePosition = .imageOnly
        button.toolTip = label
        button.target = self
        button.action = action
        button.setAccessibilityLabel(label)
    }

    @objc private func sliderMoved() {
        let tenths = SongGain.snapped(decibels: slider.doubleValue)
        let previous = session.level
        guard session.move(to: tenths) else { return }
        if tenths == 0 || previous.signum() * tenths.signum() < 0 {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        render()
        if NSApp.currentEvent?.type == .leftMouseUp {
            slider.doubleValue = SongGain.decibels(session.level)
            session.save()
        }
    }

    @objc private func stepUp() {
        step(1)
    }

    @objc private func stepDown() {
        step(-1)
    }

    private func step(_ steps: Int) {
        guard session.move(to: SongGain.stepped(session.level, by: steps)) else { return }
        if session.level == 0 {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        slider.doubleValue = SongGain.decibels(session.level)
        render()
    }

    @objc private func resetLevel() {
        guard session.move(to: 0) else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        slider.doubleValue = 0
        session.save()
        render()
    }

    private func render() {
        let level = session.level
        readout.stringValue = SongVolumeCopy.level(level)
        readout.textColor = level == 0 ? .secondaryLabelColor : .labelColor
        readout.setAccessibilityLabel(SongVolumeCopy.accessibilityLevel(level))
        slider.setAccessibilityValueDescription(SongVolumeCopy.level(level))
        resetButton.isEnabled = level != 0
        quieterButton.isEnabled = level > -SongGain.maxTenths
        louderButton.isEnabled = level < SongGain.maxTenths
    }
}

/// Shows the Song Volume popover where the person's eyes already are: under the
/// volume control of whichever player is on screen, or as a sheet when neither is.
@MainActor
enum MacSongVolumePresenter {

    private static var anchors: [WeakAnchor] = []
    private static var popover: NSPopover?

    private struct WeakAnchor {
        weak var view: NSView?
    }

    /// Offers `view` as a place the popover may hang from, most recent first.
    static func register(anchor view: NSView) {
        anchors.removeAll { $0.view == nil || $0.view === view }
        anchors.insert(WeakAnchor(view: view), at: 0)
    }

    static func present(for track: Track, from anchor: NSView? = nil) {
        popover?.close()
        let visible = anchor ?? anchors.compactMap(\.view).first { $0.window?.isVisible == true && !$0.isHiddenOrHasHiddenAncestor }
        let window = visible?.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        let panel = MacSongVolumePanel(track: track, window: window)
        guard let visible else {
            window?.contentViewController?.presentAsSheet(panel)
            return
        }
        let created = NSPopover()
        created.behavior = .transient
        created.contentViewController = panel
        created.show(relativeTo: visible.bounds, of: visible, preferredEdge: .maxY)
        popover = created
    }

    #if DEBUG
    static var shownWindow: NSWindow? {
        popover?.contentViewController?.view.window
    }
    #endif

    /// The playing song's popover, for the Playback menu.
    static func presentForPlayingSong() {
        guard let track = AudioPlayer.shared.currentTrack else { return }
        present(for: track)
    }

    /// Steps the playing song's own volume from the keyboard and says where it landed.
    static func nudgePlayingSong(by steps: Int) {
        guard let track = AudioPlayer.shared.currentTrack else { return }
        let store = SongVolumeStore.shared
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        do {
            let level = try store.set(SongGain.stepped(store.level(for: track), by: steps), for: track)
            MacToast.show("\(SongVolumeCopy.title) \(SongVolumeCopy.level(level)) · \(track.title)", in: window)
        } catch {
            MacToast.show(SongVolumeCopy.saveFailed(title: track.title), style: .error, in: window)
        }
    }
}

/// The pill beside a player's equalizer button: hidden at 0 dB, otherwise the
/// playing song's own level, which opens the Song Volume popover from itself.
final class MacSongVolumePill: NSButton {

    init() {
        super.init(frame: .zero)
        bezelStyle = .push
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .bold)
        target = self
        action = #selector(open)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 20).isActive = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(refresh), name: SongVolumeStore.didChange, object: nil)
        center.addObserver(self, selector: #selector(refresh), name: AudioPlayer.trackDidChange, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 14, height: 20)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    @objc private func refresh() {
        let level = AudioPlayer.shared.currentTrack.map { SongVolumeStore.shared.level(for: $0) } ?? 0
        isHidden = level == 0
        attributedTitle = NSAttributedString(
            string: SongVolumeCopy.level(level),
            attributes: [.font: font ?? .systemFont(ofSize: 10.5, weight: .bold), .foregroundColor: NSColor.controlAccentColor]
        )
        toolTip = SongVolumeCopy.accessibilityLevel(level)
        setAccessibilityLabel(SongVolumeCopy.accessibilityLevel(level))
        applyColors()
        invalidateIntrinsicContentSize()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
        }
    }

    @objc private func open() {
        guard let track = AudioPlayer.shared.currentTrack else { return }
        MacSongVolumePresenter.present(for: track, from: self)
    }
}
