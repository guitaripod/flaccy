import AppKit
import Combine
import FlaccyCore

/// The one glass panel the Mac floats over the library, in three shapes.
///
/// It starts as the first-launch welcome. When a library is being built for the
/// first time it grows in place into the Debut — same panel, same glass, wider
/// and taller — and closes on the summary card. It never becomes a window
/// takeover: the sidebar, the toolbar and the transport stay exactly where they
/// were, and the grid the reader is about to land in stays visible behind it.
final class OnboardingPanelView: NSView {

    private enum Metrics {
        static let welcomeWidth: CGFloat = 476
        static let debutWidth: CGFloat = 640
        static let debutHeight: CGFloat = 420
        static let resize: TimeInterval = 0.45
        static let crossfade: TimeInterval = 0.35
    }

    private enum Presentation {
        case welcome
        case debut
        case summary
    }

    var onFinishDebut: ((LibraryDebutSummary) -> Void)?

    var isPresentingDebut: Bool { presentation != .welcome }

    private let progressLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let sampleButton = GlassCapsuleButton(title: String(localized: "Download Sample Album"), symbolName: "arrow.down.circle")
    private var isDownloading = false

    private let scrim = NSView()
    private let host = NSView()
    private lazy var welcomeContent: NSStackView = Self.makeWelcomeContent(
        spinner: spinner, progressLabel: progressLabel, sampleButton: sampleButton
    )
    private let debutView = MacLibraryDebutView()
    private var summaryCard: MacDebutSummaryCard?
    private var hostWidth: NSLayoutConstraint!
    private var hostHeight: NSLayoutConstraint!
    private var presentation: Presentation = .welcome
    private var summary: LibraryDebutSummary?
    private var isBuildingSummary = false

    enum Visibility {
        case show
        case hide
        case keep
    }

    /// Loading is intentionally a "keep" state: the library posts its update
    /// notification while a reload is still marked in-flight, so hiding on
    /// isLoading would dismiss the panel the moment the empty first scan runs.
    static var visibility: Visibility {
        if MacLibrarySurfaceModel.shared.state.value.surface == .debut { return .show }
        if !LibraryRoot.shared.isUsingDefaultRoot || LibraryRoot.shared.isFallbackActive
            || !Library.shared.allTracks.isEmpty {
            return .hide
        }
        if Library.shared.isLoading { return .keep }
        return databaseHasTracks ? .hide : .show
    }

    /// The in-memory library is empty until the first reload completes, so a
    /// returning user's launch checks the database directly instead of
    /// flashing the welcome panel over an existing library.
    private static var databaseHasTracks: Bool {
        !((try? DatabaseManager.shared.fetchAllTrackRelativePaths().isEmpty) ?? true)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        sampleButton.onClick = { [weak self] in self?.downloadSample() }

        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.78).cgColor
        scrim.alphaValue = 0
        scrim.isHidden = true
        scrim.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrim)

        host.translatesAutoresizingMaskIntoConstraints = false
        welcomeContent.translatesAutoresizingMaskIntoConstraints = false
        debutView.translatesAutoresizingMaskIntoConstraints = false
        debutView.alphaValue = 0
        debutView.onTurnOnAI = { PurchaseManager.shared.requestPaywall() }
        host.addSubview(welcomeContent)
        host.addSubview(debutView)

        hostWidth = host.widthAnchor.constraint(equalToConstant: Metrics.welcomeWidth)
        hostHeight = host.heightAnchor.constraint(
            equalToConstant: welcomeContent.fittingSize.height
        )

        let panel = MacLiquidGlass.surface(hosting: host, cornerRadius: 26)
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        NSLayoutConstraint.activate([
            scrim.topAnchor.constraint(equalTo: topAnchor),
            scrim.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrim.bottomAnchor.constraint(equalTo: bottomAnchor),
            hostWidth, hostHeight,
            welcomeContent.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            welcomeContent.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            debutView.topAnchor.constraint(equalTo: host.topAnchor),
            debutView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            debutView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            debutView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
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

    func render(_ state: MacLibrarySurfaceModel.State) {
        guard state.surface == .debut else {
            present(.welcome)
            return
        }
        debutView.render(state)
        switch state.act {
        case .indexing, .finishing:
            present(.debut)
        case .summary:
            presentSummaryWhenReady()
        case .done:
            present(.welcome)
        }
    }

    /// Act III needs figures the database has to be asked for, so the card is
    /// built once, off the main thread, and the second act keeps running on
    /// screen until it is ready rather than showing an empty card.
    private func presentSummaryWhenReady() {
        if let summary {
            present(.summary, summary: summary)
            return
        }
        guard !isBuildingSummary else { return }
        isBuildingSummary = true
        debutView.settle()
        Task { [weak self] in
            let built = await MacDebutSummaryBuilder.build()
            guard let self else { return }
            self.summary = built
            self.isBuildingSummary = false
            self.present(.summary, summary: built)
        }
    }

    private func present(_ next: Presentation, summary: LibraryDebutSummary? = nil) {
        guard next != presentation else { return }
        presentation = next

        let card = next == .summary ? makeSummaryCard(summary) : summaryCard
        let incoming: NSView
        switch next {
        case .welcome: incoming = welcomeContent
        case .debut: incoming = debutView
        case .summary: incoming = card ?? debutView
        }

        let width = next == .welcome ? Metrics.welcomeWidth : Metrics.debutWidth
        let height = targetHeight(for: next, card: card)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        scrim.isHidden = next == .welcome && scrim.alphaValue == 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : Metrics.resize
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            hostWidth.animator().constant = width
            hostHeight.animator().constant = height
            scrim.animator().alphaValue = next == .welcome ? 0 : 1
            layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            self?.scrim.isHidden = self?.scrim.alphaValue == 0
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : Metrics.crossfade
            for view in [welcomeContent, debutView, card].compactMap({ $0 }) {
                view.animator().alphaValue = view === incoming ? 1 : 0
            }
        }
    }

    private func targetHeight(for presentation: Presentation, card: MacDebutSummaryCard?) -> CGFloat {
        switch presentation {
        case .welcome: return welcomeContent.fittingSize.height
        case .debut: return Metrics.debutHeight
        case .summary: return max(Metrics.debutHeight, card?.fittingSize.height ?? Metrics.debutHeight)
        }
    }

    private func makeSummaryCard(_ summary: LibraryDebutSummary?) -> MacDebutSummaryCard? {
        if let summaryCard { return summaryCard }
        guard let summary else { return nil }
        let card = MacDebutSummaryCard(
            summary: summary, aiSkippedForEntitlement: PurchaseManager.shared.state == .expired
        )
        card.translatesAutoresizingMaskIntoConstraints = false
        card.alphaValue = 0
        card.onDismiss = { [weak self] in self?.onFinishDebut?(summary) }
        card.onSeeWhatsIncluded = { PurchaseManager.shared.requestPaywall() }
        host.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: host.topAnchor),
            card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            card.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor),
        ])
        summaryCard = card
        return card
    }

    private static func makeWelcomeContent(
        spinner: NSProgressIndicator, progressLabel: NSTextField, sampleButton: GlassCapsuleButton
    ) -> NSStackView {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true

        let title = NSTextField(labelWithString: String(localized: "Welcome to Flaccy"))
        title.font = .systemFont(ofSize: 26, weight: .bold)

        let subtitle = NSTextField(wrappingLabelWithString:
            String(localized: "Point Flaccy at your music folder and it indexes everything in place — FLAC, ALAC, MP3 and more, nothing copied or moved.")
        )
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = MacColors.secondaryLabel
        subtitle.alignment = .center
        subtitle.preferredMaxLayoutWidth = 380

        let chooseButton = GlassCapsuleButton(
            title: String(localized: "Choose Music Folder…"), symbolName: "folder", prominent: true
        )
        chooseButton.onClick = {
            NSApp.sendAction(#selector(MacAppDelegate.chooseMusicFolder(_:)), to: nil, from: nil)
        }

        let buttons = NSStackView(views: [chooseButton, sampleButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        progressLabel.font = .systemFont(ofSize: 12)
        progressLabel.textColor = MacColors.secondaryLabel

        let progressRow = NSStackView(views: [spinner, progressLabel])
        progressRow.orientation = .horizontal
        progressRow.spacing = 6

        let hintIcon = NSImageView(image: NSImage(
            systemSymbolName: "square.and.arrow.down.on.square", accessibilityDescription: nil
        ) ?? NSImage())
        hintIcon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        hintIcon.contentTintColor = MacColors.tertiaryLabel
        let hintLabel = NSTextField(labelWithString: String(localized: "Or drop audio files and folders anywhere in this window."))
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = MacColors.tertiaryLabel
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
        return content
    }

    private func downloadSample() {
        guard !isDownloading else { return }
        isDownloading = true
        spinner.startAnimation(nil)
        progressLabel.stringValue = String(localized: "Contacting server…")
        AppLogger.info("Onboarding: sample album download started", category: .content)
        Task { [weak self] in
            let success = await SampleMusicService.shared.downloadSamples()
            guard let self else { return }
            self.isDownloading = false
            self.spinner.stopAnimation(nil)
            self.progressLabel.stringValue = ""
            if !success {
                MacToast.show(String(localized: "Couldn't download the sample album."), style: .error, in: self.window)
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
