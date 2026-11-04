import FlaccyCore
import UIKit

/// The iPad's menu bar, and the shortcuts a hardware keyboard reaches on any
/// device, mirroring the Mac's menus: Settings, Import Files and New Playlist,
/// Find, the Library's views and Now Playing, and a Playback menu. Every item
/// lands on `AppDelegate`, the end of the responder chain, and runs against
/// the window in front through `AppCommandTarget`.
enum AppCommands {

    struct Item {
        let title: String
        let action: Selector
        let input: String?
        let modifiers: UIKeyModifierFlags

        init(_ title: String, _ action: Selector, input: String? = nil, modifiers: UIKeyModifierFlags = .command) {
            self.title = title
            self.action = action
            self.input = input
            self.modifiers = modifiers
        }

        var element: UIMenuElement {
            guard let input else { return UICommand(title: title, action: action) }
            return UIKeyCommand(title: title, action: action, input: input, modifierFlags: modifiers)
        }
    }

    static let settings = Item(String(localized: "Settings…"), #selector(AppDelegate.flaccyShowSettings(_:)), input: ",")

    static let file = [
        Item(String(localized: "Import Files…"), #selector(AppDelegate.flaccyImportFiles(_:)), input: "o"),
        Item(String(localized: "New Playlist"), #selector(AppDelegate.flaccyNewPlaylist(_:)), input: "n"),
    ]

    static let find = Item(String(localized: "Find"), #selector(AppDelegate.flaccyFind(_:)), input: "f")

    static let destinations = [
        Item(HomeCopy.home, #selector(AppDelegate.flaccyShowHome(_:)), input: "1"),
        Item(String(localized: "Albums"), #selector(AppDelegate.flaccyShowAlbums(_:)), input: "2"),
        Item(String(localized: "Songs"), #selector(AppDelegate.flaccyShowSongs(_:)), input: "3"),
        Item(String(localized: "Artists"), #selector(AppDelegate.flaccyShowArtists(_:)), input: "4"),
        Item(String(localized: "Playlists"), #selector(AppDelegate.flaccyShowPlaylists(_:)), input: "5"),
        Item(String(localized: "Recap"), #selector(AppDelegate.flaccyShowRecap(_:)), input: "6"),
    ]

    static let nowPlaying = [
        Item(String(localized: "Toggle Queue"), #selector(AppDelegate.flaccyToggleQueue(_:)), input: "k"),
        Item(String(localized: "Toggle Lyrics"), #selector(AppDelegate.flaccyToggleLyrics(_:)), input: "l", modifiers: [.command, .shift]),
        Item(String(localized: "Now Playing"), #selector(AppDelegate.flaccyToggleNowPlaying(_:)), input: "f", modifiers: [.command, .shift]),
        Item(String(localized: "Now Playing Column"), #selector(AppDelegate.flaccyTogglePlayerColumn(_:)), input: "0", modifiers: [.command, .alternate]),
    ]

    static let transport = [
        Item(String(localized: "Play/Pause"), #selector(AppDelegate.flaccyTogglePlayPause(_:)), input: " ", modifiers: []),
        Item(String(localized: "Next Track"), #selector(AppDelegate.flaccyNextTrack(_:)), input: UIKeyCommand.inputRightArrow),
        Item(String(localized: "Previous Track"), #selector(AppDelegate.flaccyPreviousTrack(_:)), input: UIKeyCommand.inputLeftArrow),
    ]

    static let modes = [
        Item(String(localized: "Toggle Shuffle"), #selector(AppDelegate.flaccyToggleShuffle(_:))),
        Item(String(localized: "Cycle Repeat Mode"), #selector(AppDelegate.flaccyCycleRepeat(_:))),
    ]

    static let song = [
        Item(String(localized: "Love Track"), #selector(AppDelegate.flaccyToggleLove(_:)), input: "l"),
        Item(String(localized: "Equalizer"), #selector(AppDelegate.flaccyShowEqualizer(_:)), input: "e", modifiers: [.command, .alternate]),
    ]

    static let songVolume = [
        Item(SongVolumeCopy.menuTitle, #selector(AppDelegate.flaccyShowSongVolume(_:))),
        Item(SongVolumeCopy.songLouder, #selector(AppDelegate.flaccySongLouder(_:)), input: UIKeyCommand.inputUpArrow, modifiers: [.command, .shift]),
        Item(SongVolumeCopy.songQuieter, #selector(AppDelegate.flaccySongQuieter(_:)), input: UIKeyCommand.inputDownArrow, modifiers: [.command, .shift]),
    ]

    static var all: [Item] {
        [settings, find] + file + destinations + nowPlaying + transport + modes + song + songVolume
    }

    /// Keeps the system's sidebar toggle and drops the standard groups Flaccy
    /// has nothing behind: new windows, documents, printing, its own find
    /// panel, toolbars, inspectors and text formatting.
    static func configureMainMenu() {
        guard #available(iOS 26.0, *) else { return }
        let configuration = UIMainMenuSystem.Configuration()
        configuration.newScenePreference = .removed
        configuration.documentPreference = .removed
        configuration.printingPreference = .removed
        configuration.findingPreference = .removed
        configuration.toolbarPreference = .removed
        configuration.inspectorPreference = .removed
        configuration.textFormattingPreference = .removed
        configuration.sidebarPreference = .included
        UIMainMenuSystem.shared.setBuildConfiguration(configuration)
    }

    static func build(into builder: UIMenuBuilder) {
        guard builder.system == .main else { return }
        let settingsMenu = UIMenu(options: .displayInline, children: [settings.element])
        if builder.menu(for: .preferences) != nil {
            builder.replace(menu: .preferences, with: settingsMenu)
        } else if builder.menu(for: .about) != nil {
            builder.insertSibling(settingsMenu, afterMenu: .about)
        }
        if builder.menu(for: .file) != nil {
            builder.insertChild(inline(file), atStartOfMenu: .file)
        }
        if builder.menu(for: .edit) != nil {
            builder.insertChild(inline([find]), atEndOfMenu: .edit)
        }
        let playback = UIMenu(
            title: String(localized: "Playback"),
            identifier: UIMenu.Identifier("com.midgarcorp.flaccy.playback"),
            children: [inline(transport), inline(modes), inline(song), inline(songVolume)]
        )
        if builder.menu(for: .view) != nil {
            builder.insertChild(inline(nowPlaying), atStartOfMenu: .view)
            builder.insertChild(inline(destinations), atStartOfMenu: .view)
            builder.insertSibling(playback, afterMenu: .view)
        } else {
            builder.insertSibling(playback, afterMenu: .application)
        }
    }

    private static func inline(_ items: [Item]) -> UIMenu {
        UIMenu(options: .displayInline, children: items.map(\.element))
    }
}

extension AppDelegate {

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        AppCommands.build(into: builder)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard AppCommands.all.contains(where: { $0.action == action }) else {
            return super.canPerformAction(action, withSender: sender)
        }
        return AppCommandTarget.current?.canPerform(action) ?? false
    }

    override func validate(_ command: UICommand) {
        super.validate(command)
        guard AppCommands.all.contains(where: { $0.action == command.action }) else { return }
        command.state = AppCommandTarget.current?.isOn(command.action) == true ? .on : .off
    }

    @objc func flaccyShowSettings(_ sender: Any?) { AppCommandTarget.current?.showSettings() }
    @objc func flaccyImportFiles(_ sender: Any?) { AppCommandTarget.current?.importFiles() }
    @objc func flaccyNewPlaylist(_ sender: Any?) { AppCommandTarget.current?.newPlaylist() }
    @objc func flaccyFind(_ sender: Any?) { AppCommandTarget.current?.find() }
    @objc func flaccyShowHome(_ sender: Any?) { AppCommandTarget.current?.show(.home) }
    @objc func flaccyShowRecap(_ sender: Any?) { AppCommandTarget.current?.show(.recap) }
    @objc func flaccyShowAlbums(_ sender: Any?) { AppCommandTarget.current?.showLibrary(.albums) }
    @objc func flaccyShowSongs(_ sender: Any?) { AppCommandTarget.current?.showLibrary(.songs) }
    @objc func flaccyShowArtists(_ sender: Any?) { AppCommandTarget.current?.showLibrary(.artists) }
    @objc func flaccyShowPlaylists(_ sender: Any?) { AppCommandTarget.current?.showLibrary(.playlists) }
    @objc func flaccyToggleQueue(_ sender: Any?) { AppCommandTarget.current?.toggleQueue() }
    @objc func flaccyToggleLyrics(_ sender: Any?) { AppCommandTarget.current?.toggleLyrics() }
    @objc func flaccyToggleNowPlaying(_ sender: Any?) { AppCommandTarget.current?.toggleNowPlaying() }
    @objc func flaccyTogglePlayerColumn(_ sender: Any?) { AppCommandTarget.current?.togglePlayerColumn() }
    @objc func flaccyTogglePlayPause(_ sender: Any?) { AppCommandTarget.current?.togglePlayPause() }
    @objc func flaccyNextTrack(_ sender: Any?) { AppCommandTarget.current?.nextTrack() }
    @objc func flaccyPreviousTrack(_ sender: Any?) { AppCommandTarget.current?.previousTrack() }
    @objc func flaccyToggleShuffle(_ sender: Any?) { AppCommandTarget.current?.toggleShuffle() }
    @objc func flaccyCycleRepeat(_ sender: Any?) { AppCommandTarget.current?.cycleRepeat() }
    @objc func flaccyToggleLove(_ sender: Any?) { AppCommandTarget.current?.toggleLove() }
    @objc func flaccyShowEqualizer(_ sender: Any?) { AppCommandTarget.current?.showEqualizer() }
    @objc func flaccyShowSongVolume(_ sender: Any?) { AppCommandTarget.current?.showSongVolume() }
    @objc func flaccySongLouder(_ sender: Any?) { AppCommandTarget.current?.nudgeSongVolume(by: 1) }
    @objc func flaccySongQuieter(_ sender: Any?) { AppCommandTarget.current?.nudgeSongVolume(by: -1) }
}
