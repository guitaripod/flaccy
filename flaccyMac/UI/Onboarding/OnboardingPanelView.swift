import AppKit

/// First-launch welcome panel floated over the library: shown only while the
/// default container root is active, no folder bookmark exists and the
/// library has no tracks; hides itself the moment music appears.
final class OnboardingPanelView: NSView {

    private let progressLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let sampleButton = GlassCapsuleButton(title: "Download Sample Album", symbolName: "arrow.down.circle")
    private var isDownloading = false

    enum Visibility {
        case show
        case hide
        case keep
    }

    /// Loading is intentionally a "keep" state: the library posts its update
    /// notification while a reload is still marked in-flight, so hiding on
    /// isLoading would dismiss the panel the moment the empty first scan runs.
    static var visibility: Visibility {
        if !LibraryRoot.shared.isUsingDefaultRoot || !Library.shared.allTracks.isEmpty {
            return .hide
        }
        return Library.shared.isLoading ? .keep : .show
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true

        let title = NSTextField(labelWithString: "Welcome to Flaccy")
        title.font = .systemFont(ofSize: 26, weight: .bold)

        let subtitle = NSTextField(wrappingLabelWithString:
            "Point Flaccy at your music folder and it indexes everything in place — FLAC, ALAC, MP3 and more, nothing copied or moved."
        )
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.preferredMaxLayoutWidth = 380

        let chooseButton = GlassCapsuleButton(
            title: "Choose Music Folder…", symbolName: "folder", prominent: true
        )
        chooseButton.onClick = {
            NSApp.sendAction(#selector(MacAppDelegate.chooseMusicFolder(_:)), to: nil, from: nil)
        }

        sampleButton.onClick = { [weak self] in self?.downloadSample() }

        let buttons = NSStackView(views: [chooseButton, sampleButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        progressLabel.font = .systemFont(ofSize: 12)
        progressLabel.textColor = .secondaryLabelColor

        let progressRow = NSStackView(views: [spinner, progressLabel])
        progressRow.orientation = .horizontal
        progressRow.spacing = 6

        let hintIcon = NSImageView(image: NSImage(
            systemSymbolName: "square.and.arrow.down.on.square", accessibilityDescription: nil
        ) ?? NSImage())
        hintIcon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        hintIcon.contentTintColor = .tertiaryLabelColor
        let hintLabel = NSTextField(labelWithString: "Or drop audio files and folders anywhere in this window.")
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .tertiaryLabelColor
        let hint = NSStackView(views: [hintIcon, hintLabel])
        hint.orientation = .horizontal
        hint.spacing = 6

        let content = NSStackView(views: [icon, title, subtitle, buttons, progressRow, hint])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 14
        content.setCustomSpacing(6, after: title)
        content.setCustomSpacing(22, after: subtitle)
        content.setCustomSpacing(10, after: buttons)
        content.edgeInsets = NSEdgeInsets(top: 40, left: 48, bottom: 36, right: 48)

        let panel = MacLiquidGlass.surface(hosting: content, cornerRadius: 26)
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(progressChanged),
            name: SampleMusicService.progressDidChange, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func downloadSample() {
        guard !isDownloading else { return }
        isDownloading = true
        spinner.startAnimation(nil)
        progressLabel.stringValue = "Contacting server…"
        AppLogger.info("Onboarding: sample album download started", category: .content)
        Task { [weak self] in
            let success = await SampleMusicService.shared.downloadSamples()
            guard let self else { return }
            self.isDownloading = false
            self.spinner.stopAnimation(nil)
            self.progressLabel.stringValue = ""
            if !success {
                MacToast.show("Couldn't download the sample album.", style: .error, in: self.window)
            }
        }
    }

    @objc private func progressChanged() {
        let text = SampleMusicService.shared.progressText
        if !text.isEmpty {
            progressLabel.stringValue = text
        }
    }
}
