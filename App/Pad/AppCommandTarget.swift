import FlaccyCore
import MidgarCore
import UIKit

/// What the menu bar and keyboard shortcuts act on: the tabs, the player and
/// the root of the window in front. Each scene makes one and hands it the
/// stage when it becomes active.
final class AppCommandTarget {

    private(set) static weak var current: AppCommandTarget?

    private weak var window: UIWindow?
    private weak var tabs: AppTabBarController?
    private weak var player: PlayerContainerViewController?
    private weak var root: RootContainerViewController?

    init(window: UIWindow, tabs: AppTabBarController, player: PlayerContainerViewController, root: RootContainerViewController) {
        self.window = window
        self.tabs = tabs
        self.player = player
        self.root = root
    }

    func becomeCurrent() {
        Self.current = self
    }

    private var hasTrack: Bool { AudioPlayer.shared.currentTrack != nil }

    private var presenter: UIViewController? {
        TrialRunwayPresenter.topmostViewController(in: window)
    }

    /// Whether `action` means something right now; the menu dims it otherwise
    /// and its shortcut does nothing.
    func canPerform(_ action: Selector) -> Bool {
        switch action {
        case #selector(AppDelegate.flaccyTogglePlayPause(_:)), #selector(AppDelegate.flaccyNextTrack(_:)),
             #selector(AppDelegate.flaccyPreviousTrack(_:)), #selector(AppDelegate.flaccyToggleLove(_:)),
             #selector(AppDelegate.flaccySongLouder(_:)), #selector(AppDelegate.flaccySongQuieter(_:)):
            return hasTrack
        case #selector(AppDelegate.flaccyShowSongVolume(_:)), #selector(AppDelegate.flaccyToggleLyrics(_:)),
             #selector(AppDelegate.flaccyToggleNowPlaying(_:)):
            return hasTrack && !isPresenting
        case #selector(AppDelegate.flaccyTogglePlayerColumn(_:)):
            return root?.canShowPlayerColumn == true && !isPresenting
        case #selector(AppDelegate.flaccyFind(_:)), #selector(AppDelegate.flaccyShowHome(_:)),
             #selector(AppDelegate.flaccyShowRecap(_:)), #selector(AppDelegate.flaccyShowAlbums(_:)),
             #selector(AppDelegate.flaccyShowSongs(_:)), #selector(AppDelegate.flaccyShowArtists(_:)),
             #selector(AppDelegate.flaccyShowPlaylists(_:)), #selector(AppDelegate.flaccyImportFiles(_:)),
             #selector(AppDelegate.flaccyShowSettings(_:)), #selector(AppDelegate.flaccyNewPlaylist(_:)),
             #selector(AppDelegate.flaccyShowEqualizer(_:)), #selector(AppDelegate.flaccyToggleQueue(_:)):
            return !isPresenting
        default:
            return true
        }
    }

    /// True while a sheet or full-screen flow is up: commands that present
    /// something or move the window underneath wait until it is dismissed;
    /// playback keeps answering.
    private var isPresenting: Bool {
        window?.rootViewController?.presentedViewController != nil
    }

    /// Whether `action` is a setting that is on now, shown as a checkmark.
    func isOn(_ action: Selector) -> Bool {
        let player = AudioPlayer.shared
        switch action {
        case #selector(AppDelegate.flaccyToggleShuffle(_:)): return player.shuffleEnabled
        case #selector(AppDelegate.flaccyCycleRepeat(_:)): return player.repeatMode != .off
        case #selector(AppDelegate.flaccyToggleLove(_:)):
            return player.currentTrack.map { LovedTracksService.shared.isLoved(track: $0) } ?? false
        case #selector(AppDelegate.flaccyTogglePlayerColumn(_:)):
            return root?.canShowPlayerColumn == true && PlayerColumnSetting.isShown
        default: return false
        }
    }

    func showSettings() {
        guard let tabs, let presenter else { return }
        presenter.present(SettingsViewController.makePresented(library: tabs.library), animated: true)
    }

    func importFiles() {
        guard let library = tabs?.library else { return }
        library.performWhenVisible { library.importTapped() }
    }

    func newPlaylist() {
        guard let tabs, let presenter else { return }
        tabs.library.createPlaylistTapped(presentingFrom: presenter)
    }

    func find() {
        player?.collapseIfExpanded()
        tabs?.show(.search)
        tabs?.search.focusSearchField()
    }

    func show(_ destination: AppTabBarController.Destination) {
        player?.collapseIfExpanded()
        UISelectionFeedbackGenerator().selectionChanged()
        tabs?.show(destination)
    }

    func showLibrary(_ segment: LibraryViewModel.Segment) {
        player?.collapseIfExpanded()
        UISelectionFeedbackGenerator().selectionChanged()
        tabs?.showLibrary(segment)
    }

    func toggleQueue() {
        player?.toggleCenterState(.queue)
    }

    func toggleLyrics() {
        player?.toggleCenterState(.lyrics)
    }

    func toggleNowPlaying() {
        player?.toggleFullPlayer()
    }

    func togglePlayerColumn() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        PlayerColumnSetting.setShown(!PlayerColumnSetting.isShown)
    }

    func togglePlayPause() {
        AudioPlayer.shared.togglePlayPause()
    }

    func nextTrack() {
        AudioPlayer.shared.nextTrack()
    }

    func previousTrack() {
        AudioPlayer.shared.previousTrack()
    }

    func toggleShuffle() {
        AudioPlayer.shared.toggleShuffle()
    }

    func cycleRepeat() {
        AudioPlayer.shared.cycleRepeatMode()
    }

    func toggleLove() {
        player?.toggleLoveForPlayingSong()
    }

    func showEqualizer() {
        guard let presenter else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        presenter.present(EqualizerViewController.makePresented(), animated: true)
    }

    func showSongVolume() {
        guard let track = AudioPlayer.shared.currentTrack, let presenter else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        presenter.present(SongVolumeViewController.makePresented(for: track), animated: true)
    }

    /// Moves the playing song's own level one step and says where it landed,
    /// as the Mac does for ⇧⌘↑ and ⇧⌘↓.
    func nudgeSongVolume(by steps: Int) {
        guard let track = AudioPlayer.shared.currentTrack, let view = presenter?.view else { return }
        let store = SongVolumeStore.shared
        do {
            let level = try store.set(SongGain.stepped(store.level(for: track), by: steps), for: track)
            UISelectionFeedbackGenerator().selectionChanged()
            ToastView.show("\(SongVolumeCopy.title) \(SongVolumeCopy.level(level)) · \(track.title)", in: view)
        } catch {
            MidgarLog.error("Song volume nudge failed: \(error.localizedDescription)", category: .playback)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            ToastView.show(SongVolumeCopy.saveFailed(title: track.title), in: view, style: .error)
        }
    }
}
