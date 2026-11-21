import XCTest
@testable import FlaccyCore

/// Replays `Fixtures/theme-golden.json`, which the Rust client writes from its
/// own theme code (`linux/src/theme/golden.rs`), and asserts FlaccyCore makes
/// the same thing of every built-in theme, every awkward document, every seed
/// color and every carousel layout. A change to either language that forgets
/// the other fails here or in the Rust test that guards the file.
final class ThemeGoldenTests: XCTestCase {

    private struct Golden: Decodable {
        let builtin: [Theme]
        let documents: [Document]
        let derived: [Derived]
        let ownChoices: [OwnChoice]
        let flow: [Room]
        let glide: [Mark]

        enum CodingKeys: String, CodingKey {
            case builtin, documents, derived, flow, glide
            case ownChoices = "own_choices"
        }
    }

    private struct Named: Decodable, Equatable {
        let id: String
        let name: String
    }

    private struct Theme: Decodable {
        let id: String
        let name: String
        let author: String
        let description: String
        let appearance: String
        let warnings: [String]
        let schemes: [Named]
        let variants: [Named]
        let looks: [Look]
    }

    private struct Colors: Decodable, Equatable {
        let accent: String
        let onAccent: String
        let accentText: String
        let washA: String
        let washB: String
        let card: String
        let window: String
        let headerbar: String
        let sidebar: String
        let view: String
        let popover: String
        let text: String?

        enum CodingKeys: String, CodingKey {
            case accent, card, window, headerbar, sidebar, view, popover, text
            case onAccent = "on_accent"
            case accentText = "accent_text"
            case washA = "wash_a"
            case washB = "wash_b"
        }

        init(_ palette: ThemePalette) {
            accent = palette.accent.hex
            onAccent = palette.onAccent.hex
            accentText = palette.accentText.hex
            washA = palette.washA.hex
            washB = palette.washB.hex
            card = palette.card.hex
            window = palette.window.hex
            headerbar = palette.headerbar.hex
            sidebar = palette.sidebar.hex
            view = palette.view.hex
            popover = palette.popover.hex
            text = palette.text?.hex
        }
    }

    private struct Look: Decodable {
        let scheme: String
        let variant: String?
        let interfaceFont: String?
        let headingFont: String?
        let corners: Double
        let covers: String
        let shadows: Bool
        let albums: String
        let coverSize: Int
        let glow: Bool
        let appearance: String
        let followsArtwork: Bool
        let dark: Colors
        let light: Colors
        let darkWithCover: Colors

        enum CodingKeys: String, CodingKey {
            case scheme, variant, corners, covers, shadows, albums, glow, appearance, dark, light
            case interfaceFont = "interface_font"
            case headingFont = "heading_font"
            case coverSize = "cover_size"
            case followsArtwork = "follows_artwork"
            case darkWithCover = "dark_with_cover"
        }
    }

    private struct Document: Decodable {
        let name: String
        let document: String
        let refused: String?
        let theme: Theme?
    }

    private struct Derived: Decodable {
        let seed: String
        let muted: Bool
        let dark: Bool
        let palette: Colors
    }

    private struct Own: Decodable {
        let interfaceFont: String?
        let headingFont: String?
        let corners: Double?
        let covers: String?
        let shadows: Bool?
        let albums: String?
        let coverSize: Int?
        let glow: Bool?

        enum CodingKeys: String, CodingKey {
            case corners, covers, shadows, albums, glow
            case interfaceFont = "interface_font"
            case headingFont = "heading_font"
            case coverSize = "cover_size"
        }
    }

    private struct OwnChoice: Decodable {
        let scheme: String
        let variant: String
        let own: Own
        let look: Look
    }

    private struct Slot: Decodable {
        let index: Int
        let x: Double
        let y: Double
        let side: Double
        let opacity: Double
    }

    private struct Room: Decodable {
        let width: Double
        let height: Double
        let position: Double
        let count: Int
        let side: Double
        let gap: Double
        let pitch: Double
        let slots: [Slot]
    }

    private struct Mark: Decodable {
        let frame: Int
        let position: Double
        let velocity: Double
    }

    private static let golden: Golden = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/theme-golden.json")
        do {
            return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
        } catch {
            fatalError("theme-golden.json could not be read: \(error)")
        }
    }()

    private func assertSame(_ pack: ThemePack, _ expected: Theme, _ label: String) {
        XCTAssertEqual(pack.name, expected.name, label)
        XCTAssertEqual(pack.author, expected.author, label)
        XCTAssertEqual(pack.description, expected.description, label)
        XCTAssertEqual(pack.appearance.rawValue, expected.appearance, label)
        XCTAssertEqual(pack.warnings, expected.warnings, label)
        XCTAssertEqual(pack.schemes.map { Named(id: $0.id, name: $0.name) }, expected.schemes, label)
        XCTAssertEqual(pack.variants.map { Named(id: $0.id, name: $0.name) }, expected.variants, label)
        let variants = pack.variants.isEmpty ? [""] : pack.variants.map(\.id)
        var made: [ThemeLook] = []
        for scheme in pack.schemes {
            for variant in variants {
                made.append(ThemeLook(pack: pack, choice: .init(pack: pack.id, scheme: scheme.id, variant: variant)))
            }
        }
        XCTAssertEqual(made.count, expected.looks.count, label)
        for (look, wanted) in zip(made, expected.looks) {
            assertSame(look, wanted, "\(label) / \(wanted.scheme) / \(wanted.variant ?? "-")")
        }
    }

    private func assertSame(_ look: ThemeLook, _ expected: Look, _ label: String) {
        XCTAssertEqual(look.wornScheme.id, expected.scheme, label)
        XCTAssertEqual(look.wornVariant?.id, expected.variant, label)
        XCTAssertEqual(look.interfaceFont, expected.interfaceFont, label)
        XCTAssertEqual(look.headingFont, expected.headingFont, label)
        XCTAssertEqual(look.corners, expected.corners, accuracy: 1e-12, label)
        XCTAssertEqual(look.covers.id, expected.covers, label)
        XCTAssertEqual(look.shadows, expected.shadows, label)
        XCTAssertEqual(look.albums.id, expected.albums, label)
        XCTAssertEqual(look.coverSize, expected.coverSize, label)
        XCTAssertEqual(look.glow, expected.glow, label)
        XCTAssertEqual(look.appearance.rawValue, expected.appearance, label)
        XCTAssertEqual(look.followsArtwork, expected.followsArtwork, label)
        XCTAssertEqual(Colors(look.palette(dark: true)), expected.dark, "\(label) dark")
        XCTAssertEqual(Colors(look.palette(dark: false)), expected.light, "\(label) light")
        XCTAssertEqual(
            Colors(look.palette(dark: true, artwork: ThemeColor(0x1f, 0x6f, 0xeb))), expected.darkWithCover,
            "\(label) with a cover"
        )
    }

    func testEveryBuiltinThemeResolvesAsRustResolvesIt() {
        let golden = Self.golden
        XCTAssertEqual(ThemeLibrary.builtin.map(\.id), golden.builtin.map(\.id))
        XCTAssertEqual(ThemeLibrary.builtin.first?.id, ThemeLibrary.defaultID)
        for (pack, expected) in zip(ThemeLibrary.builtin, golden.builtin) {
            XCTAssertTrue(pack.isBuiltin)
            XCTAssertEqual(pack.warnings, [], pack.id)
            assertSame(pack, expected, pack.id)
        }
    }

    func testEveryAwkwardDocumentReadsOrIsRefusedInTheSameWords() {
        for entry in Self.golden.documents {
            do {
                let pack = try ThemePack.parse(id: "case", document: entry.document)
                guard let expected = entry.theme else {
                    XCTFail("\(entry.name): read, but Rust refuses it with \(entry.refused ?? "")")
                    continue
                }
                assertSame(pack, expected, entry.name)
            } catch {
                XCTAssertEqual(error.reason, entry.refused, entry.name)
            }
        }
    }

    func testEverySeedDerivesTheSamePalette() {
        for entry in Self.golden.derived {
            guard let seed = ThemeColor(hex: entry.seed) else {
                XCTFail("\(entry.seed) is not a color")
                continue
            }
            XCTAssertEqual(
                Colors(ThemePalette.derived(seed: seed, muted: entry.muted, dark: entry.dark)), entry.palette,
                "\(entry.seed) muted=\(entry.muted) dark=\(entry.dark)"
            )
        }
    }

    func testThePersonsOwnChoicesLieOverTheTheme() throws {
        let phosphor = try XCTUnwrap(ThemeLibrary.builtin.first { $0.id == "phosphor" })
        for entry in Self.golden.ownChoices {
            let own = ThemePack.Style(
                interfaceFont: entry.own.interfaceFont,
                headingFont: entry.own.headingFont,
                corners: entry.own.corners,
                covers: entry.own.covers.flatMap(ThemePack.CoverShape.init(rawValue:)),
                shadows: entry.own.shadows,
                albums: entry.own.albums.flatMap(ThemePack.AlbumsView.init(rawValue:)),
                coverSize: entry.own.coverSize,
                glow: entry.own.glow
            )
            let look = ThemeLook(
                pack: phosphor, choice: .init(pack: "phosphor", scheme: entry.scheme, variant: entry.variant),
                overrides: own
            )
            assertSame(look, entry.look, "\(entry.scheme) / \(entry.variant)")
        }
    }

    func testTheCarouselIsLaidOutTheSame() {
        for room in Self.golden.flow {
            let label = "\(room.width)x\(room.height) at \(room.position) of \(room.count)"
            let flow = FlowGeometry.fitting(width: room.width, height: room.height)
            XCTAssertEqual(flow.side, room.side, label)
            XCTAssertEqual(flow.gap, room.gap, label)
            XCTAssertEqual(flow.pitch, room.pitch, accuracy: 1e-9, label)
            let slots = flow.slots(width: room.width, height: room.height, position: room.position, count: room.count)
            XCTAssertEqual(slots.map(\.index), room.slots.map(\.index), label)
            for (slot, expected) in zip(slots, room.slots) {
                XCTAssertEqual(slot.x, expected.x, accuracy: 1e-9, label)
                XCTAssertEqual(slot.y, expected.y, accuracy: 1e-9, label)
                XCTAssertEqual(slot.side, expected.side, accuracy: 1e-9, label)
                XCTAssertEqual(slot.opacity, expected.opacity, accuracy: 1e-9, label)
            }
        }
    }

    func testAGlideMovesTheSameWayFrameByFrame() {
        var glide = FlowGlide()
        var frames = 0
        var marks: [(Int, Double, Double)] = []
        while glide.step(toward: 3.0, seconds: 1.0 / 60.0) {
            frames += 1
            if frames % 10 == 0 { marks.append((frames, glide.position, glide.velocity)) }
        }
        marks.append((frames + 1, glide.position, glide.velocity))
        XCTAssertEqual(marks.map(\.0), Self.golden.glide.map(\.frame))
        for (mark, expected) in zip(marks, Self.golden.glide) {
            XCTAssertEqual(mark.1, expected.position, accuracy: 1e-9)
            XCTAssertEqual(mark.2, expected.velocity, accuracy: 1e-9)
        }
    }
}
