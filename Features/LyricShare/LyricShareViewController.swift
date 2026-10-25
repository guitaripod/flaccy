import FlaccyCore
import UIKit

/// The iPhone sheet that turns lyrics into a clip: a live preview playing the
/// song's own audio on top, the template, format, colours, font and lines
/// beneath, and Share Video or Share Image at the foot.
final class LyricShareViewController: UIViewController {

    /// The widest the preview renders, in pixels: sharp on any iPhone, cheap
    /// enough to redraw every frame.
    static let previewPixelWidth: CGFloat = 540

    private let session: LyricShareSession
    private let preview = LyricSharePreviewPlayer()
    private let previewImage = UIImageView()
    private let previewFrame = UIView()
    private var previewAspect: NSLayoutConstraint?
    private let playButton = UIButton(type: .system)
    private let audioSpinner = UIActivityIndicatorView(style: .medium)
    private let audioNote = UILabel()
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var templateButtons: [LyricShareTemplate: UIButton] = [:]
    private let formatControl = UISegmentedControl(items: LyricShareFormat.allCases.map(LyricShareCopy.format))
    private var themeButtons: [LyricShareTheme: UIButton] = [:]
    private let typefaceControl = UISegmentedControl(items: LyricShareTypeface.allCases.map(LyricShareCopy.typeface))
    private let coverToggle = UIButton(type: .system)
    private let visualizerToggle = UIButton(type: .system)
    private let markToggle = UIButton(type: .system)
    private let linesHint = UILabel()
    private let startSlider = UISlider()
    private let startLabel = UILabel()
    private var lineButtons: [Int: UIButton] = [:]
    private let shareVideoButton = UIButton(type: .system)
    private let shareImageButton = UIButton(type: .system)
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let progressLabel = UILabel()
    private let cancelExportButton = UIButton(type: .system)
    private let exportBar = UIStackView()
    private let progressBar = UIStackView()
    private var renderer: LyricShareRenderer?
    private var displayLink: CADisplayLink?
    private var cancelFlag: LyricShareCancelFlag?
    private let selection = UISelectionFeedbackGenerator()

    init(session: LyricShareSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    /// Presents the sheet over `presenter` in its own navigation bar.
    static func present(_ session: LyricShareSession, from presenter: UIViewController) {
        let controller = LyricShareViewController(session: session)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        presenter.present(navigation, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        title = LyricShareCopy.sheetTitle
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.close() })
        buildPreview()
        buildControls()
        buildExportBar()
        session.onChange = { [weak self] in self?.sessionChanged() }
        session.onAudioChange = { [weak self] in self?.audioChanged() }
        applyStyle()
        refreshLines()
        session.reloadAudio()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startDisplayLink()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            teardown()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if renderer == nil || renderer?.pixelWidth != Int(previewPixels().rounded()) {
            rebuildRenderer()
        }
    }

    private func close() {
        teardown()
        dismiss(animated: true)
    }

    private func teardown() {
        cancelFlag?.set()
        preview.stop()
        displayLink?.invalidate()
        displayLink = nil
    }

    private func buildPreview() {
        previewFrame.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewFrame)
        previewImage.contentMode = .scaleAspectFit
        previewImage.layer.cornerRadius = 16
        previewImage.layer.cornerCurve = .continuous
        previewImage.clipsToBounds = true
        previewImage.translatesAutoresizingMaskIntoConstraints = false
        previewImage.isAccessibilityElement = true
        previewImage.accessibilityTraits = .image
        previewImage.isUserInteractionEnabled = true
        previewImage.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(togglePreview)))
        previewFrame.addSubview(previewImage)

        var play = UIButton.Configuration.filled()
        play.cornerStyle = .capsule
        play.baseBackgroundColor = .black.withAlphaComponent(0.55)
        play.baseForegroundColor = .white
        play.image = UIImage(systemName: "play.fill")
        play.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        playButton.configuration = play
        playButton.accessibilityLabel = LyricShareCopy.playPreview
        playButton.addAction(UIAction { [weak self] _ in self?.togglePreview() }, for: .touchUpInside)
        playButton.translatesAutoresizingMaskIntoConstraints = false
        previewFrame.addSubview(playButton)

        audioSpinner.color = .white
        audioSpinner.hidesWhenStopped = true
        audioSpinner.translatesAutoresizingMaskIntoConstraints = false
        previewFrame.addSubview(audioSpinner)

        audioNote.font = .scaled(.footnote, size: 13, weight: .medium)
        audioNote.adjustsFontForContentSizeCategory = true
        audioNote.textColor = .secondaryLabel
        audioNote.numberOfLines = 0
        audioNote.textAlignment = .center
        audioNote.isHidden = true
        audioNote.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(audioNote)

        NSLayoutConstraint.activate([
            previewFrame.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            previewFrame.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            previewFrame.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            previewFrame.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.4),
            previewImage.centerXAnchor.constraint(equalTo: previewFrame.centerXAnchor),
            previewImage.topAnchor.constraint(equalTo: previewFrame.topAnchor),
            previewImage.bottomAnchor.constraint(equalTo: previewFrame.bottomAnchor),
            previewImage.widthAnchor.constraint(lessThanOrEqualTo: previewFrame.widthAnchor),
            playButton.trailingAnchor.constraint(equalTo: previewImage.trailingAnchor, constant: -10),
            playButton.bottomAnchor.constraint(equalTo: previewImage.bottomAnchor, constant: -10),
            audioSpinner.centerXAnchor.constraint(equalTo: playButton.centerXAnchor),
            audioSpinner.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            audioNote.topAnchor.constraint(equalTo: previewFrame.bottomAnchor, constant: 6),
            audioNote.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            audioNote.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
    }

    private func buildControls() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: audioNote.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16),
        ])

        stack.addArrangedSubview(section(LyricShareCopy.templateHeader, content: templateRow()))
        formatControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.update { $0.format = LyricShareFormat.allCases[self.formatControl.selectedSegmentIndex] }
        }, for: .valueChanged)
        stack.addArrangedSubview(section(LyricShareCopy.formatHeader, content: formatControl))
        stack.addArrangedSubview(section(LyricShareCopy.colorsHeader, content: themeRow()))
        typefaceControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.update { $0.typeface = LyricShareTypeface.allCases[self.typefaceControl.selectedSegmentIndex] }
        }, for: .valueChanged)
        stack.addArrangedSubview(section(LyricShareCopy.fontHeader, content: typefaceControl))
        stack.addArrangedSubview(toggleRow())
        stack.addArrangedSubview(linesSection())
    }

    private func section(_ title: String, content: UIView) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = .scaled(.subheadline, size: 15, weight: .semibold)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.accessibilityTraits = .header
        let column = UIStackView(arrangedSubviews: [label, content])
        column.axis = .vertical
        column.spacing = 8
        return column
    }

    private func templateRow() -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = 8
        for template in LyricShareTemplate.allCases {
            let button = UIButton(type: .system)
            button.accessibilityHint = LyricShareCopy.templateHint(template)
            button.addAction(UIAction { [weak self] _ in self?.update { $0.template = template } }, for: .touchUpInside)
            templateButtons[template] = button
            row.addArrangedSubview(button)
        }
        return row
    }

    private func themeRow() -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = 8
        for theme in LyricShareTheme.allCases {
            let button = UIButton(type: .system)
            button.addAction(UIAction { [weak self] _ in self?.update { $0.theme = theme } }, for: .touchUpInside)
            button.accessibilityLabel = LyricShareCopy.theme(theme)
            themeButtons[theme] = button
            row.addArrangedSubview(button)
        }
        return row
    }

    private func toggleRow() -> UIView {
        let row = UIStackView(arrangedSubviews: [coverToggle, visualizerToggle, markToggle])
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = 8
        coverToggle.addAction(UIAction { [weak self] _ in self?.update { $0.showArtwork.toggle() } }, for: .touchUpInside)
        visualizerToggle.addAction(UIAction { [weak self] _ in self?.update { $0.showVisualizer.toggle() } }, for: .touchUpInside)
        markToggle.addAction(UIAction { [weak self] _ in self?.update { $0.showMark.toggle() } }, for: .touchUpInside)
        return row
    }

    private func linesSection() -> UIView {
        linesHint.font = .scaled(.footnote, size: 13, weight: .regular)
        linesHint.adjustsFontForContentSizeCategory = true
        linesHint.textColor = .secondaryLabel
        linesHint.numberOfLines = 0
        let column = UIStackView(arrangedSubviews: [linesHint])
        column.axis = .vertical
        column.spacing = 6
        if !session.isTimed {
            startLabel.font = .scaled(.footnote, size: 13, weight: .medium)
            startLabel.adjustsFontForContentSizeCategory = true
            startSlider.minimumValue = 0
            startSlider.maximumValue = Float(max(session.trackDuration - LyricShareClip.plainDuration, 0))
            startSlider.value = Float(session.plainStart)
            startSlider.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.session.setPlainStart(Double(self.startSlider.value))
            }, for: .valueChanged)
            column.addArrangedSubview(startLabel)
            column.addArrangedSubview(startSlider)
        }
        let rows = UIStackView()
        rows.axis = .vertical
        rows.spacing = 2
        for (index, text) in session.pickerLines.enumerated() {
            let button = UIButton(type: .system)
            var config = UIButton.Configuration.plain()
            config.title = text
            config.titleAlignment = .leading
            config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
            config.background.cornerRadius = 10
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = UIFont.scaled(.body, size: 16, weight: .semibold)
                return attributes
            }
            button.configuration = config
            button.contentHorizontalAlignment = .leading
            button.titleLabel?.numberOfLines = 0
            button.isEnabled = session.isPickable(index)
            button.addAction(UIAction { [weak self] _ in
                self?.selection.selectionChanged()
                self?.session.toggle(line: index)
            }, for: .touchUpInside)
            lineButtons[index] = button
            rows.addArrangedSubview(button)
        }
        column.addArrangedSubview(rows)
        return section(LyricShareCopy.linesHeader, content: column)
    }

    private func buildExportBar() {
        var image = UIButton.Configuration.gray()
        image.image = UIImage(systemName: "photo")
        image.title = LyricShareCopy.shareImage
        image.imagePadding = 6
        image.cornerStyle = .capsule
        shareImageButton.configuration = image
        shareImageButton.addAction(UIAction { [weak self] _ in self?.export(video: false) }, for: .touchUpInside)

        var video = UIButton.Configuration.filled()
        video.image = UIImage(systemName: "play.rectangle.fill")
        video.title = LyricShareCopy.shareVideo
        video.imagePadding = 6
        video.cornerStyle = .capsule
        shareVideoButton.configuration = video
        shareVideoButton.addAction(UIAction { [weak self] _ in self?.export(video: true) }, for: .touchUpInside)

        exportBar.addArrangedSubview(shareImageButton)
        exportBar.addArrangedSubview(shareVideoButton)
        exportBar.axis = .horizontal
        exportBar.spacing = 10
        exportBar.distribution = .fillEqually

        progressLabel.text = LyricShareCopy.making
        progressLabel.font = .scaled(.footnote, size: 13, weight: .semibold)
        progressLabel.adjustsFontForContentSizeCategory = true
        var cancel = UIButton.Configuration.plain()
        cancel.title = String(localized: "Cancel")
        cancelExportButton.configuration = cancel
        cancelExportButton.addAction(UIAction { [weak self] _ in self?.cancelFlag?.set() }, for: .touchUpInside)
        let progressColumn = UIStackView(arrangedSubviews: [progressLabel, progressView])
        progressColumn.axis = .vertical
        progressColumn.spacing = 6
        progressBar.addArrangedSubview(progressColumn)
        progressBar.addArrangedSubview(cancelExportButton)
        progressBar.axis = .horizontal
        progressBar.alignment = .center
        progressBar.spacing = 12
        progressBar.isHidden = true

        let bar = UIStackView(arrangedSubviews: [exportBar, progressBar])
        bar.axis = .vertical
        bar.translatesAutoresizingMaskIntoConstraints = false
        let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        background.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(background)
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            shareVideoButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
            background.topAnchor.constraint(equalTo: bar.topAnchor, constant: -10),
            background.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            background.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: background.topAnchor),
        ])
    }

    private func update(_ change: (inout LyricShareStyle) -> Void) {
        var style = session.style
        change(&style)
        guard style != session.style else { return }
        selection.selectionChanged()
        session.style = style
    }

    private func sessionChanged() {
        applyStyle()
        refreshLines()
        rebuildRenderer()
    }

    private func audioChanged() {
        preview.load(session.previewURL)
        audioSpinner.isHidden = !session.isLoadingAudio
        if session.isLoadingAudio { audioSpinner.startAnimating() } else { audioSpinner.stopAnimating() }
        playButton.isHidden = session.isLoadingAudio || session.audio == nil
        if let failure = session.audioFailure {
            audioNote.text = LyricShareCopy.audioFailure(failure, song: session.title)
            audioNote.isHidden = false
        } else {
            audioNote.text = session.isLoadingAudio ? LyricShareCopy.readingAudio : nil
            audioNote.isHidden = !session.isLoadingAudio
        }
        shareVideoButton.isEnabled = session.audio != nil
        updatePlayButton()
        rebuildRenderer()
    }

    private func applyStyle() {
        let style = session.style
        for (template, button) in templateButtons {
            var config = template == style.template ? UIButton.Configuration.tinted() : UIButton.Configuration.gray()
            config.image = UIImage(systemName: LyricShareCopy.templateSymbol(template))
            config.title = LyricShareCopy.template(template)
            config.imagePlacement = .top
            config.imagePadding = 6
            config.cornerStyle = .large
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = UIFont.scaled(.caption1, size: 12, weight: .semibold)
                return attributes
            }
            button.configuration = config
            button.isSelected = template == style.template
        }
        formatControl.selectedSegmentIndex = LyricShareFormat.allCases.firstIndex(of: style.format) ?? 0
        typefaceControl.selectedSegmentIndex = LyricShareTypeface.allCases.firstIndex(of: style.typeface) ?? 0
        for (theme, button) in themeButtons {
            let palette = session.palette(for: theme)
            var config = UIButton.Configuration.plain()
            config.image = Self.swatch(palette, selected: theme == style.theme)
            config.title = LyricShareCopy.theme(theme)
            config.imagePlacement = .top
            config.imagePadding = 6
            config.baseForegroundColor = theme == style.theme ? .label : .secondaryLabel
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = UIFont.scaled(.caption1, size: 12, weight: .semibold)
                return attributes
            }
            button.configuration = config
            button.isSelected = theme == style.theme
        }
        configureToggle(coverToggle, title: LyricShareCopy.showCover, symbol: "photo", on: style.showArtwork)
        configureToggle(visualizerToggle, title: LyricShareCopy.showVisualizer, symbol: "waveform", on: style.showVisualizer)
        configureToggle(markToggle, title: LyricShareCopy.showMark, symbol: "signature", on: style.showMark)
        let format = style.format
        previewAspect?.isActive = false
        previewAspect = previewImage.widthAnchor.constraint(
            equalTo: previewImage.heightAnchor, multiplier: CGFloat(format.pixelWidth) / CGFloat(format.pixelHeight))
        previewAspect?.priority = .defaultHigh
        previewAspect?.isActive = true
    }

    private func configureToggle(_ button: UIButton, title: String, symbol: String, on: Bool) {
        var config = on ? UIButton.Configuration.tinted() : UIButton.Configuration.gray()
        config.image = UIImage(systemName: on ? "checkmark" : symbol)
        config.title = title
        config.imagePadding = 4
        config.cornerStyle = .capsule
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.scaled(.footnote, size: 13, weight: .semibold)
            return attributes
        }
        button.configuration = config
        button.accessibilityTraits = on ? [.button, .selected] : .button
    }

    /// A round chip of a theme's background with a dot of its ink.
    private static func swatch(_ palette: LyricSharePalette, selected: Bool) -> UIImage {
        let side: CGFloat = 40
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let rect = CGRect(x: 2, y: 2, width: side - 4, height: side - 4)
            let colors = [Self.uiColor(palette.background).cgColor, Self.uiColor(palette.backgroundDeep).cgColor] as CFArray
            context.cgContext.addEllipse(in: rect)
            context.cgContext.clip()
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: side), options: [])
            }
            Self.uiColor(palette.ink).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: side / 2 - 5, y: side / 2 - 5, width: 10, height: 10))
            context.cgContext.resetClip()
            let ring = selected ? UIColor.tintColor : UIColor.separator
            ring.setStroke()
            let outline = UIBezierPath(ovalIn: rect.insetBy(dx: selected ? 0 : 0.5, dy: selected ? 0 : 0.5))
            outline.lineWidth = selected ? 3 : 1
            outline.stroke()
        }.withRenderingMode(.alwaysOriginal)
    }

    private static func uiColor(_ color: LyricShareColor) -> UIColor {
        UIColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
    }

    private func refreshLines() {
        let current = session.selection
        for (index, button) in lineButtons {
            let chosen = current.contains(index) && session.isPickable(index)
            var config = button.configuration ?? .plain()
            config.background.backgroundColor = chosen ? UIColor.tintColor.withAlphaComponent(0.18) : .clear
            config.baseForegroundColor = chosen ? .label : (session.isPickable(index) ? .secondaryLabel : .tertiaryLabel)
            config.image = chosen ? UIImage(systemName: "checkmark.circle.fill") : nil
            config.imagePlacement = .trailing
            button.configuration = config
            button.accessibilityTraits = chosen ? [.button, .selected] : .button
        }
        linesHint.text = LyricShareCopy.linesHint(duration: session.window.duration, timed: session.isTimed)
        startLabel.text = LyricShareCopy.startsAt(session.plainStart)
    }

    private func previewPixels() -> CGFloat {
        let format = session.style.format
        let height = max(previewFrame.bounds.height, 1)
        let width = min(previewFrame.bounds.width, height * CGFloat(format.pixelWidth) / CGFloat(format.pixelHeight))
        return min(width * (view.window?.screen.scale ?? 3), Self.previewPixelWidth)
    }

    private func rebuildRenderer() {
        let pixels = previewPixels()
        guard pixels > 1 else { return }
        let width = CGFloat(session.style.format.pixelWidth)
        renderer = LyricShareRenderer(scene: session.scene(), scale: pixels / width)
        drawPreview()
    }

    /// The frame the preview shows: where the preview player is, or, while it
    /// is paused, the first line just before it ends, fully sung.
    private func previewFrameIndex() -> Int {
        let frames = LyricShareClip.frameCount(session.window)
        if preview.isPlaying {
            return min(Int(preview.currentTime * Double(LyricShareClip.fps)), frames - 1)
        }
        guard session.isTimed else { return min(LyricShareClip.fps, frames - 1) }
        let first = session.lyrics.document.lines[session.selection.first]
        let sung = max(first.end - 0.1, first.start + LyricShareMotion.entranceDuration)
        let settled = sung - session.window.lyricStart
        return min(max(Int(settled * Double(LyricShareClip.fps)), 0), frames - 1)
    }

    private func drawPreview() {
        guard let renderer, let image = renderer.image(frame: previewFrameIndex()) else { return }
        previewImage.image = UIImage(cgImage: image)
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
        link.isPaused = !preview.isPlaying
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func step() {
        drawPreview()
    }

    @objc private func togglePreview() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if preview.isPlaying {
            preview.pause()
        } else {
            preview.play()
        }
        updatePlayButton()
        drawPreview()
    }

    private func updatePlayButton() {
        let playing = preview.isPlaying
        playButton.configuration?.image = UIImage(systemName: playing ? "pause.fill" : "play.fill")
        playButton.accessibilityLabel = playing ? LyricShareCopy.pausePreview : LyricShareCopy.playPreview
        displayLink?.isPaused = !playing
    }

    private func setExporting(_ exporting: Bool) {
        exportBar.isHidden = exporting
        progressBar.isHidden = !exporting
        progressView.progress = 0
        stack.isUserInteractionEnabled = !exporting
        stack.alpha = exporting ? 0.5 : 1
        isModalInPresentation = exporting
    }

    private func export(video: Bool) {
        guard cancelFlag == nil else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        preview.pause()
        updatePlayButton()
        let flag = LyricShareCancelFlag()
        cancelFlag = flag
        setExporting(video)
        Task { [weak self] in
            guard let self else { return }
            let result = await self.session.export(video: video, cancel: flag) { [weak self] value in
                self?.progressView.setProgress(Float(value), animated: false)
            }
            self.cancelFlag = nil
            self.setExporting(false)
            switch result {
            case .success(let url):
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                self.presentShare(url, from: video ? self.shareVideoButton : self.shareImageButton)
            case .failure(.cancelled):
                break
            case .failure(let failure):
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                ToastView.show(LyricShareCopy.exportFailure(failure), in: self.view, style: .error)
            }
        }
    }

    private func presentShare(_ url: URL, from source: UIView) {
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = source
        present(activity, animated: true)
    }
}
