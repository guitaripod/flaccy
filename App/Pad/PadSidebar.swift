import FlaccyCore
import GRDB
import MidgarCore
import UIKit

/// The iPad's sidebar: Home, Recap and Search as on the iPhone, the Library's
/// four pivots as one group, every playlist as its own destination, and the
/// Wantlist, Listening Guide and Year in Music under Discover. In a window too
/// narrow for a sidebar the same tabs collapse to the iPhone's four, and the
/// Library's segmented picker takes the pivots back.
final class PadSidebar: NSObject {

    enum Identifier {
        static let libraryGroup = "library"
        static let playlistsGroup = "playlists"
        static let discoverGroup = "discover"
        static let wantlist = "discover.wantlist"
        static let listeningGuide = "discover.listeningGuide"
        static let playlistPrefix = "playlist."

        static func pivot(_ segment: LibraryViewModel.Segment) -> String {
            "library.\(segment.identifier)"
        }

        static func playlist(_ id: Int64) -> String {
            playlistPrefix + String(id)
        }
    }

    let libraryGroup: UITabGroup
    let playlistsGroup: UITabGroup
    let discoverGroup: UITabGroup
    let playlistsNavigation = UINavigationController()

    private weak var tabs: AppTabBarController?
    private var playlistObservation: AnyDatabaseCancellable?
    private var playlistTabs: [Int64: UITab] = [:]
    private var playlistNames: [Int64: String] = [:]

    /// Called whenever the sidebar starts or stops standing in for the
    /// Library's segmented picker, with true while it does.
    var onShowsPivotsChange: ((Bool) -> Void)?

    init(tabs: AppTabBarController) {
        self.tabs = tabs
        let pivots = LibraryViewModel.Segment.allCases.map { segment in
            UITab(
                title: segment.title, image: UIImage(systemName: segment.symbolName),
                identifier: Identifier.pivot(segment), viewControllerProvider: nil
            )
        }
        libraryGroup = UITabGroup(
            title: String(localized: "Library"), image: UIImage(systemName: "square.stack.fill"),
            identifier: Identifier.libraryGroup, children: pivots
        ) { [library = tabs.library] _ in library }
        libraryGroup.managingNavigationController = tabs.libraryNavigation
        libraryGroup.sidebarAppearance = .rootSection

        playlistsGroup = UITabGroup(
            title: String(localized: "Playlists"), image: UIImage(systemName: "music.note.list"),
            identifier: Identifier.playlistsGroup, children: []
        ) { _ in SidebarSectionPlaceholder() }
        playlistsGroup.preferredPlacement = .sidebarOnly
        playlistsGroup.sidebarAppearance = .rootSection
        playlistsGroup.managingNavigationController = playlistsNavigation

        let wantlist = UITab(
            title: String(localized: "Wantlist"), image: UIImage(systemName: "sparkles.rectangle.stack"),
            identifier: Identifier.wantlist
        ) { _ in
            UINavigationController(rootViewController: WantlistViewController())
        }
        let guide = UITab(
            title: String(localized: "Listening Guide"), image: UIImage(systemName: "book"),
            identifier: Identifier.listeningGuide
        ) { _ in
            UINavigationController(rootViewController: ListeningGuideViewController())
        }
        discoverGroup = UITabGroup(
            title: String(localized: "Discover"), image: UIImage(systemName: "sparkles"),
            identifier: Identifier.discoverGroup, children: [wantlist, guide]
        ) { _ in SidebarSectionPlaceholder() }
        discoverGroup.preferredPlacement = .sidebarOnly
        discoverGroup.sidebarAppearance = .rootSection
        super.init()

        playlistsGroup.sidebarActions = [
            UIAction(title: String(localized: "New Playlist"), image: UIImage(systemName: "plus")) { [weak self] _ in
                self?.createPlaylist()
            },
        ]
        discoverGroup.sidebarActions = [
            UIAction(title: String(localized: "Year in Music"), image: UIImage(systemName: "calendar.badge.clock")) { [weak tabs] _ in
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                tabs?.present(YearInMusicViewController(), animated: true)
            },
        ]
        observePlaylists()
    }

    func pivotTab(for segment: LibraryViewModel.Segment) -> UITab? {
        libraryGroup.tab(forIdentifier: Identifier.pivot(segment))
    }

    /// Keeps the sidebar's selection on the pivot the Library is showing, so a
    /// change made from the segmented picker in a narrow window is still
    /// selected once the sidebar returns.
    func libraryDidSwitch(to segment: LibraryViewModel.Segment) {
        guard let pivot = pivotTab(for: segment), libraryGroup.selectedChild !== pivot else { return }
        libraryGroup.selectedChild = pivot
    }

    /// Whether the window has room for a sidebar at all, shown or not.
    var sidebarIsAvailable: Bool {
        guard let tabs, tabs.mode == .tabSidebar else { return false }
        if #available(iOS 27.0, *) {
            return tabs.sidebar.isAvailable
        }
        return tabs.traitCollection.horizontalSizeClass == .regular
    }

    /// Whether the sidebar is on screen, so the Library's pivots live there
    /// rather than in its own segmented picker.
    var showsPivots: Bool {
        guard let tabs else { return false }
        return sidebarIsAvailable && !tabs.sidebar.isHidden
    }

    func notifyPivotPlacement() {
        fitSectionsToSidebar()
        onShowsPivotsChange?(showsPivots)
    }

    private var primaryTabs: [UITab] = []

    /// The tabs the window always has, in tab bar order; the sidebar adds the
    /// Playlists and Discover sections after them.
    func setPrimaryTabs(_ primary: [UITab]) {
        primaryTabs = primary
    }

    /// A compact window has no sidebar, and its tab bar would otherwise list
    /// the sidebar-only sections as tabs of their own and push Search behind
    /// More, whatever their placement says; there the tabs are the iPhone's
    /// four, and a destination inside a section hands over to the Library.
    private func fitSectionsToSidebar() {
        guard let tabs, !primaryTabs.isEmpty else { return }
        let compact = !sidebarIsAvailable
        let wanted = compact ? primaryTabs : primaryTabs + [playlistsGroup, discoverGroup]
        guard tabs.tabs.map(\.identifier) != wanted.map(\.identifier) else { return }
        let selectedID = tabs.selectedTab.map { $0.parent?.identifier ?? $0.identifier }
        tabs.setTabs(wanted, animated: false)
        if compact, selectedID == Identifier.playlistsGroup {
            tabs.showLibrary(.playlists)
        } else if compact, selectedID == Identifier.discoverGroup {
            tabs.showLibrary(tabs.library.viewModel.currentSegment)
        }
        MidgarLog.debug("Tabs for a \(compact ? "compact window" : "window with a sidebar"): \(wanted.count)", category: .ui)
    }

    private func observePlaylists() {
        playlistObservation = DatabaseManager.shared.observePlaylists { [weak self] playlists in
            self?.applyPlaylists(playlists)
        }
    }

    /// Rebuilds the Playlists section from the database, reusing each existing
    /// tab so an open playlist keeps its screen and scroll position through a
    /// rename or an unrelated change.
    private func applyPlaylists(_ playlists: [PlaylistRecord]) {
        var children: [UITab] = []
        var kept: [Int64: UITab] = [:]
        for playlist in playlists {
            guard let id = playlist.id else { continue }
            let tab = playlistTabs[id] ?? makePlaylistTab(id: id, name: playlist.name)
            if tab.title != playlist.name {
                tab.title = playlist.name
                (tab.viewController as? PlaylistDetailViewController)?.showRenamed(playlist.name)
            }
            playlistNames[id] = playlist.name
            kept[id] = tab
            children.append(tab)
        }
        playlistTabs = kept
        playlistNames = playlistNames.filter { kept[$0.key] != nil }
        guard children.map(\.identifier) != playlistsGroup.children.map(\.identifier) else { return }
        playlistsGroup.children = children
        MidgarLog.debug("Sidebar playlists: \(children.count)", category: .ui)
    }

    private func makePlaylistTab(id: Int64, name: String) -> UITab {
        UITab(title: name, image: UIImage(systemName: "music.note.list"), identifier: Identifier.playlist(id)) { [weak self] _ in
            PlaylistDetailViewController(playlistId: id, playlistName: self?.playlistNames[id] ?? name)
        }
    }

    func playlistID(for tab: UITab) -> Int64? {
        guard tab.identifier.hasPrefix(Identifier.playlistPrefix) else { return nil }
        return Int64(tab.identifier.dropFirst(Identifier.playlistPrefix.count))
    }

    private func createPlaylist() {
        guard let tabs else { return }
        tabs.library.createPlaylistTapped(presentingFrom: tabs)
    }
}

extension PadSidebar: UITabBarControllerDelegate {

    func tabBarController(_ tabBarController: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?) {
        guard let tabs else { return }
        if let segment = LibraryViewModel.Segment.allCases.first(where: { Identifier.pivot($0) == selectedTab.identifier }),
           tabs.library.viewModel.currentSegment != segment {
            tabs.library.select(segment: segment)
        }
    }

    func tabBarController(
        _ tabBarController: UITabBarController, tab: UITab, operationForAcceptingItemsFrom dropSession: UIDropSession
    ) -> UIDropOperation {
        playlistID(for: tab) != nil && TrackDrag.carriesTracks(dropSession) ? .copy : .cancel
    }

    /// Songs dropped on a playlist in the sidebar join the end of it.
    func tabBarController(_ tabBarController: UITabBarController, tab: UITab, acceptItemsFrom dropSession: UIDropSession) {
        guard let id = playlistID(for: tab) else { return }
        TrackDrag.add(TrackDrag.tracks(in: dropSession), toPlaylist: id, named: tab.title, in: tabs?.view)
    }

    /// The four pivots are one Library screen showing different segments, so
    /// each of them puts that same screen at the root of the Library's stack.
    func tabBarController(
        _ tabBarController: UITabBarController,
        displayedViewControllersFor tab: UITab,
        proposedViewControllers: [UIViewController]
    ) -> [UIViewController] {
        guard let tabs else { return proposedViewControllers }
        if tab.parent === libraryGroup || tab === libraryGroup { return [tabs.library] }
        if tab.parent === playlistsGroup, let controller = tab.viewController { return [controller] }
        return proposedViewControllers
    }
}

extension PadSidebar: UITabBarController.Sidebar.Delegate {

    func tabBarController(
        _ tabBarController: UITabBarController,
        sidebarVisibilityWillChange sidebar: UITabBarController.Sidebar,
        animator: any UITabBarController.Sidebar.Animating
    ) {
        animator.addAnimations { [weak self] in self?.notifyPivotPlacement() }
        animator.addCompletion { [weak self] in self?.notifyPivotPlacement() }
    }

    @available(iOS 27.0, *)
    func tabBarController(_ tabBarController: UITabBarController, sidebarAvailabilityDidChange sidebar: UITabBarController.Sidebar) {
        notifyPivotPlacement()
    }
}

/// UIKit requires every root tab to own a view controller, even a section that
/// lives only in the sidebar and is never itself a destination; this is the one
/// those sections hand over, and nothing ever shows it.
private final class SidebarSectionPlaceholder: UIViewController {}

extension LibraryViewModel.Segment {

    /// The segment's name in tab identifiers, which never changes even when the
    /// case order does.
    var identifier: String {
        switch self {
        case .albums: "albums"
        case .songs: "songs"
        case .artists: "artists"
        case .playlists: "playlists"
        }
    }

    var title: String {
        switch self {
        case .albums: String(localized: "Albums")
        case .songs: String(localized: "Songs")
        case .artists: String(localized: "Artists")
        case .playlists: String(localized: "Playlists")
        }
    }

    var symbolName: String {
        switch self {
        case .albums: "square.grid.2x2"
        case .songs: "music.note"
        case .artists: "music.microphone"
        case .playlists: "music.note.list"
        }
    }
}
