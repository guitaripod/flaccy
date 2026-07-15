import AppKit
import UniformTypeIdentifiers

/// Year in Music configurator: a slide list, year picker, theme swatches, and
/// format toggle on the left; the rendered story card on the right; export,
/// copy, and share actions. Slides render through the CoreGraphics
/// StoryCardRenderer and are cached per year/theme/format/slide.
final class YearInMusicViewController: NSViewController {

    private let backdrop = AmbientBackdropView()

    private let yearPopUp = NSPopUpButton()
    private let slideList = NSStackView()
    private let swatchRow = NSStackView()
    private let formatControl = NSSegmentedControl(
        labels: ["Story 9:16", "Post 4:5"], trackingMode: .selectOne, target: nil, action: nil
    )
    private let previewImageView = NSImageView()
    private let renderSpinner = NSProgressIndicator()
    private let slideTitleLabel = NSTextField(labelWithString: "")
    private let emptyState = NSStackView()
    private let sidebar = NSStackView()
    private let exportButton = NSButton(title: "Export PNG…", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let shareButton = NSButton(title: "Share", target: nil, action: nil)

    private var years: [Int] = []
    private var selectedYear = Calendar.current.component(.year, from: Date())
    private var selectedSlide: StorySlide = .overview
    private var selectedThemeIndex = 0
    private var themes: [StoryTheme] = []
    private var data: YearInMusicData?
    private var artwork: StoryArtwork = .empty
    private var renderCache: [String: NSImage] = [:]
    private var slideButtons: [NSButton] = []
    private var recomputeToken = 0

    private var selectedFormat: StoryFormat {
        formatControl.selectedSegment == 1 ? .post : .story
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(backdrop)

        buildSidebar()
        buildPreview()
        buildEmptyState()

        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)
        root.addSubview(previewImageView)
        root.addSubview(renderSpinner)
        root.addSubview(slideTitleLabel)
        root.addSubview(emptyState)
        renderSpinner.translatesAutoresizingMaskIntoConstraints = false
        slideTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            sidebar.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            sidebar.widthAnchor.constraint(equalToConstant: 240),
            sidebar.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -28),

            previewImageView.topAnchor.constraint(equalTo: root.topAnchor, constant: 48),
            previewImageView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -60),
            previewImageView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 32),
            previewImageView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),

            renderSpinner.centerXAnchor.constraint(equalTo: previewImageView.centerXAnchor),
            renderSpinner.centerYAnchor.constraint(equalTo: previewImageView.centerYAnchor),

            slideTitleLabel.centerXAnchor.constraint(equalTo: previewImageView.centerXAnchor),
            slideTitleLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),

            emptyState.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        backdrop.apply(ArtworkPaletteExtractor.fallbackPalette(seed: "year-in-music"), animated: false)
        reloadYears()
    }

    deinit {
        AppLogger.info("YearInMusicViewController deinit", category: .ui)
    }

    private func buildSidebar() {
        let title = NSTextField(labelWithString: "Year in Music")
        title.font = .systemFont(ofSize: 22, weight: .heavy)
        title.textColor = MacColors.primaryLabel

        yearPopUp.target = self
        yearPopUp.action = #selector(yearChanged)

        slideList.orientation = .vertical
        slideList.alignment = .leading
        slideList.spacing = 2
        for slide in StorySlide.allCases {
            let button = NSButton(title: slide.displayName, target: self, action: #selector(slideChanged(_:)))
            button.bezelStyle = .accessoryBarAction
            button.tag = slide.rawValue
            button.setButtonType(.pushOnPushOff)
            slideList.addArrangedSubview(button)
            slideButtons.append(button)
        }

        swatchRow.orientation = .horizontal
        swatchRow.spacing = 8

        formatControl.selectedSegment = 0
        formatControl.target = self
        formatControl.action = #selector(formatChanged)

        exportButton.bezelStyle = .rounded
        exportButton.target = self
        exportButton.action = #selector(exportTapped)
        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        shareButton.bezelStyle = .rounded
        shareButton.target = self
        shareButton.action = #selector(shareTapped)

        let actions = NSStackView(views: [exportButton, copyButton, shareButton])
        actions.orientation = .vertical
        actions.alignment = .leading
        actions.spacing = 6

        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 16
        sidebar.addArrangedSubview(title)
        sidebar.addArrangedSubview(labeled("YEAR", yearPopUp))
        sidebar.addArrangedSubview(labeled("SLIDES", slideList))
        sidebar.addArrangedSubview(labeled("THEME", swatchRow))
        sidebar.addArrangedSubview(labeled("FORMAT", formatControl))
        sidebar.addArrangedSubview(actions)
    }

    private func labeled(_ caption: String, _ content: NSView) -> NSView {
        let label = NSTextField(labelWithString: caption)
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = MacColors.tertiaryLabel
        let stack = NSStackView(views: [label, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        return stack
    }

    private func buildPreview() {
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.wantsLayer = true
        previewImageView.layer?.shadowColor = NSColor.black.withAlphaComponent(0.55).cgColor
        previewImageView.layer?.shadowRadius = 24
        previewImageView.layer?.shadowOffset = CGSize(width: 0, height: -8)
        previewImageView.layer?.shadowOpacity = 1

        slideTitleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        slideTitleLabel.textColor = MacColors.secondaryLabel

        renderSpinner.style = .spinning
        renderSpinner.controlSize = .regular
        renderSpinner.isDisplayedWhenStopped = false
    }

    private func buildEmptyState() {
        let icon = NSImageView(image: NSImage(
            systemSymbolName: "calendar.badge.clock", accessibilityDescription: nil
        ) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 40, weight: .light)
        icon.contentTintColor = MacColors.tertiaryLabel
        let title = NSTextField(labelWithString: "No listening history for this year")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = MacColors.primaryLabel
        let subtitle = NSTextField(labelWithString: "Play some music or import your Last.fm history in Settings.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = MacColors.secondaryLabel
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 8
        emptyState.addArrangedSubview(icon)
        emptyState.addArrangedSubview(title)
        emptyState.addArrangedSubview(subtitle)
        emptyState.isHidden = true
    }

    private func reloadYears() {
        let currentYear = Calendar.current.component(.year, from: Date())
        var available = YearInMusicService.shared.availableYears()
        if !available.contains(currentYear) {
            available.insert(currentYear, at: 0)
        }
        years = available.sorted(by: >)
        yearPopUp.removeAllItems()
        yearPopUp.addItems(withTitles: years.map(String.init))
        if let index = years.firstIndex(of: selectedYear) {
            yearPopUp.selectItem(at: index)
        } else {
            selectedYear = years.first ?? currentYear
            yearPopUp.selectItem(at: 0)
        }
        recomputeData()
    }

    private func recomputeData() {
        let year = selectedYear
        let durations = YearInMusicService.shared.libraryDurations()
        let slide = selectedSlide
        let format = selectedFormat
        let themeIndex = selectedThemeIndex
        recomputeToken &+= 1
        let token = recomputeToken
        beginRendering()

        Task.detached {
            let computed = YearInMusicService.shared.compute(year: year, libraryDurations: durations)
            let artwork = computed.hasContent ? StoryArtwork.resolve(for: computed) : .empty
            let seed = computed.topArtists.first.map { "\($0.name)\(year)" } ?? "flaccy\(year)"
            let themes = StoryTheme.all(seedPalette: ArtworkPaletteExtractor.fallbackPalette(seed: seed))
            let resolvedIndex = min(themeIndex, themes.count - 1)

            let firstRender: (image: NSImage, key: String)? = {
                guard computed.hasContent, themes.indices.contains(resolvedIndex) else { return nil }
                let theme = themes[resolvedIndex]
                guard let image = StoryCardRenderer.makeImage(
                    slide: slide, data: computed, artwork: artwork, theme: theme, format: format
                ) else { return nil }
                return (image, Self.cacheKey(year: computed.year, slide: slide, theme: theme, format: format))
            }()

            await MainActor.run { [weak self] in
                guard let self, token == self.recomputeToken else { return }
                self.data = computed
                self.artwork = artwork
                self.themes = themes
                self.selectedThemeIndex = resolvedIndex
                self.renderCache = [:]
                if let firstRender {
                    self.renderCache[firstRender.key] = firstRender.image
                }
                self.rebuildSwatches()
                self.refreshSelectionUI()
                self.renderPreview()
                self.endRendering()
            }
        }
    }

    private func beginRendering() {
        previewImageView.image = nil
        emptyState.isHidden = true
        [exportButton, copyButton, shareButton].forEach { $0.isEnabled = false }
        renderSpinner.startAnimation(nil)
    }

    private func endRendering() {
        renderSpinner.stopAnimation(nil)
    }

    nonisolated private static func cacheKey(year: Int, slide: StorySlide, theme: StoryTheme, format: StoryFormat) -> String {
        "\(year)|\(slide.rawValue)|\(theme.name)|\(format == .story ? "s" : "p")"
    }

    private func rebuildSwatches() {
        swatchRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, theme) in themes.enumerated() {
            let swatch = ThemeSwatchButton(theme: theme, selected: index == selectedThemeIndex)
            swatch.tag = index
            swatch.target = self
            swatch.action = #selector(themeChanged(_:))
            swatch.toolTip = theme.name
            swatchRow.addArrangedSubview(swatch)
        }
    }

    private func refreshSelectionUI() {
        for button in slideButtons {
            button.state = button.tag == selectedSlide.rawValue ? .on : .off
        }
        let themeName = themes.indices.contains(selectedThemeIndex) ? themes[selectedThemeIndex].name : ""
        slideTitleLabel.stringValue = "\(selectedSlide.displayName) · \(themeName)"
    }

    private func renderPreview() {
        guard let data, data.hasContent, themes.indices.contains(selectedThemeIndex) else {
            previewImageView.image = nil
            emptyState.isHidden = false
            [exportButton, copyButton, shareButton].forEach { $0.isEnabled = false }
            return
        }
        emptyState.isHidden = true
        [exportButton, copyButton, shareButton].forEach { $0.isEnabled = true }
        previewImageView.image = renderedImage(slide: selectedSlide, format: selectedFormat)
    }

    private func renderedImage(slide: StorySlide, format: StoryFormat) -> NSImage? {
        guard let data, themes.indices.contains(selectedThemeIndex) else { return nil }
        let theme = themes[selectedThemeIndex]
        let key = Self.cacheKey(year: data.year, slide: slide, theme: theme, format: format)
        if let cached = renderCache[key] { return cached }
        let image = StoryCardRenderer.makeImage(
            slide: slide, data: data, artwork: artwork, theme: theme, format: format
        )
        if let image { renderCache[key] = image }
        return image
    }

    @objc private func yearChanged() {
        let index = yearPopUp.indexOfSelectedItem
        guard index >= 0, index < years.count else { return }
        selectedYear = years[index]
        recomputeData()
    }

    @objc private func slideChanged(_ sender: NSButton) {
        guard let slide = StorySlide(rawValue: sender.tag) else { return }
        selectedSlide = slide
        refreshSelectionUI()
        renderPreview()
    }

    @objc private func themeChanged(_ sender: NSButton) {
        selectedThemeIndex = sender.tag
        rebuildSwatches()
        refreshSelectionUI()
        renderPreview()
    }

    @objc private func formatChanged() {
        renderPreview()
    }

    @objc private func exportTapped() {
        guard let window = view.window,
              let image = renderedImage(slide: selectedSlide, format: selectedFormat) else { return }
        let suffix = selectedFormat == .story ? "Story" : "Post"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Flaccy \(selectedYear) \(selectedSlide.displayName) \(suffix).png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            guard let data = image.pngData() else { return }
            do {
                try data.write(to: url)
                AppLogger.info("Year in Music export saved to \(url.path)", category: .ui)
                MacToast.show("Exported \(url.lastPathComponent)", style: .success, in: self?.view.window)
            } catch {
                AppLogger.error("Year in Music export failed: \(error.localizedDescription)", category: .ui)
                MacToast.show("Export failed", style: .error, in: self?.view.window)
            }
        }
    }

    @objc private func copyTapped() {
        guard let image = renderedImage(slide: selectedSlide, format: selectedFormat) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        MacToast.show("Slide copied", style: .success, in: view.window)
    }

    @objc private func shareTapped() {
        guard let image = renderedImage(slide: selectedSlide, format: selectedFormat) else { return }
        let picker = NSSharingServicePicker(items: [image])
        picker.show(relativeTo: shareButton.bounds, of: shareButton, preferredEdge: .minY)
    }
}

/// Circular gradient swatch used to pick a story theme.
final class ThemeSwatchButton: NSButton {

    private let theme: StoryTheme
    private let isSelectedSwatch: Bool
    private let gradient = CAGradientLayer()

    init(theme: StoryTheme, selected: Bool) {
        self.theme = theme
        self.isSelectedSwatch = selected
        super.init(frame: .zero)
        title = ""
        isBordered = false
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true

        gradient.frame = CGRect(x: 0, y: 0, width: 26, height: 26)
        gradient.cornerRadius = 13
        gradient.colors = theme.gradientColors.map { ($0.usingColorSpace(.deviceRGB) ?? $0).cgColor }
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        gradient.borderWidth = selected ? 2 : 0.5
        effectiveAppearance.performAsCurrentDrawingAppearance { applyBorderColor() }
        layer?.addSublayer(gradient)
        setAccessibilityLabel("Theme \(theme.name)\(selected ? ", selected" : "")")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyBorderColor() }
    }

    private func applyBorderColor() {
        gradient.borderColor = isSelectedSwatch
            ? MacColors.primaryLabel.cgColor
            : MacColors.fill(0.3).cgColor
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
