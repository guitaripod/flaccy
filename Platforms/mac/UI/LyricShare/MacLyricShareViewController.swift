import AppKit
import FlaccyCore
import MidgarCore

/// The Mac window that turns lyrics into a clip: a live preview playing the
/// song's own audio on the left; template, format, colours, font and lines on
/// the right; Save and Share at the foot. Mirrors the iPhone sheet.
final class MacLyricShareViewController: NSViewController {

    /// The widest the preview renders, in pixels: sharp on a Retina window,
    /// cheap enough to redraw 30 times a second.
    static let previewPixelWidth: CGFloat = 720
    static let controlsWidth: CGFloat = 380
    static let previewFrameInterval: TimeInterval = 1.0 / 30

    let session: LyricShareSession
    let preview = LyricSharePreviewPlayer()
    var onClose: (() -> Void)?

    let well = LyricSharePreviewWell()
    let audioNote = NSTextField(wrappingLabelWithString: "")
    let controlsScroll = NSScrollView()
    let controlsDocument = FlippedView()
    let controlsStack = NSStackView()
    var templateButtons: [LyricShareTemplate: LyricShareChipButton] = [:]
    var themeButtons: [LyricShareTheme: LyricShareChipButton] = [:]
    let formatControl = NSSegmentedControl(
        labels: LyricShareFormat.allCases.map(LyricShareCopy.format), trackingMode: .selectOne, target: nil, action: nil)
    let typefaceControl = NSSegmentedControl(
        labels: LyricShareTypeface.allCases.map(LyricShareCopy.typeface), trackingMode: .selectOne, target: nil, action: nil)
    let coverToggle = NSButton(checkboxWithTitle: LyricShareCopy.showCover, target: nil, action: nil)
    let visualizerToggle = NSButton(checkboxWithTitle: LyricShareCopy.showVisualizer, target: nil, action: nil)
    let markToggle = NSButton(checkboxWithTitle: LyricShareCopy.showMark, target: nil, action: nil)
    let linesHint = NSTextField(wrappingLabelWithString: "")
    let startSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    let startLabel = NSTextField(labelWithString: "")
    var lineRows: [Int: LyricShareLineRow] = [:]
    let saveImageButton = NSButton(title: LyricShareCopy.saveImage, target: nil, action: nil)
    let saveVideoButton = NSButton(title: LyricShareCopy.saveVideo, target: nil, action: nil)
    let shareButton = NSButton(title: LyricShareCopy.shareVideo, target: nil, action: nil)
    let progressBar = NSProgressIndicator()
    let progressLabel = NSTextField(labelWithString: LyricShareCopy.making)
    let cancelExportButton = NSButton(title: String(localized: "Cancel"), target: nil, action: nil)
    let exportActions = NSStackView()
    let exportProgress = NSStackView()
    var cancelFlag: LyricShareCancelFlag?
    private var renderer: LyricShareRenderer?
    private var ticker: Timer?

    init(session: LyricShareSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    isolated deinit {
        ticker?.invalidate()
    }

    var isExporting: Bool {
        cancelFlag != nil
    }

    override func loadView() {
        let root = LyricShareRootView()
        root.frame = NSRect(origin: .zero, size: LyricShareWindowController.contentSize)
        view = root

        let header = buildHeader()
        let previewPane = buildPreviewPane()
        buildControls()
        let bar = buildBottomBar()
        let topRule = NSBox()
        topRule.boxType = .separator
        let bottomRule = NSBox()
        bottomRule.boxType = .separator
        for subview in [header, topRule, previewPane, controlsScroll, bottomRule, bar] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 56),
            topRule.topAnchor.constraint(equalTo: header.bottomAnchor),
            topRule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            previewPane.topAnchor.constraint(equalTo: topRule.bottomAnchor, constant: 16),
            previewPane.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            previewPane.bottomAnchor.constraint(equalTo: bottomRule.topAnchor, constant: -16),
            previewPane.trailingAnchor.constraint(equalTo: controlsScroll.leadingAnchor, constant: -8),
            controlsScroll.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            controlsScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            controlsScroll.bottomAnchor.constraint(equalTo: bottomRule.topAnchor),
            controlsScroll.widthAnchor.constraint(equalToConstant: Self.controlsWidth),
            bottomRule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomRule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomRule.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 60),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        session.onChange = { [weak self] in self?.sessionChanged() }
        session.onAudioChange = { [weak self] in self?.audioChanged() }
        well.onPreviewResize = { [weak self] in self?.rebuildRenderer() }
        applyStyle()
        refreshLines()
        session.reloadAudio()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(view)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == Self.spaceKeyCode, !event.isARepeat {
            togglePreview()
        } else {
            super.keyDown(with: event)
        }
    }

    /// Escape stops a running export first, and closes the window otherwise.
    override func cancelOperation(_ sender: Any?) {
        if let cancelFlag {
            cancelFlag.set()
        } else {
            onClose?()
        }
    }

    private static let spaceKeyCode: UInt16 = 49

    /// Stops everything the window started: a running export, the preview's
    /// audio and its redraw timer. The song resumes if the preview paused it.
    func teardown() {
        cancelFlag?.set()
        preview.stop()
        stopTicker()
        session.onChange = nil
        session.onAudioChange = nil
    }

    private func buildHeader() -> NSView {
        let title = NSTextField(labelWithString: LyricShareCopy.sheetTitle)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "\(session.title) — \(session.artist)")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let close = NSButton(title: LyricShareCopy.close, target: self, action: #selector(closeTapped))
        close.bezelStyle = .rounded

        let header = NSView()
        for subview in [text, close] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            text.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -16),
            close.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        return header
    }

    private func buildPreviewPane() -> NSView {
        well.playButton.target = self
        well.playButton.action = #selector(togglePreviewTapped)
        well.playButton.setAccessibilityLabel(LyricShareCopy.playPreview)
        well.imageView.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(togglePreviewTapped)))

        audioNote.font = .systemFont(ofSize: 12, weight: .medium)
        audioNote.textColor = .secondaryLabelColor
        audioNote.alignment = .center
        audioNote.isHidden = true

        let pane = NSStackView()
        pane.orientation = .vertical
        pane.alignment = .leading
        pane.spacing = 10
        pane.addFullWidth(well)
        pane.addFullWidth(audioNote)
        return pane
    }

    @objc private func closeTapped() {
        onClose?()
    }

    func sessionChanged() {
        applyStyle()
        refreshLines()
        rebuildRenderer()
    }

    func audioChanged() {
        preview.load(session.previewURL)
        if session.isLoadingAudio { well.spinner.startAnimation(nil) } else { well.spinner.stopAnimation(nil) }
        well.playButton.isHidden = session.isLoadingAudio || session.audio == nil
        if let failure = session.audioFailure {
            audioNote.stringValue = LyricShareCopy.audioFailure(failure, song: session.title)
            audioNote.isHidden = false
        } else {
            audioNote.stringValue = session.isLoadingAudio ? LyricShareCopy.readingAudio : ""
            audioNote.isHidden = !session.isLoadingAudio
        }
        saveVideoButton.isEnabled = session.audio != nil && !isExporting
        shareButton.isEnabled = session.audio != nil && !isExporting
        updatePlayButton()
        rebuildRenderer()
    }

    private func previewPixels() -> CGFloat {
        let scale = view.window?.backingScaleFactor ?? 2
        let pointsOnScreen = well.imageView.convert(well.imageView.bounds, to: nil).width
        return min(pointsOnScreen * scale, Self.previewPixelWidth)
    }

    func rebuildRenderer() {
        let pixels = previewPixels()
        guard pixels > 1 else { return }
        let width = CGFloat(session.style.format.pixelWidth)
        renderer = LyricShareRenderer(scene: session.scene(), scale: pixels / width)
        drawPreview()
    }

    /// The frame the preview shows: where the preview player is, or a
    /// moment with the first line on screen while it is paused.
    private func previewFrameIndex() -> Int {
        let frames = LyricShareClip.frameCount(session.window)
        if preview.isPlaying {
            return min(Int(preview.currentTime * Double(LyricShareClip.fps)), frames - 1)
        }
        guard session.isTimed else { return min(LyricShareClip.fps, frames - 1) }
        let first = session.lyrics.document.lines[session.selection.first]
        let settled = first.start + LyricShareMotion.entranceDuration - session.window.lyricStart
        return min(max(Int(settled * Double(LyricShareClip.fps)), 0), frames - 1)
    }

    func drawPreview() {
        guard let renderer, let image = renderer.image(frame: previewFrameIndex()) else { return }
        well.imageView.image = NSImage(cgImage: image, size: .zero)
    }

    /// A run-loop timer rather than a display link: AppKit pauses a view's
    /// display link whenever the app is not frontmost, and the preview would
    /// freeze while the song plays. It runs only while the preview plays.
    private func startTicker() {
        guard ticker == nil else { return }
        let timer = Timer(
            timeInterval: Self.previewFrameInterval, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer.tolerance = Self.previewFrameInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    @objc private func tick() {
        drawPreview()
    }

    @objc private func togglePreviewTapped() {
        togglePreview()
    }

    func togglePreview() {
        guard session.audio != nil else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        if preview.isPlaying { preview.pause() } else { preview.play() }
        updatePlayButton()
        drawPreview()
    }

    func updatePlayButton() {
        let playing = preview.isPlaying
        let label = playing ? LyricShareCopy.pausePreview : LyricShareCopy.playPreview
        well.playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: label)
        well.playButton.setAccessibilityLabel(label)
        well.playButton.toolTip = label
        if playing { startTicker() } else { stopTicker() }
    }
}
