import MidgarCore
import UIKit

/// Opens the welcome over the app on a launch that should have it, and carries out what the person picked once it closes.
@MainActor
enum WelcomeFlow {

    static func presentIfNeeded(over host: UIViewController, tabs: AppTabBarController) {
        Task { @MainActor in
            let servers = (try? await RemoteServers.shared.list().count) ?? 0
            let forced = WelcomeGate.isForced()
            guard WelcomeGate.shouldPresent(
                seen: WelcomeGate.hasBeenSeen,
                hadIndexedLibrary: LibraryStartupProbe.hadIndexedLibrary,
                serverCount: servers,
                isAutomated: WelcomeGate.isAutomatedRun(),
                forced: forced
            ) else { return }
            if !forced { WelcomeGate.markSeen() }
            present(over: host, tabs: tabs, serverStep: forced && WelcomeGate.opensOnServerStep())
        }
    }

    private static func present(over host: UIViewController, tabs: AppTabBarController, serverStep: Bool) {
        let welcome = WelcomeViewController()
        let navigation = UINavigationController(rootViewController: welcome)
        navigation.modalPresentationStyle = .fullScreen
        welcome.onChoice = { [weak host, weak tabs] choice in
            navigation.dismiss(animated: true) {
                guard let host, let tabs else { return }
                carry(out: choice, host: host, tabs: tabs)
            }
        }
        host.present(navigation, animated: false)
        if serverStep { welcome.showServerStep(animated: false) }
    }

    private static func carry(out choice: WelcomeViewController.Choice, host: UIViewController, tabs: AppTabBarController) {
        let library = tabs.library
        switch choice {
        case .importFiles:
            library.performWhenVisible { library.importTapped() }
        case .sample:
            library.performWhenVisible { library.sampleMusicTapped() }
        case .musicServer:
            AddServerViewController.present(from: host, servers: RemoteServersViewModel())
        case .notNow, .serverConnected:
            break
        }
    }
}
