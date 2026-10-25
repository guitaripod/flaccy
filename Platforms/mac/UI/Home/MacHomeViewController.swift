import AppKit
import MidgarCore
import FlaccyCore
import FlaccyEngine

/// A flipped document view that reports when its width changes.
final class MacHomeDocumentView: NSView {

    var onWidthChange: ((CGFloat) -> Void)?

    private var reportedWidth: CGFloat = -1

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        guard bounds.width != reportedWidth else { return }
        reportedWidth = bounds.width
        onWidthChange?(bounds.width)
    }
}

/// The first thing the Mac shows: where you left off, what to go back to, what
/// was made for you and what is new, put together from a `HomeFeed` that is
/// built off the main actor and rebuilt when anything it reads changes.
final class MacHomeViewController: NSViewController {

    static let sidePadding: CGFloat = 32
    static let maximumContentWidth: CGFloat = 1500
    static let wideBreakpoint: CGFloat = 1100
    static let stackedStripBreakpoint: CGFloat = 680

    private let backdrop = MacHomeBackdropView()
    private let scrollView = NSScrollView()
    private let document = MacHomeDocumentView()
    private let column = NSStackView()
    private var emptyHost: NSView?
    private var backdropTop: NSLayoutConstraint?
    private var columnFill: NSLayoutConstraint?
    private var topRow: MacHomeTopRow?
    private var heroRow: MacHomeTopRow?
    private var strips: [NSStackView] = []
    private var observers: [NSObjectProtocol] = []
    private var feed: HomeFeed?
    private var generation = 0
    private var refreshPending = false
    private var isVisible = false

    override func loadView() {
        let root = AppearanceObservingView()
        root.wantsLayer = true
        view = root

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(backdrop)

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 32
        column.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)

        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        let backdropTop = backdrop.topAnchor.constraint(equalTo: root.topAnchor)
        self.backdropTop = backdropTop
        let fill = column.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -Self.sidePadding * 2)
        fill.priority = NSLayoutConstraint.Priority(750)
        columnFill = fill

        NSLayoutConstraint.activate([
            backdropTop,
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.heightAnchor.constraint(equalToConstant: MacHomeBackdropView.height),

            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),

            column.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            column.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maximumContentWidth),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: Self.sidePadding),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
            fill,
        ])

        document.onWidthChange = { [weak self] width in self?.widthDidChange(width) }
        scrollView.contentView.postsBoundsChangedNotifications = true
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        isVisible = true
        startObserving()
        scheduleRefresh()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        isVisible = false
        stopObserving()
    }

    isolated deinit {
        stopObserving()
    }

    func presentCustomize() {
        guard presentedViewControllers?.isEmpty ?? true else { return }
        presentAsSheet(MacHomeCustomizeViewController())
    }

    #if DEBUG
    func scrollForCapture(to offset: CGFloat) {
        view.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: offset - clip.contentInsets.top))
        scrollView.reflectScrolledClipView(clip)
    }
    #endif

    private var contentWidth: CGFloat {
        min(max(document.bounds.width - Self.sidePadding * 2, 0), Self.maximumContentWidth)
    }

    private var isWide: Bool {
        contentWidth >= Self.wideBreakpoint
    }

    private func widthDidChange(_ width: CGFloat) {
        topRow?.setWide(isWide)
        let stacked = contentWidth < Self.stackedStripBreakpoint
        for strip in strips {
            strip.orientation = stacked ? .vertical : .horizontal
        }
    }

    private func startObserving() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            Library.didUpdateNotification,
            AudioPlayer.trackDidChange,
            AudioPlayer.playbackStateDidChange,
            AudioPlayer.queueDidChange,
            RecentContextStore.didChange,
            HomeLayoutStore.didChange,
            PurchaseManager.stateDidChange,
            PurchaseManager.entitlementsDidLoad,
            AlbumArtworkCache.didChangeNotification,
            NSApplication.didBecomeActiveNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }
        observers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrollDidMove() }
        })
    }

    private func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func scrollDidMove() {
        let clip = scrollView.contentView
        let offset = clip.bounds.origin.y + clip.contentInsets.top
        backdropTop?.constant = -max(offset, 0)
    }

    private func scheduleRefresh() {
        guard isVisible, !refreshPending else { return }
        refreshPending = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            self?.refreshPending = false
            self?.refresh()
        }
    }

    /// Reads what Home needs on the main actor, builds the feed off it, and
    /// keeps the answer only if nothing newer has been asked for since.
    private func refresh() {
        guard isVisible else { return }
        generation += 1
        let token = generation
        let inputs = HomeFeedInputs.current()
        Task.detached(priority: .userInitiated) { [weak self] in
            let built = HomeFeedBuilder.build(inputs)
            await MainActor.run {
                guard let self, self.generation == token else { return }
                self.apply(built)
            }
        }
    }

    private func apply(_ feed: HomeFeed) {
        self.feed = feed
        let clip = scrollView.contentView
        let restore = clip.bounds.origin.y
        clearColumn()
        emptyHost?.removeFromSuperview()
        emptyHost = nil
        HomePromoOffers.loadIfNeeded(for: feed.promo)
        scrollView.isHidden = feed.hero == .empty
        backdrop.show(heroCover(of: feed))
        guard feed.hero != .empty else {
            showFirstRun(feed)
            return
        }

        let index = MacHomeCoverIndex(albums: Library.shared.albums)
        var position = 0
        let blocks = feed.blocks
        while position < blocks.count {
            let block = blocks[position]
            if case .single(.resume) = block, position + 1 < blocks.count, case .single(.jumpBackIn) = blocks[position + 1],
               !feed.jumpBackIn.isEmpty {
                addTopRow(hero: true, panel: true, feed: feed)
                position += 2
                continue
            }
            add(block, feed: feed, index: index)
            position += 1
        }
        addPromoBesideThePage(feed)
        document.layoutSubtreeIfNeeded()
        widthDidChange(document.bounds.width)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: restore))
        scrollView.reflectScrolledClipView(clip)
    }

    private func clearColumn() {
        for view in column.arrangedSubviews {
            column.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        topRow = nil
        heroRow = nil
        strips = []
    }

    /// With nothing of the person's own in the library the page is the card
    /// that brings music in, alone and centred.
    private func showFirstRun(_ feed: HomeFeed) {
        guard let card = promoView(feed) else { return }
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -Self.sidePadding * 2),
        ])
        emptyHost = card
    }

    /// The footnote and the last-day card go straight under the hero, the
    /// value card ends the page, and a card that replaces the hero was already
    /// placed where the hero stands, unless Continue is turned off and there
    /// is no hero row to stand in for: then it leads the page.
    private func addPromoBesideThePage(_ feed: HomeFeed) {
        guard let promo = feed.promo else { return }
        if promo.placement == .replacesHero, heroRow != nil { return }
        guard let extra = promoView(feed) else { return }
        extra.translatesAutoresizingMaskIntoConstraints = false
        switch promo.placement {
        case .replacesHero:
            column.insertArrangedSubview(extra, at: 0)
        case .heroFootnote, .belowHero:
            let index = heroRow.flatMap { column.arrangedSubviews.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            column.insertArrangedSubview(extra, at: index)
            if let heroRow, promo.placement == .heroFootnote { column.setCustomSpacing(12, after: heroRow) }
        case .pageEnd:
            column.addArrangedSubview(extra)
        }
        let limit = extra is MacHomePromoNote
            ? extra.widthAnchor.constraint(equalTo: column.widthAnchor)
            : extra.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor)
        limit.isActive = true
    }

    private func add(_ block: HomeBlock, feed: HomeFeed, index: MacHomeCoverIndex) {
        switch block {
        case .single(.resume):
            addTopRow(hero: true, panel: false, feed: feed)
        case .single(.jumpBackIn):
            addTopRow(hero: false, panel: !feed.jumpBackIn.isEmpty, feed: feed)
        case .single(.madeForYou):
            addFull(madeForYou(feed, index: index))
        case .single(.recentlyAdded):
            addFull(recentlyAdded(feed))
        case .single(.onThisDay):
            if let card = memoryCard(feed) { addFull(card) }
        case .single(.thisWeek):
            if let card = weekCard(feed) { addFull(card) }
        case .pair(let first, let second):
            let cards = [first, second].compactMap { card(for: $0, feed: feed) }
            guard !cards.isEmpty else { return }
            let strip = NSStackView(views: cards)
            strip.orientation = .horizontal
            strip.distribution = .fillEqually
            strip.spacing = 16
            strips.append(strip)
            addFull(strip)
        }
    }

    private func card(for section: HomeSection, feed: HomeFeed) -> NSView? {
        switch section {
        case .onThisDay: memoryCard(feed)
        case .thisWeek: weekCard(feed)
        default: nil
        }
    }

    private func addFull(_ view: NSView) {
        column.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    private func addTopRow(hero: Bool, panel: Bool, feed: HomeFeed) {
        let row = MacHomeTopRow()
        if hero { row.setHero(heroView(feed)) }
        if panel { row.setPanel(jumpBackInPanel(feed)) }
        row.setWide(isWide)
        topRow = row
        if hero { heroRow = row }
        addFull(row)
    }

    private func heroCover(of feed: HomeFeed) -> Album? {
        if feed.promo?.placement == .replacesHero { return nil }
        switch feed.hero {
        case .resume: return feed.resume?.album
        case .upNext: return feed.upNext?.albums.first
        case .dayOne: return feed.dayOne?.coverAlbums.first
        case .empty: return nil
        }
    }
}

/// Library albums by their identity, so a mix's tracks can be turned into the
/// albums for its cover without scanning the library once per track.
struct MacHomeCoverIndex {

    private let index: HomeFeedBuilder.AlbumIndex

    init(albums: [Album]) {
        index = HomeFeedBuilder.AlbumIndex(albums: albums)
    }

    func albums(for tracks: [Track]) -> [Album] {
        HomeFeedBuilder.coverAlbums(tracks, index: index)
    }

    func album(titled title: String, credit: String) -> Album? {
        index.album(title: title, artist: credit)
    }
}
