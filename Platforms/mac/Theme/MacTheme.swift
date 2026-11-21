import AppKit
import FlaccyCore
import MidgarCore
import ObjectiveC

/// The theme the Mac app is wearing: which one, with which colors and
/// variant, and what the person has chosen for themselves over it. It turns
/// that into the palettes, faces and shapes the app draws with, applies them
/// to every window at once, and tells whoever lays out by the look.
///
/// Flaccy's own theme is the system's look with the system's accent, exactly
/// as before themes existed; every other theme paints its own surfaces and
/// text.
@MainActor
final class MacTheme {

    static let shared = MacTheme()

    private(set) var library: ThemeLibrary
    private(set) var wardrobe: ThemeWardrobe
    private(set) var look: ThemeLook
    private var epoch = 0
    private var setsAppearance = false
    private var watcher: ThemeFolderWatcher?

    private nonisolated(unsafe) static var backgroundKey: UInt8 = 0
    private nonisolated(unsafe) static var titlebarKey: UInt8 = 0

    /// Where the person's own themes live: a folder Finder opens from
    /// Settings.
    static var themesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("flaccy").appendingPathComponent("Themes")
    }

    private init() {
        library = ThemeLibrary(themesDirectory: MacTheme.themesDirectory)
        var stored = ThemeWardrobe(stored: UserDefaults.standard.data(forKey: ThemeWardrobe.storageKey))
        #if DEBUG
        MacTheme.applyLaunchOverride(to: &stored)
        #endif
        wardrobe = stored
        look = stored.look(in: library)
    }

    #if DEBUG
    /// `FLACCY_THEME=pack[/scheme[/variant]]` and `FLACCY_ALBUMS_VIEW` dress a
    /// debug launch without touching Settings, for captures.
    private static func applyLaunchOverride(to wardrobe: inout ThemeWardrobe) {
        let environment = ProcessInfo.processInfo.environment
        if let theme = environment["FLACCY_THEME"], !theme.isEmpty {
            let parts = theme.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            wardrobe.wear(pack: parts[0])
            if parts.count > 1 { wardrobe.wear(scheme: parts[1]) }
            if parts.count > 2 { wardrobe.wear(variant: parts[2]) }
        }
        if let view = environment["FLACCY_ALBUMS_VIEW"] { wardrobe.show(albumsAs: view) }
        if let covers = environment["FLACCY_COVERS"] { wardrobe.covers = covers }
        if let corners = environment["FLACCY_CORNERS"] { wardrobe.corners = corners }
        if let font = environment["FLACCY_FONT"] { wardrobe.font = font }
        if let glow = environment["FLACCY_GLOW"] { wardrobe.glow = glow }
    }
    #endif

    /// Whether the worn theme is Flaccy's own, whose surfaces, text and
    /// accent are the system's.
    var isSystemLook: Bool { look.pack.id == ThemeLibrary.defaultID }

    /// Whether the window washes itself in the playing cover's colors: always
    /// under Flaccy's own theme, and under another when it asks for the glow.
    var washesInArtwork: Bool { isSystemLook || look.glow }

    /// The one place the look changes: `change` rewrites what is worn or what
    /// the person chose, which is then saved and applied.
    func edit(_ change: (inout ThemeWardrobe) -> Void) {
        var next = wardrobe
        change(&next)
        guard next != wardrobe else { return }
        wardrobe = next
        UserDefaults.standard.set(next.stored, forKey: ThemeWardrobe.storageKey)
        look = next.look(in: library)
        apply()
        MidgarLog.info(
            "Theme \(look.pack.id) / \(look.wornScheme.id) / \(look.wornVariant?.id ?? "-"), albums as \(look.albums.id)",
            category: .ui
        )
    }

    /// Reads the themes folder again, for a theme added, changed or removed.
    func reloadLibrary() {
        let reloaded = ThemeLibrary(themesDirectory: MacTheme.themesDirectory)
        guard reloaded.packs != library.packs || reloaded.problems != library.problems else { return }
        library = reloaded
        look = wardrobe.look(in: library)
        apply()
        MidgarLog.info("Themes folder changed: \(reloaded.packs.count) themes, \(reloaded.problems.count) with a problem", category: .ui)
    }

    /// Copies the worn theme into the themes folder under a name of the
    /// person's own and puts the copy on, worn the way the original was, so
    /// what they change in its `theme.toml` shows as they save. Returns the
    /// copy's folder.
    func copyWornThemeToChange() throws(ThemeLibrary.CopyFailure) -> URL {
        let folder = MacTheme.themesDirectory
        let id = try library.makeEditableCopy(of: look.pack.id, in: folder)
        library = ThemeLibrary(themesDirectory: folder)
        edit { $0.wear(copyOfWorn: id) }
        return folder.appendingPathComponent(id)
    }

    /// Makes the themes folder and follows it, so a theme saved in an editor
    /// is on the window a moment later. Called once at launch.
    func start() {
        prepare()
        applyAppearance()
        let folder = MacTheme.themesDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        watcher = ThemeFolderWatcher(folder: folder) { [weak self] in self?.reloadLibrary() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowCameForward(_:)), name: NSWindow.didBecomeKeyNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowCameForward(_:)), name: NSWindow.didBecomeMainNotification, object: nil
        )
    }

    @objc private func windowCameForward(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        dress(window)
    }

    /// Hands the look to everything that draws with it.
    private func prepare() {
        epoch += 1
        if isSystemLook {
            ThemePalettes.wear(dark: nil, light: nil)
        } else {
            ThemePalettes.wear(dark: look.palette(dark: true), light: look.palette(dark: false))
        }
        let faces = MacThemeTypography.faces(for: look)
        ThemeShape.wear(look)
        let shaped = look.corners != ThemePack.cornersStandard || look.covers != .rounded || !look.shadows
        MacThemeHooks.wear(dressing: !isSystemLook || !faces.isSystem || shaped, faces: faces, epoch: epoch)
    }

    /// Holds the app in the mode a theme is drawn for, and lets the system
    /// decide again once no theme insists.
    private func applyAppearance() {
        switch look.appearance {
        case .dark: hold(NSAppearance(named: .darkAqua))
        case .light: hold(NSAppearance(named: .aqua))
        case .any:
            guard setsAppearance else { return }
            hold(nil)
        }
    }

    /// Puts the whole app in `appearance`, or back in the system's for nil.
    /// A color read outside a drawing pass (a layer's color set as a view is
    /// built) resolves against the thread's current appearance, which stays
    /// the system's whatever the app is held in, so that is held too; the
    /// setter is reached by name because Swift marks it deprecated in favor
    /// of a scoped call that cannot cover code that runs later.
    private func hold(_ appearance: NSAppearance?) {
        NSApp.appearance = appearance
        setsAppearance = appearance != nil
        let setter = NSSelectorFromString("setCurrentAppearance:")
        let type: AnyObject = NSAppearance.self
        if type.responds(to: setter) { _ = type.perform(setter, with: appearance) }
    }

    /// Gives a window the theme's background where it still has the system's
    /// own. A window that painted itself (the equalizer's black, Now Playing)
    /// keeps what it chose.
    func dress(_ window: NSWindow) {
        guard ThemePalettes.hasPainted, !(window is NSPanel && window.styleMask.contains(.nonactivatingPanel)) else { return }
        let last = objc_getAssociatedObject(window, &MacTheme.backgroundKey) as? NSColor
        guard window.backgroundColor == NSColor.windowBackgroundColor || window.backgroundColor === last else { return }
        let background = MacThemedColor.windowBackground.fresh()
        objc_setAssociatedObject(window, &MacTheme.backgroundKey, background, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        window.backgroundColor = background
        dressTitlebar(of: window)
    }

    /// Lets the theme's own color show under the toolbar of a window whose
    /// content runs to the top, where the system draws a material of its own,
    /// and gives the system's back once no theme paints.
    private func dressTitlebar(of window: NSWindow) {
        guard window.toolbar != nil, window.styleMask.contains(.fullSizeContentView) else { return }
        let own = objc_getAssociatedObject(window, &MacTheme.titlebarKey) as? Bool
        if ThemePalettes.isPainting {
            if own == nil {
                objc_setAssociatedObject(
                    window, &MacTheme.titlebarKey, window.titlebarAppearsTransparent, .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                )
            }
            window.titlebarAppearsTransparent = true
        } else if let own {
            window.titlebarAppearsTransparent = own
            objc_setAssociatedObject(window, &MacTheme.titlebarKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    /// Applies the look to every window.
    func apply() {
        prepare()
        applyAppearance()
        let windows = NSApp.windows
        windows.forEach(dress)
        MacThemeHooks.dressEverything(in: windows)
        NotificationCenter.default.post(name: WornTheme.didChange, object: nil)
    }
}

/// Watches the themes folder and everything in it, and says so on the main
/// actor a moment after anything changed.
@MainActor
final class ThemeFolderWatcher {

    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(folder: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            nil, themeFolderChanged, &context, [folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    fileprivate func changed() {
        onChange()
    }

    isolated deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

/// The file system's callback for the themes folder, delivered on the main
/// queue the stream was given.
private nonisolated func themeFolderChanged(
    _ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?, _ count: Int, _ paths: UnsafeMutableRawPointer,
    _ flags: UnsafePointer<FSEventStreamEventFlags>, _ ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let address = UInt(bitPattern: info)
    MainActor.assumeIsolated {
        guard let pointer = UnsafeRawPointer(bitPattern: address) else { return }
        Unmanaged<ThemeFolderWatcher>.fromOpaque(pointer).takeUnretainedValue().changed()
    }
}
