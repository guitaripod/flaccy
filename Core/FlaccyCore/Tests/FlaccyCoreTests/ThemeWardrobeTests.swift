import XCTest
@testable import FlaccyCore

/// The same rules as the Linux client's `ui/look.rs` tests.
final class ThemeWardrobeTests: XCTestCase {

    func testAThemeIsRememberedAsItWasLeft() {
        var wardrobe = ThemeWardrobe()
        XCTAssertEqual(wardrobe.wornPackID, "flaccy")
        XCTAssertEqual(wardrobe.remembered("phosphor"), ThemeWardrobe.Worn())

        wardrobe.wear(scheme: "aurora")
        wardrobe.show(albumsAs: "wall")
        wardrobe.wear(pack: "phosphor")
        XCTAssertEqual(wardrobe.scheme, "")
        XCTAssertEqual(wardrobe.albumsView, "")
        wardrobe.wear(scheme: "amber")
        wardrobe.wear(variant: "grid")

        XCTAssertEqual(wardrobe.remembered("flaccy"), .init(scheme: "aurora", variant: "", view: "wall"))
        XCTAssertEqual(wardrobe.remembered("phosphor"), .init(scheme: "amber", variant: "grid", view: ""))

        wardrobe.wear(pack: "flaccy")
        XCTAssertEqual(wardrobe.scheme, "aurora")
        XCTAssertEqual(wardrobe.albumsView, "wall")
        wardrobe.wear(pack: "phosphor")
        XCTAssertEqual(wardrobe.choice, .init(pack: "phosphor", scheme: "amber", variant: "grid"))
    }

    func testAVariantBringsItsOwnViewBack() {
        var wardrobe = ThemeWardrobe()
        wardrobe.wear(pack: "marquee")
        wardrobe.show(albumsAs: "list")
        XCTAssertEqual(wardrobe.look(in: ThemeLibrary()).albums, .list)
        wardrobe.wear(variant: "grid")
        XCTAssertEqual(wardrobe.albumsView, "")
        XCTAssertEqual(wardrobe.look(in: ThemeLibrary()).albums, .grid)
    }

    func testThePersonsOwnChoicesLieOverAnyThemeAndReset() {
        var wardrobe = ThemeWardrobe()
        XCTAssertFalse(wardrobe.hasOwnChoices)
        wardrobe.covers = "circle"
        wardrobe.corners = "sharp"
        wardrobe.font = " Charter "
        wardrobe.glow = "off"
        wardrobe.coverSize = 999
        XCTAssertTrue(wardrobe.hasOwnChoices)
        wardrobe.wear(pack: "liner-notes")
        let look = wardrobe.look(in: ThemeLibrary())
        XCTAssertEqual(look.covers, .circle)
        XCTAssertEqual(look.corners, ThemePack.cornersSharp)
        XCTAssertEqual(look.interfaceFont, "Charter")
        XCTAssertEqual(look.coverSize, ThemePack.coverSizeMax)
        XCTAssertFalse(look.glow)
        wardrobe.resetOwnChoices()
        XCTAssertFalse(wardrobe.hasOwnChoices)
        XCTAssertEqual(wardrobe.look(in: ThemeLibrary()).covers, .rounded)
        XCTAssertEqual(wardrobe.wornPackID, "liner-notes")
    }

    func testItSurvivesStorageAndReadsWhatAnOlderBuildWrote() throws {
        var wardrobe = ThemeWardrobe()
        wardrobe.wear(pack: "phosphor")
        wardrobe.wear(scheme: "amber")
        XCTAssertEqual(ThemeWardrobe(stored: wardrobe.stored), wardrobe)
        XCTAssertEqual(ThemeWardrobe(stored: nil), ThemeWardrobe())
        XCTAssertEqual(ThemeWardrobe(stored: Data("not json".utf8)), ThemeWardrobe())
        let partial = ThemeWardrobe(stored: Data(#"{"pack":"gallery"}"#.utf8))
        XCTAssertEqual(partial.wornPackID, "gallery")
        XCTAssertEqual(partial.memory, [:])
    }

    func testAThemeThatIsGoneWearsFlaccysOwn() {
        var wardrobe = ThemeWardrobe()
        wardrobe.wear(pack: "deleted-folder")
        XCTAssertEqual(wardrobe.look(in: ThemeLibrary()).pack.id, ThemeLibrary.defaultID)
    }
}

final class ThemeSurfaceTests: XCTestCase {

    func testEveryBuiltinKeepsItsTextReadableOnEverySurface() {
        for pack in ThemeLibrary.builtin {
            for scheme in pack.schemes {
                let look = ThemeLook(pack: pack, choice: .init(pack: pack.id, scheme: scheme.id))
                let modes: [Bool] = look.appearance == .dark ? [true] : (look.appearance == .light ? [false] : [true, false])
                for dark in modes {
                    let palette = look.palette(dark: dark)
                    let label = palette.ink(for: .label).color
                    for surface in [ThemeSurface.background, .groupedBackground, .card, .raisedCard, .bar, .sidebar] {
                        let contrast = label.contrast(with: palette.ink(for: surface).color)
                        XCTAssertGreaterThanOrEqual(contrast, 7.0, "\(pack.id)/\(scheme.id) dark=\(dark) on \(surface)")
                    }
                }
            }
        }
    }

    func testAPaletteWithoutItsOwnTextTakesWhiteOrNearBlack() {
        let dark = ThemePalette.derived(seed: ThemeLook.brandSeed, muted: false, dark: true)
        let light = ThemePalette.derived(seed: ThemeLook.brandSeed, muted: false, dark: false)
        XCTAssertEqual(dark.readableText, ThemeColor(0xff, 0xff, 0xff))
        XCTAssertEqual(light.readableText, ThemeColor(0x1c, 0x1c, 0x1e))
        XCTAssertEqual(dark.ink(for: .secondaryLabel).alpha, 0.62)
    }

    func testAFontListResolvesToTheFirstFaceTheDeviceHas() {
        let has: (String) -> Bool = { ["Charter", "Menlo"].contains($0) }
        XCTAssertEqual(ThemeFontFace.resolve("JetBrains Mono, Fira Code, monospace", isInstalled: has), .monospaced)
        XCTAssertEqual(ThemeFontFace.resolve("JetBrains Mono, Menlo, monospace", isInstalled: has), .family("Menlo"))
        XCTAssertEqual(ThemeFontFace.resolve("Charter, Georgia, serif", isInstalled: has), .family("Charter"))
        XCTAssertEqual(ThemeFontFace.resolve("Georgia, SERIF", isInstalled: has), .serif)
        XCTAssertEqual(ThemeFontFace.resolve("Nothing Here", isInstalled: has), nil)
        XCTAssertEqual(ThemeFontFace.resolve("system-ui, Charter", isInstalled: has), nil)
        XCTAssertEqual(ThemeFontFace.resolve(" , ui-rounded", isInstalled: has), .rounded)
        XCTAssertEqual(ThemeFontFace.resolve(nil, isInstalled: has), nil)
    }
}

final class ThemeWatchLookTests: XCTestCase {

    private func look(_ pack: String, scheme: String = "") -> ThemeLook {
        ThemeLook(pack: ThemeLibrary().pack(id: pack), choice: .init(pack: pack, scheme: scheme))
    }

    func testTheWatchIsToldTheOutcomeOfATheme() throws {
        let phosphor = ThemeWatchLook(look: look("phosphor", scheme: "amber"))
        XCTAssertFalse(phosphor.isOwnLook)
        XCTAssertEqual(phosphor.accent, 0xf5a700)
        XCTAssertEqual(phosphor.text, 0xffdf9e)
        XCTAssertEqual(phosphor.bodyFace, .monospaced)
        XCTAssertEqual(phosphor.coverShape, .square)
        XCTAssertEqual(phosphor.coverRadius(10, side: 40), 0)

        let hifi = ThemeWatchLook(look: look("hi-fi"))
        XCTAssertEqual(hifi.coverRadius(10, side: 40), 20)
        XCTAssertNil(hifi.bodyFace)

        let liner = ThemeWatchLook(look: look("liner-notes", scheme: "lamplight"))
        XCTAssertEqual(liner.headingFace, .serif)
        XCTAssertEqual(liner.coverRadius(10, side: 40), 10)
        XCTAssertTrue(ThemeWatchLook(look: look("flaccy")).isOwnLook)
    }

    func testItCrossesToTheWatchAndBack() {
        let sent = ThemeWatchLook(look: look("marquee", scheme: "arcade"))
        XCTAssertEqual(ThemeWatchLook(encoded: sent.encoded), sent)
        XCTAssertNil(ThemeWatchLook(encoded: nil))
        XCTAssertNil(ThemeWatchLook(encoded: Data("{}".utf8)))
    }
}

final class ThemeLibraryTests: XCTestCase {

    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flaccy-theme-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func write(_ text: String, _ path: String, in folder: URL) throws {
        let file = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    func testReadsThePersonsThemesAndNamesTheBrokenOnes() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("name = \"Sunny\"\n[layout]\nalbums = \"wall\"", "sunny/theme.toml", in: folder)
        try write("name = ", "broken/theme.toml", in: folder)
        try write("", "empty/readme.txt", in: folder)
        try write("name = \"Mine\"", "phosphor/theme.toml", in: folder)
        try write("name = \"Hidden\"", ".hidden/theme.toml", in: folder)
        try write("name = \"Loose\"", "loose.toml", in: folder)

        let library = ThemeLibrary(themesDirectory: folder)
        XCTAssertEqual(library.pack(id: "sunny").name, "Sunny")
        XCTAssertFalse(library.pack(id: "sunny").isBuiltin)
        XCTAssertEqual(library.packs.count, ThemeLibrary.builtin.count + 1)
        XCTAssertEqual(library.problems.map(\.folder), ["broken", "empty", "phosphor"])
        XCTAssertTrue(library.problems[0].reason.contains("not valid TOML"))
        XCTAssertTrue(library.problems[1].reason.contains("no theme.toml"))
        XCTAssertTrue(library.problems[2].reason.contains("already has a theme"))
        XCTAssertTrue(library.pack(id: "phosphor").isBuiltin)
        XCTAssertEqual(ThemeLibrary(themesDirectory: URL(fileURLWithPath: "/nonexistent/themes")).packs.count, ThemeLibrary.builtin.count)
    }

    func testABuiltinCopiesOutAsAThemeThatLoadsUnderANewName() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try ThemeLibrary(themesDirectory: folder).makeEditableCopy(of: "phosphor", in: folder)
        XCTAssertEqual(first, "my-phosphor")
        let reloaded = ThemeLibrary(themesDirectory: folder)
        let copy = reloaded.pack(id: "my-phosphor")
        XCTAssertEqual(copy.name, "My Phosphor")
        XCTAssertEqual(copy.warnings, [])
        XCTAssertEqual(copy.schemes, reloaded.pack(id: "phosphor").schemes)
        XCTAssertEqual(copy.style, reloaded.pack(id: "phosphor").style)
        XCTAssertEqual(try reloaded.makeEditableCopy(of: "phosphor", in: folder), "my-phosphor-2")
    }

    func testAPersonsThemeCopiesWithEverythingInItsFolder() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("# mine\nname = \"Sunny\"\n[[scheme]]\nname = \"Day\"\n", "sunny/theme.toml", in: folder)
        try write("png", "sunny/assets/paper.png", in: folder)
        let id = try ThemeLibrary(themesDirectory: folder).makeEditableCopy(of: "sunny", in: folder)
        XCTAssertEqual(id, "my-sunny")
        let copy = folder.appendingPathComponent("my-sunny")
        XCTAssertEqual(try String(contentsOf: copy.appendingPathComponent("assets/paper.png"), encoding: .utf8), "png")
        XCTAssertEqual(
            try String(contentsOf: copy.appendingPathComponent("theme.toml"), encoding: .utf8),
            "# mine\nname = \"My Sunny\"\n[[scheme]]\nname = \"Day\"\n"
        )
    }

    func testRenamingTouchesOnlyTheThemesOwnName() {
        XCTAssertEqual(
            ThemeLibrary.renamed("format = 1\nname=\"Old\"\n[[scheme]]\nname = \"Keep\"\n", to: "A \"New\" One"),
            "format = 1\nname = \"A \\\"New\\\" One\"\n[[scheme]]\nname = \"Keep\"\n"
        )
    }
}

final class ThemeWardrobeCopyTests: XCTestCase {

    func testACopyIsWornTheWayItsOriginalWas() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flaccy-theme-copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var wardrobe = ThemeWardrobe()
        wardrobe.wear(pack: "phosphor")
        wardrobe.wear(scheme: "amber")
        wardrobe.show(albumsAs: "wall")
        let id = try ThemeLibrary(themesDirectory: folder).makeEditableCopy(of: "phosphor", in: folder)
        let library = ThemeLibrary(themesDirectory: folder)
        let original = wardrobe.look(in: library)
        wardrobe.wear(copyOfWorn: id)
        let copy = wardrobe.look(in: library)
        XCTAssertEqual(copy.pack.id, "my-phosphor")
        XCTAssertEqual(copy.wornScheme.id, original.wornScheme.id)
        XCTAssertEqual(copy.wornScheme.id, "amber")
        XCTAssertEqual(copy.albums, .wall)
        XCTAssertEqual(copy.palette(dark: true), original.palette(dark: true))
        XCTAssertEqual(wardrobe.remembered("phosphor").scheme, "amber")
    }

    func testAGalleryDrawsAThemeAsItWasLastWorn() {
        let library = ThemeLibrary()
        var wardrobe = ThemeWardrobe()
        wardrobe.wear(pack: "gallery")
        wardrobe.show(albumsAs: "list")
        wardrobe.wear(pack: "phosphor")
        XCTAssertEqual(wardrobe.look(wearing: library.pack(id: "gallery"), in: library).albums, .list)
        XCTAssertEqual(wardrobe.look(wearing: library.pack(id: "phosphor"), in: library), wardrobe.look(in: library))
        XCTAssertEqual(wardrobe.wornPackID, "phosphor")
    }
}
