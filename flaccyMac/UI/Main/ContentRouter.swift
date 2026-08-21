import AppKit
import Combine
import FlaccyCore

/// Hosts the selected section's view controller in the split view's content
/// column. Library sections are drill-down stacks that keep their state while
/// the user switches around; reveal notifications jump to an album or artist
/// detail from anywhere; the first-launch onboarding panel floats on top
/// until the library has music, and grows into the Debut while one is being
/// built for the first time.
final class ContentRouter: NSViewController {

    private(set) var currentSection: SidebarSection?
    private var currentChild: NSViewController?
    private var sectionControllers: [SidebarSection: NSViewController] = [:]
    private var onboardingView: OnboardingPanelView?
    private let backdrop = AmbientBackdropView(vivid: true)
    private var surfaceCancellable: AnyCancellable?

    /// How far the library dims behind the Debut panel, so the grid the reader
    /// is about to land in stays visible underneath instead of being replaced by
    /// a second empty state.
    private static let debutContentAlpha: CGFloat = 0.55

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        backdrop.apply(NowPlayingPaletteService.shared.current, animated: false)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NowPlayingPaletteService.shared.start()
        NotificationCenter.default.addObserver(
            self, selector: #selector(nowPlayingPaletteChanged), name: .flaccyNowPlayingPaletteChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRevealAlbum(_:)), name: .flaccyRevealAlbum, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRevealArtist(_:)), name: .flaccyRevealArtist, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshOnboarding), name: Library.didUpdateNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshOnboarding), name: LibraryRoot.didChange, object: nil
        )
        surfaceCancellable = MacLibrarySurfaceModel.shared.state
            .removeDuplicates()
            .sink { [weak self] state in
                self?.render(state)
            }
        render(MacLibrarySurfaceModel.shared.state.value)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func show(_ section: SidebarSection) {
        guard section != currentSection else { return }
        currentSection = section

        let next = controller(for: section)
        if let currentChild {
            currentChild.view.removeFromSuperview()
            currentChild.removeFromParent()
        }
        addChild(next)
        next.view.translatesAutoresizingMaskIntoConstraints = false
        next.view.alphaValue = onboardingView?.isPresentingDebut == true ? Self.debutContentAlpha : 1
        if let onboardingView {
            view.addSubview(next.view, positioned: .below, relativeTo: onboardingView)
        } else {
            view.addSubview(next.view)
        }
        NSLayoutConstraint.activate([
            next.view.topAnchor.constraint(equalTo: view.topAnchor),
            next.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            next.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        currentChild = next
        AppLogger.info("Content router showing \(section.title)", category: .ui)
    }

    func revealAlbum(title: String, artist: String) {
        guard let album = Library.shared.albums.first(where: {
            $0.title == title && $0.artist == artist
        }) else {
            MacToast.show(String(localized: "\u{201C}\(title)\u{201D} is no longer in your library."), style: .info, in: view.window)
            return
        }
        switchTo(.albums)
        guard let stack = sectionControllers[.albums] as? ContentStackController else { return }
        stack.popToRoot()
        stack.push(makeAlbumDetail(album, in: stack))
    }

    func revealArtist(_ name: String) {
        switchTo(.artists)
        guard let stack = sectionControllers[.artists] as? ContentStackController else { return }
        stack.popToRoot()
        stack.push(makeArtistDetail(name, in: stack))
    }

    @objc private func handleRevealAlbum(_ notification: Notification) {
        guard let title = notification.userInfo?[LibraryNavigator.Key.albumTitle] as? String,
              let artist = notification.userInfo?[LibraryNavigator.Key.artist] as? String else { return }
        revealAlbum(title: title, artist: artist)
    }

    @objc private func handleRevealArtist(_ notification: Notification) {
        guard let name = notification.userInfo?[LibraryNavigator.Key.artist] as? String else { return }
        revealArtist(name)
    }

    /// Always posts the section notification — even when the target section is
    /// already current — because MainSplitViewController relies on it to close
    /// the Now Playing overlay before the reveal is pushed underneath it.
    private func switchTo(_ section: SidebarSection) {
        NotificationCenter.default.post(
            name: .flaccyShowSection,
            object: nil,
            userInfo: [SectionNotificationKey.section: section.rawValue]
        )
        show(section)
    }

    private func controller(for section: SidebarSection) -> NSViewController {
        if let existing = sectionControllers[section] { return existing }
        let created = makeController(for: section)
        sectionControllers[section] = created
        return created
    }

    private func makeController(for section: SidebarSection) -> NSViewController {
        switch section {
        case .albums:
            let grid = AlbumGridViewController()
            let stack = ContentStackController(root: grid)
            grid.onOpenAlbum = { [weak self, weak stack] album in
                guard let self, let stack else { return }
                stack.push(self.makeAlbumDetail(album, in: stack))
            }
            return stack
        case .songs:
            return SongsTableViewController()
        case .artists:
            let artists = ArtistsViewController()
            let stack = ContentStackController(root: artists)
            artists.onOpenArtist = { [weak self, weak stack] name in
                guard let self, let stack else { return }
                stack.push(self.makeArtistDetail(name, in: stack))
            }
            return stack
        case .playlists:
            let playlists = PlaylistsViewController()
            let stack = ContentStackController(root: playlists)
            playlists.onOpenPlaylist = { [weak stack] record in
                stack?.push(PlaylistDetailViewController(playlist: record))
            }
            return stack
        case .wantlist:
            return WantlistViewController()
        case .charts:
            return ChartsViewController()
        case .yearInMusic:
            return YearInMusicViewController()
        case .listeningGuide:
            return ListeningGuideViewController()
        }
    }

    private func makeAlbumDetail(_ album: Album, in stack: ContentStackController) -> AlbumDetailViewController {
        let detail = AlbumDetailViewController(album: album)
        detail.onSelectArtist = { [weak self] name in
            self?.revealArtist(name)
        }
        return detail
    }

    private func makeArtistDetail(_ name: String, in stack: ContentStackController) -> ArtistDetailViewController {
        let detail = ArtistDetailViewController(artist: name)
        detail.onOpenAlbum = { [weak self, weak stack] album in
            guard let self, let stack else { return }
            stack.push(self.makeAlbumDetail(album, in: stack))
        }
        detail.onSelectArtist = { [weak self, weak stack] other in
            guard let self, let stack else { return }
            stack.push(self.makeArtistDetail(other, in: stack))
        }
        return detail
    }

    @objc private func nowPlayingPaletteChanged() {
        backdrop.apply(NowPlayingPaletteService.shared.current, animated: true)
    }

    private func render(_ state: MacLibrarySurfaceModel.State) {
        refreshOnboarding()
        onboardingView?.render(state)
    }

    @objc private func refreshOnboarding() {
        let visibility = OnboardingPanelView.visibility
        if visibility == .show, onboardingView == nil {
            installOnboardingPanel()
        } else if visibility == .hide, let onboardingView {
            onboardingView.removeFromSuperview()
            self.onboardingView = nil
            currentChild?.view.alphaValue = 1
            AppLogger.info("Onboarding panel dismissed", category: .ui)
        }
    }

    private func installOnboardingPanel() {
        let panel = OnboardingPanelView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.onFinishDebut = { [weak self] summary in
            self?.finishDebut(summary)
        }
        view.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: view.topAnchor),
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        onboardingView = panel
        panel.render(MacLibrarySurfaceModel.shared.state.value)
        AppLogger.info("Onboarding panel shown", category: .ui)
    }

    /// The close of Act III: the panel falls away while the grid it was standing
    /// in front of comes up to full strength, so the library the reader watched
    /// being built is literally the one they land in.
    private func finishDebut(_ summary: LibraryDebutSummary) {
        MacLibrarySurfaceModel.shared.completeDebut(summary)
        badgeDock(with: summary.trackCount)
        guard let panel = onboardingView else { return }
        onboardingView = nil
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.45
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
            currentChild?.view.animator().alphaValue = 1
        } completionHandler: {
            panel.removeFromSuperview()
        }
        AppLogger.info("Library debut dismissed (\(summary.trackCount) tracks)", category: .ui)
    }

    /// The Mac's equivalent of the iPhone's success haptic: the number the
    /// summary card just claimed, on the Dock icon, for three seconds.
    private func badgeDock(with trackCount: Int) {
        NSApp.dockTile.badgeLabel = LibraryLoadPhaseCopy.number(trackCount)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            NSApp.dockTile.badgeLabel = nil
        }
    }
}

/// The Mac's single reader of `LibrarySurfaceRouter`.
///
/// Three surfaces ask the same question — the status strip, the titlebar chip
/// and the onboarding panel — so the two streams they depend on are merged once,
/// here, and routed once. Merging matters: the load snapshot and its fraction
/// arrive on one notification and the job on another, and a surface that
/// subscribed to both separately could apply them in either order.
@MainActor
final class MacLibrarySurfaceModel {

    static let shared = MacLibrarySurfaceModel()

    struct State: Equatable {
        var surface: LibrarySurface = .none
        var load: LibraryLoadProgress = .idle
        var fraction: Double = 0
        var job: EnrichmentJobProgress = .idle
        var act: LibraryDebutAct = .indexing
    }

    /// How often the Debut re-asks the director while the second act is running,
    /// so the 90 s curtain fires even when a stalled job has stopped publishing.
    private static let curtainTick: TimeInterval = 0.5

    let state = CurrentValueSubject<State, Never>(State())

    private var router = LibrarySurfaceRouter()
    private var director = LibraryDebutDirector()
    private var cancellables: Set<AnyCancellable> = []
    private var curtainTimer: Timer?
    private var finishingSince: Date?
    private var started = false

    /// Read once, at launch, and never re-read. The router's debut latch is
    /// released by `releaseDebut()` alone; letting this flip to true mid-Debut —
    /// which it would, the moment the first build is written — would drop the
    /// showpiece halfway through.
    private var debutCompleted = false

    /// Whether the enrichment coordinator has published since launch. The seed
    /// below reads its still-idle box, so only a real notification counts.
    private var heardFromJob = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        debutCompleted = Self.readDebutCompleted()

        NotificationCenter.default.publisher(for: Library.progressDidChange)
            .compactMap { notification -> (LibraryLoadProgress, Double)? in
                guard let progress = notification.userInfo?[Library.ProgressKey.progress] as? LibraryLoadProgress,
                      let fraction = notification.userInfo?[Library.ProgressKey.fraction] as? Double
                else { return nil }
                return (progress, fraction)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress, fraction in
                self?.apply { $0.load = progress; $0.fraction = fraction }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: EnrichmentCoordinator.progressDidChange)
            .compactMap { $0.userInfo?[EnrichmentCoordinator.ProgressKey.progress] as? EnrichmentJobProgress }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] job in
                self?.heardFromJob = true
                self?.apply { $0.job = job }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: Library.didUpdateNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.apply { _ in }
            }
            .store(in: &cancellables)

        apply { $0.job = EnrichmentCoordinator.shared.progress }
    }

    /// Records the finished Debut and lets the router out of its latch. Called
    /// once, by the surface that dismissed the summary card.
    func completeDebut(_ summary: LibraryDebutSummary) {
        debutCompleted = true
        router.releaseDebut()
        LibraryStartupProbe.markIndexed()
        do {
            try DatabaseManager.shared.saveLibraryDebut(summary)
        } catch {
            AppLogger.error("Saving library debut failed: \(error.localizedDescription)", category: .database)
        }
        apply { _ in }
    }

    private func apply(_ mutate: (inout State) -> Void) {
        var next = state.value
        mutate(&next)

        let albums = Library.shared.albums.count
        next.surface = router.route(
            load: next.load,
            job: next.job,
            debutCompleted: debutCompleted,
            hasLibrary: albums > 0,
            elapsed: jobElapsed(next.job)
        )

        if next.surface == .debut, advanceDebut(next, albumCount: albums) == .done {
            next.surface = .none
        }
        next.act = director.act
        state.value = next
        updateCurtainTimer(for: next)
    }

    /// Advances the Debut and reports the act it landed on. A first build that
    /// produced no albums has nothing to show off: the director reports `.done`
    /// straight away and the latch is released here without writing
    /// `libraryDebut`, because an empty folder is not a library that was built.
    private func advanceDebut(_ state: State, albumCount: Int) -> LibraryDebutAct {
        let elapsed = elapsedInFinishing(director.act)
        director.advance(
            load: state.load, job: state.job, albumCount: albumCount,
            elapsedInFinishing: elapsed,
            jobHeardFrom: jobHasSpoken(elapsedInFinishing: elapsed)
        )
        if director.act == .done { router.releaseDebut() }
        return director.act
    }

    /// Whether the director may believe a drained queue means the enrichment
    /// job is over. The job's snapshot starts life `.idle` with nothing
    /// remaining, which reads as drained and would skip the finishing act
    /// before the coordinator has counted what is due; the floor keeps a pass
    /// that never reports from stranding the act, and the curtain still caps it.
    private func jobHasSpoken(elapsedInFinishing: TimeInterval) -> Bool {
        heardFromJob || elapsedInFinishing >= Self.jobReportFloor
    }

    private static let jobReportFloor: TimeInterval = 2

    private func jobElapsed(_ job: EnrichmentJobProgress) -> TimeInterval {
        guard let startedAt = job.startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    private func elapsedInFinishing(_ act: LibraryDebutAct) -> TimeInterval {
        guard act == .finishing else {
            finishingSince = nil
            return 0
        }
        guard let finishingSince else {
            self.finishingSince = Date()
            return 0
        }
        return Date().timeIntervalSince(finishingSince)
    }

    private func updateCurtainTimer(for state: State) {
        let wanted = state.surface == .debut && state.act == .finishing
        guard wanted else {
            curtainTimer?.invalidate()
            curtainTimer = nil
            return
        }
        guard curtainTimer == nil else { return }
        curtainTimer = Timer.scheduledTimer(withTimeInterval: Self.curtainTick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply { _ in } }
        }
    }

    private static func readDebutCompleted() -> Bool {
        if LibraryStartupProbe.hadIndexedLibrary { return true }
        return ((try? DatabaseManager.shared.libraryDebut()) ?? nil) != nil
    }
}
