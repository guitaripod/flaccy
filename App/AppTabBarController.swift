import FlaccyCore
import MidgarCore
import UIKit

/// The iPhone's root navigation: Home, Library, Recap and Search, with the
/// mini player riding above the tab bar. Every screen that used to push onto
/// the Library's stack now pushes onto the stack of whichever tab is selected.
final class AppTabBarController: UITabBarController {

    enum Destination: String, CaseIterable {
        case home
        case library
        case recap
        case search
    }

    let library = LibraryViewController()
    let home: HomeViewController
    let recapController = ChartsViewController()
    let search: SearchViewController

    let homeNavigation: UINavigationController
    let libraryNavigation: UINavigationController
    let recapNavigation: UINavigationController
    let searchNavigation: UINavigationController

    var onMiniPlayerTap: (() -> Void)?

    /// True while the window is split and Now Playing is a pane of its own, so
    /// a second mini player in the tab accessory would only repeat it.
    var suppressesMiniPlayer = false {
        didSet {
            guard suppressesMiniPlayer != oldValue else { return }
            updateMiniPlayer(track: lastMiniPlayerTrack, isPlaying: lastMiniPlayerIsPlaying)
        }
    }

    private var lastMiniPlayerTrack: Track?
    private var lastMiniPlayerIsPlaying = false

    private var tabsByDestination: [Destination: UITab] = [:]

    private lazy var accessoryMiniPlayer: MiniPlayerView = {
        let mini = MiniPlayerView()
        mini.style = .accessory
        mini.onTap = { [weak self] in self?.onMiniPlayerTap?() }
        return mini
    }()

    init() {
        home = HomeViewController(libraryViewModel: library.viewModel, library: library)
        search = SearchViewController(libraryViewModel: library.viewModel)
        homeNavigation = UINavigationController(rootViewController: home)
        libraryNavigation = UINavigationController(rootViewController: library)
        recapNavigation = UINavigationController(rootViewController: recapController)
        searchNavigation = UINavigationController(rootViewController: search)
        super.init(nibName: nil, bundle: nil)

        homeNavigation.navigationBar.prefersLargeTitles = true
        libraryNavigation.navigationBar.prefersLargeTitles = false
        recapNavigation.navigationBar.prefersLargeTitles = false
        searchNavigation.navigationBar.prefersLargeTitles = true
        home.tabController = self
        configureTabs()
        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior = .onScrollDown
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        library.loadViewIfNeeded()
    }

    private func configureTabs() {
        mode = .tabBar
        let homeTab = UITab(
            title: HomeCopy.home, image: UIImage(systemName: "house.fill"), identifier: Destination.home.rawValue
        ) { [homeNavigation] _ in homeNavigation }
        let libraryTab = UITab(
            title: String(localized: "Library"), image: UIImage(systemName: "square.stack.fill"),
            identifier: Destination.library.rawValue
        ) { [libraryNavigation] _ in libraryNavigation }
        let recapTab = UITab(
            title: String(localized: "Recap"), image: UIImage(systemName: "chart.bar.xaxis"),
            identifier: Destination.recap.rawValue
        ) { [recapNavigation] _ in recapNavigation }
        let searchTab = UISearchTab { [searchNavigation] _ in searchNavigation }
        tabsByDestination = [.home: homeTab, .library: libraryTab, .recap: recapTab, .search: searchTab]
        tabs = [homeTab, libraryTab, recapTab, searchTab]
        selectedTab = homeTab
    }

    var selectedNavigation: UINavigationController {
        selectedViewController as? UINavigationController ?? libraryNavigation
    }

    func show(_ destination: Destination) {
        guard let tab = tabsByDestination[destination] else { return }
        selectedTab = tab
    }

    /// Pushes onto the selected tab's stack, the one place any screen that
    /// came from somewhere without a navigation controller lands.
    func pushOnSelected(_ viewController: UIViewController) {
        selectedNavigation.pushViewController(viewController, animated: true)
    }

    /// Opens the Library with its Recently Added pivot, from Home's "See All".
    func showRecentlyAddedInLibrary() {
        show(.library)
        library.showRecentlyAdded()
    }

    /// Shows or removes the mini player in the system's tab accessory. Before
    /// iOS 26 the player container's own floating dock does this job.
    func updateMiniPlayer(track: Track?, isPlaying: Bool) {
        lastMiniPlayerTrack = track
        lastMiniPlayerIsPlaying = isPlaying
        guard #available(iOS 26.0, *) else { return }
        guard let track, !suppressesMiniPlayer else {
            if bottomAccessory != nil { setBottomAccessory(nil, animated: true) }
            return
        }
        accessoryMiniPlayer.configure(with: track, isPlaying: isPlaying)
        if bottomAccessory == nil {
            setBottomAccessory(UITabAccessory(contentView: accessoryMiniPlayer), animated: true)
        }
    }

    /// The accessory's frame in `space`, or nil when there is none on screen.
    func accessoryFrame(in space: UIView) -> CGRect? {
        guard #available(iOS 26.0, *), let accessory = bottomAccessory else { return nil }
        let content = accessory.contentView
        guard content.window != nil, content.bounds.height > 0 else { return nil }
        return content.convert(content.bounds, to: space)
    }

    func setAccessoryHandedOff(_ handedOff: Bool) {
        accessoryMiniPlayer.alpha = handedOff ? 0 : 1
    }

    /// What the tab bar takes from `space`'s edges, wherever it sits: its height
    /// along the bottom, its width down a side. Nothing while it is hidden or
    /// has not been laid out. Used by the floating dock before iOS 26.
    func barObstruction(in space: UIView, safeArea: UIEdgeInsets) -> UIEdgeInsets {
        guard !tabBar.isHidden, tabBar.window != nil, tabBar.bounds.width > 0 else { return .zero }
        let frame = tabBar.convert(tabBar.bounds, to: space)
        let bounds = space.bounds
        guard frame.height <= frame.width else {
            if frame.midX < bounds.midX { return UIEdgeInsets(top: 0, left: max(frame.maxX, 0), bottom: 0, right: 0) }
            return UIEdgeInsets(top: 0, left: 0, bottom: 0, right: max(bounds.maxX - frame.minX, 0))
        }
        guard frame.midY > bounds.midY else { return .zero }
        return UIEdgeInsets(top: 0, left: 0, bottom: max(bounds.maxY - frame.minY - safeArea.bottom, 0), right: 0)
    }
}
