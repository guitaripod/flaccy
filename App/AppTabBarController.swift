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
        guard #available(iOS 26.0, *) else { return }
        guard let track else {
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

    /// Where the floating dock may rest on iOS 18 to 25: just above the tab bar.
    func tabBarTop(in space: UIView) -> CGFloat {
        tabBar.convert(tabBar.bounds, to: space).minY
    }
}
