import AppKit

/// Hosts the selected section's view controller in the split view's content
/// column. Library sections are drill-down stacks that keep their state while
/// the user switches around; reveal notifications jump to an album or artist
/// detail from anywhere; the first-launch onboarding panel floats on top
/// until the library has music.
final class ContentRouter: NSViewController {

    private(set) var currentSection: SidebarSection?
    private var currentChild: NSViewController?
    private var sectionControllers: [SidebarSection: NSViewController] = [:]
    private var onboardingView: OnboardingPanelView?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
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
        refreshOnboarding()
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
            MacToast.show("\u{201C}\(title)\u{201D} is no longer in your library.", style: .info, in: view.window)
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

    private func switchTo(_ section: SidebarSection) {
        guard currentSection != section else { return }
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

    @objc private func refreshOnboarding() {
        let visibility = OnboardingPanelView.visibility
        if visibility == .show, onboardingView == nil {
            let panel = OnboardingPanelView()
            panel.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(panel)
            NSLayoutConstraint.activate([
                panel.topAnchor.constraint(equalTo: view.topAnchor),
                panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            onboardingView = panel
            AppLogger.info("Onboarding panel shown", category: .ui)
        } else if visibility == .hide, let onboardingView {
            onboardingView.removeFromSuperview()
            self.onboardingView = nil
            AppLogger.info("Onboarding panel dismissed", category: .ui)
        }
    }
}
