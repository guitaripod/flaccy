import AppKit
import FlaccyCore

/// A song page's hero: a cover beside its text in a regular window, stacked
/// above it in a compact one and in the rail of a wide one. The cover is
/// always a square whose side the mode picks.
final class TrackHeroView: NSView {

    static let railWidth: CGFloat = 380

    private let cover: NSView
    private let text: NSView
    private let coverWidth: NSLayoutConstraint
    private var modeConstraints: [NSLayoutConstraint] = []
    private(set) var mode: TrackPageLayout.Mode?

    init(cover: NSView, text: NSView) {
        self.cover = cover
        self.text = text
        coverWidth = cover.widthAnchor.constraint(equalToConstant: 232)
        super.init(frame: .zero)
        for view in [cover, text] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        cover.heightAnchor.constraint(equalTo: cover.widthAnchor).isActive = true
        coverWidth.isActive = true
        apply(.regular)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func coverSide(for mode: TrackPageLayout.Mode) -> CGFloat {
        switch mode {
        case .wide: 288
        case .regular: 232
        case .compact: 148
        }
    }

    func apply(_ mode: TrackPageLayout.Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        NSLayoutConstraint.deactivate(modeConstraints)
        coverWidth.constant = Self.coverSide(for: mode)
        switch mode {
        case .regular:
            modeConstraints = [
                cover.topAnchor.constraint(equalTo: topAnchor),
                cover.leadingAnchor.constraint(equalTo: leadingAnchor),
                cover.bottomAnchor.constraint(equalTo: bottomAnchor),
                text.leadingAnchor.constraint(equalTo: cover.trailingAnchor, constant: 28),
                text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                text.bottomAnchor.constraint(equalTo: cover.bottomAnchor),
                text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            ]
        case .compact, .wide:
            modeConstraints = [
                cover.topAnchor.constraint(equalTo: topAnchor),
                cover.leadingAnchor.constraint(equalTo: leadingAnchor),
                text.topAnchor.constraint(equalTo: cover.bottomAnchor, constant: mode == .wide ? 24 : 16),
                text.leadingAnchor.constraint(equalTo: leadingAnchor),
                text.trailingAnchor.constraint(equalTo: trailingAnchor),
                text.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
        }
        NSLayoutConstraint.activate(modeConstraints)
    }
}

/// The shell both song pages share. The page's width picks one of three
/// arrangements through `TrackPageLayout`: compact stacks a small hero over
/// the songs, regular keeps the hero above them in a clamped, centred column,
/// and wide moves the hero into a fixed rail that does not scroll while the
/// songs scroll beside it.
final class TrackPageFrameView: NSView {

    let scrollView = NSScrollView()
    private let document = DetailDocumentView()
    private let column = NSStackView()
    private let rail = NSView()
    private let hero: TrackHeroView
    private let railWidth: NSLayoutConstraint
    private let columnMaxWidth: NSLayoutConstraint
    private let columnFill: NSLayoutConstraint
    private let columnLeading: NSLayoutConstraint
    private let columnTrailing: NSLayoutConstraint
    private let columnTop: NSLayoutConstraint
    private let columnBottom: NSLayoutConstraint
    private var heroConstraints: [NSLayoutConstraint] = []
    private var bodyViews: [NSView] = []
    private(set) var mode: TrackPageLayout.Mode?

    init(hero: TrackHeroView) {
        self.hero = hero
        railWidth = rail.widthAnchor.constraint(equalToConstant: 0)
        columnMaxWidth = column.widthAnchor.constraint(lessThanOrEqualToConstant: 1080)
        columnFill = column.widthAnchor.constraint(equalTo: document.widthAnchor)
        columnFill.priority = .defaultHigh
        columnLeading = column.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor)
        columnTrailing = document.trailingAnchor.constraint(greaterThanOrEqualTo: column.trailingAnchor)
        columnTop = column.topAnchor.constraint(equalTo: document.topAnchor)
        columnBottom = document.bottomAnchor.constraint(equalTo: column.bottomAnchor)
        super.init(frame: .zero)

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 24
        column.translatesAutoresizingMaskIntoConstraints = false

        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)

        rail.translatesAutoresizingMaskIntoConstraints = false
        rail.isHidden = true

        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(rail)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            rail.topAnchor.constraint(equalTo: topAnchor),
            rail.leadingAnchor.constraint(equalTo: leadingAnchor),
            rail.bottomAnchor.constraint(equalTo: bottomAnchor),
            railWidth,

            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            document.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            column.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            columnMaxWidth, columnFill, columnLeading, columnTrailing, columnTop, columnBottom,
        ])
        arrange(.regular)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The views under the hero, in order, each as wide as the column.
    func setBody(_ views: [NSView]) {
        bodyViews.forEach { $0.removeFromSuperview() }
        bodyViews = views
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            column.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
    }

    /// Runs `change`, which rebuilds the page's content, and puts the page back
    /// where the reader was instead of at the top.
    func preservingScroll(_ change: () -> Void) {
        let clip = scrollView.contentView
        let offset = clip.bounds.origin.y
        change()
        layoutSubtreeIfNeeded()
        let lowest = -scrollView.contentInsets.top
        let highest = max(lowest, document.bounds.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(offset, lowest), highest)))
        scrollView.reflectScrolledClipView(clip)
    }

    func scrollToTop() {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: -scrollView.contentInsets.top))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Scrolls so `rect`, given in `view`'s coordinates, sits about a third of
    /// the way down the viewport.
    func reveal(_ rect: NSRect, in view: NSView) {
        let clip = scrollView.contentView
        let inDocument = document.convert(rect, from: view)
        let viewport = clip.bounds.height
        let lowest = -scrollView.contentInsets.top
        let highest = max(lowest, document.bounds.height - viewport)
        let target = min(max(inDocument.minY - viewport * 0.33, lowest), highest)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        scrollView.reflectScrolledClipView(clip)
    }

    override func layout() {
        super.layout()
        let wanted = TrackPageLayout.mode(forWidth: Int(bounds.width))
        guard wanted != mode else { return }
        arrange(wanted)
    }

    private func arrange(_ mode: TrackPageLayout.Mode) {
        self.mode = mode
        let inRail = mode == .wide
        hero.apply(mode)
        placeHero(inRail: inRail)
        rail.isHidden = !inRail
        railWidth.constant = inRail ? TrackHeroView.railWidth : 0
        let edge: CGFloat = switch mode {
        case .compact: 16
        case .regular: 32
        case .wide: 28
        }
        columnLeading.constant = edge
        columnTrailing.constant = edge
        columnFill.constant = -2 * edge
        columnMaxWidth.constant = inRail ? 1240 : 1080
        columnTop.constant = 56
        columnBottom.constant = 32
        column.spacing = mode == .compact ? 16 : 24
    }

    /// Moves the hero between the rail and the top of the scrolling column.
    private func placeHero(inRail: Bool) {
        NSLayoutConstraint.deactivate(heroConstraints)
        heroConstraints = []
        if column.arrangedSubviews.contains(hero) { column.removeArrangedSubview(hero) }
        hero.removeFromSuperview()
        hero.translatesAutoresizingMaskIntoConstraints = false
        if inRail {
            rail.addSubview(hero)
            heroConstraints = [
                hero.topAnchor.constraint(equalTo: rail.topAnchor, constant: 56),
                hero.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: 28),
                hero.trailingAnchor.constraint(equalTo: rail.trailingAnchor, constant: -24),
            ]
        } else {
            column.insertArrangedSubview(hero, at: 0)
            heroConstraints = [hero.widthAnchor.constraint(equalTo: column.widthAnchor)]
        }
        NSLayoutConstraint.activate(heroConstraints)
    }
}
