import AppKit
import FlaccyCore

/// The desktop's one ambient status surface, floated above everything the
/// window can put on screen — including the full-window Now Playing overlay,
/// which is where a music app's readers actually sit. That standing is not
/// free: `RootContainerViewController` re-raises this view whenever anything
/// joins the stack, because the overlay is added to the same superview and
/// would otherwise land in front of it.
///
/// It carries two kinds of content and draws them differently on purpose. Load
/// content is bounded disk work, so it keeps a determinate bar that reaches a
/// real 100%. Job content is unbounded network work, so it has no bar at all:
/// a 28 pt cover of whatever is being looked up, the stage, and a countdown.
final class MacStatusStripView: NSView {

    enum Content: Equatable {
        case load(LibraryLoadProgress, Double)
        case job(EnrichmentJobProgress)
    }

    private static let coverSide: CGFloat = 28

    private let headline = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let spinner = NSProgressIndicator()
    private let cover = ArtworkTileView()
    private let leading = NSView()
    private let background = NSVisualEffectView()

    private var coverKey: String?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        alphaValue = 0
        isHidden = true

        background.translatesAutoresizingMaskIntoConstraints = false
        background.material = .hudWindow
        background.blendingMode = .withinWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.cornerCurve = .continuous
        addSubview(background)

        headline.font = .systemFont(ofSize: 12, weight: .semibold)
        headline.textColor = MacColors.primaryLabel
        headline.lineBreakMode = .byTruncatingTail
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = MacColors.secondaryLabel
        detail.alignment = .right

        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
        bar.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        cover.cornerRadius = 6
        cover.translatesAutoresizingMaskIntoConstraints = false

        leading.translatesAutoresizingMaskIntoConstraints = false
        leading.addSubview(cover)
        leading.addSubview(spinner)
        leading.isHidden = true

        let row = NSStackView(views: [headline, detail])
        row.orientation = .horizontal
        row.distribution = .fill
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        headline.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)

        let lines = NSStackView(views: [row, bar])
        lines.orientation = .vertical
        lines.spacing = 6
        lines.alignment = .leading
        lines.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [leading, lines])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            leading.widthAnchor.constraint(equalToConstant: Self.coverSide),
            leading.heightAnchor.constraint(equalToConstant: Self.coverSide),
            cover.topAnchor.constraint(equalTo: leading.topAnchor),
            cover.leadingAnchor.constraint(equalTo: leading.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: leading.trailingAnchor),
            cover.bottomAnchor.constraint(equalTo: leading.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: leading.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: leading.centerYAnchor),
            row.widthAnchor.constraint(equalTo: lines.widthAnchor),
            bar.widthAnchor.constraint(equalTo: lines.widthAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(String(localized: "Updating your library"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ content: Content) {
        switch content {
        case .load(let progress, let fraction):
            applyLoad(progress, fraction: fraction)
        case .job(let progress):
            applyJob(progress)
        }
    }

    private func applyLoad(_ progress: LibraryLoadProgress, fraction: Double) {
        leading.isHidden = true
        spinner.stopAnimation(nil)
        coverKey = nil
        bar.isHidden = false
        headline.stringValue = LibraryLoadPhaseCopy.headline(for: progress.phase)
        detail.stringValue = LibraryLoadPhaseCopy.detail(for: progress)
        bar.isIndeterminate = !progress.isDeterminate
        if progress.isDeterminate {
            bar.stopAnimation(nil)
            bar.doubleValue = min(1, max(0, fraction))
        } else {
            bar.startAnimation(nil)
        }
        setAccessibilityValueDescription(
            LibraryLoadPhaseCopy.accessibilityValue(for: progress, fraction: fraction)
        )
    }

    /// No bar, ever: `EnrichmentJobProgress` carries no fraction, and inventing
    /// one here would turn a count of rows the database still matches into a
    /// promise about how long they take.
    private func applyJob(_ progress: EnrichmentJobProgress) {
        bar.stopAnimation(nil)
        bar.isHidden = true
        leading.isHidden = false

        switch progress.activity {
        case .running:
            headline.stringValue = EnrichmentJobCopy.headline(for: progress.scope)
            detail.stringValue = EnrichmentJobCopy.detail(remaining: progress.remaining)
        case .waitingForNetwork:
            headline.stringValue = EnrichmentJobCopy.waitingForNetwork
            detail.stringValue = ""
        case .needsEntitlement:
            headline.stringValue = EnrichmentJobCopy.needsEntitlement
            detail.stringValue = ""
        case .idle:
            headline.stringValue = ""
            detail.stringValue = ""
        }

        showCover(forTitle: progress.activity == .running ? progress.currentTitle : nil)
        setAccessibilityValueDescription(EnrichmentJobCopy.accessibilityValue(for: progress))
    }

    /// The leading slot is either the cover of the album being looked up or, when
    /// the job has not named one, the spinner — so there is always exactly one
    /// thing in it and it is always the most specific thing available.
    private func showCover(forTitle title: String?) {
        guard let title, let album = Self.album(named: title) else {
            coverKey = nil
            cover.isHidden = true
            spinner.startAnimation(nil)
            return
        }
        cover.isHidden = false
        spinner.stopAnimation(nil)
        let key = "\(album.title)|\(album.artist)"
        guard key != coverKey else { return }
        coverKey = key
        if let cached = AlbumArtworkCache.shared.thumbnail(forAlbum: album.title, artist: album.artist) {
            cover.showImage(cached)
            return
        }
        cover.showPlaceholder(seed: key, shimmering: true)
        AlbumArtworkCache.shared.loadThumbnail(forAlbum: album.title, artist: album.artist) { [weak self] image in
            guard let self, self.coverKey == key else { return }
            guard let image else {
                self.cover.stopShimmer()
                return
            }
            self.cover.showImage(image)
        }
    }

    private static func album(named title: String) -> Album? {
        Library.shared.albums.first { $0.title == title }
    }

    func setVisible(_ visible: Bool) {
        guard visible != (alphaValue > 0) || isHidden == visible else { return }
        if visible { isHidden = false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.isHidden = self.alphaValue == 0
            if self.isHidden {
                self.bar.stopAnimation(nil)
                self.spinner.stopAnimation(nil)
            }
        }
    }
}
