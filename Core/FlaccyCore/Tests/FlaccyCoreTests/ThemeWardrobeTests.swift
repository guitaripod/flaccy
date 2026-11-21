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
