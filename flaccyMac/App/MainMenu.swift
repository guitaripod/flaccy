import AppKit

/// Builds the full menu bar with the app's keyboard map. Playback and file
/// actions dispatch through the responder chain to `MacAppDelegate`; view
/// items post section/panel notifications the window shell observes.
enum MainMenu {

    static func build() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(fileMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(playbackMenuItem())
        mainMenu.addItem(viewMenuItem())
        mainMenu.addItem(windowMenuItem())
        mainMenu.addItem(helpMenuItem())
        return mainMenu
    }

    private static func appMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Flaccy")
        menu.addItem(withTitle: "About Flaccy", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(MacAppDelegate.showSettings(_:)), keyEquivalent: ",")
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = menu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Flaccy", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Flaccy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return submenuItem(menu)
    }

    private static func fileMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "File")
        let choose = menu.addItem(
            withTitle: "Choose Music Folder…",
            action: #selector(MacAppDelegate.chooseMusicFolder(_:)),
            keyEquivalent: "O"
        )
        choose.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: "Import Files…", action: #selector(MacAppDelegate.importFiles(_:)), keyEquivalent: "o")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Library in Finder", action: #selector(MacAppDelegate.revealLibraryFolder(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Clean Up Library…", action: #selector(MacAppDelegate.cleanUpLibrary(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        return submenuItem(menu)
    }

    private static func editMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Find", action: #selector(MacAppDelegate.focusSearch(_:)), keyEquivalent: "f")
        return submenuItem(menu)
    }

    private static func playbackMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Playback")
        menu.addItem(withTitle: "Play/Pause", action: #selector(MacAppDelegate.togglePlayPause(_:)), keyEquivalent: "")
        let next = menu.addItem(withTitle: "Next Track", action: #selector(MacAppDelegate.nextTrack(_:)), keyEquivalent: rightArrowKey)
        next.keyEquivalentModifierMask = [.command]
        let previous = menu.addItem(withTitle: "Previous Track", action: #selector(MacAppDelegate.previousTrack(_:)), keyEquivalent: leftArrowKey)
        previous.keyEquivalentModifierMask = [.command]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Toggle Shuffle", action: #selector(MacAppDelegate.toggleShuffle(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Cycle Repeat Mode", action: #selector(MacAppDelegate.cycleRepeatMode(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Love Track", action: #selector(MacAppDelegate.toggleLove(_:)), keyEquivalent: "l")
        menu.addItem(.separator())
        let volumeUp = menu.addItem(withTitle: "Increase Volume", action: #selector(MacAppDelegate.increaseVolume(_:)), keyEquivalent: upArrowKey)
        volumeUp.keyEquivalentModifierMask = [.command]
        let volumeDown = menu.addItem(withTitle: "Decrease Volume", action: #selector(MacAppDelegate.decreaseVolume(_:)), keyEquivalent: downArrowKey)
        volumeDown.keyEquivalentModifierMask = [.command]
        return submenuItem(menu)
    }

    private static func viewMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "View")
        let sections: [(SidebarSection, String)] = [
            (.albums, "1"), (.songs, "2"), (.artists, "3"), (.playlists, "4"),
        ]
        for (section, key) in sections {
            let item = menu.addItem(
                withTitle: section.title,
                action: #selector(MacAppDelegate.showSection(_:)),
                keyEquivalent: key
            )
            item.tag = section.rawValue
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Toggle Queue", action: #selector(MacAppDelegate.toggleQueue(_:)), keyEquivalent: "k")
        let lyrics = menu.addItem(withTitle: "Toggle Lyrics", action: #selector(MacAppDelegate.toggleLyrics(_:)), keyEquivalent: "L")
        lyrics.keyEquivalentModifierMask = [.command, .shift]
        let nowPlaying = menu.addItem(withTitle: "Now Playing", action: #selector(MacAppDelegate.toggleNowPlaying(_:)), keyEquivalent: "F")
        nowPlaying.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .control]
        return submenuItem(menu)
    }

    private static func windowMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = menu
        return submenuItem(menu)
    }

    private static func helpMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Help")
        menu.addItem(withTitle: "Flaccy Help", action: #selector(NSApplication.showHelp(_:)), keyEquivalent: "?")
        NSApp.helpMenu = menu
        return submenuItem(menu)
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static var rightArrowKey: String { functionKey(NSRightArrowFunctionKey) }
    private static var leftArrowKey: String { functionKey(NSLeftArrowFunctionKey) }
    private static var upArrowKey: String { functionKey(NSUpArrowFunctionKey) }
    private static var downArrowKey: String { functionKey(NSDownArrowFunctionKey) }

    private static func functionKey(_ code: Int) -> String {
        UnicodeScalar(UInt16(code)).map { String(Character($0)) } ?? ""
    }
}
