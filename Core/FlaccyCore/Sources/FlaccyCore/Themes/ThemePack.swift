import Foundation

/// A theme as its folder describes it: what `theme.toml` says about fonts,
/// shapes, layout, color schemes and variants. Mirrored in Rust as
/// `linux/shared/src/theme/pack.rs`, with the same words for every mistake.
public struct ThemePack: Equatable, Sendable {

    /// The newest `format` this build reads. A theme written for a later one
    /// is refused by name instead of being half applied.
    public static let format = 1

    public static let coverSizeMin = 96
    public static let coverSizeMax = 320
    public static let coverSizeDefault = 140

    public static let cornersSharp = 0.0
    public static let cornersStandard = 1.0
    public static let cornersRound = 1.6
    public static let cornersMax = 2.0

    /// Whether a theme or one of its color schemes is drawn for one mode only.
    public enum Appearance: String, Sendable, CaseIterable {
        case any
        case dark
        case light
    }

    /// How the Albums page lays the library out.
    public enum AlbumsView: String, Sendable, CaseIterable {
        case grid
        case wall
        case list
        case carousel

        public var id: String { rawValue }
    }

    public enum CoverShape: String, Sendable, CaseIterable {
        case rounded
        case square
        case circle

        public var id: String { rawValue }
    }

    /// One layer of look: what a theme, a variant or the person's own choices
    /// set. Anything left nil falls through to the layer beneath.
    public struct Style: Equatable, Sendable {
        public var interfaceFont: String?
        public var headingFont: String?
        public var corners: Double?
        public var covers: CoverShape?
        public var shadows: Bool?
        public var albums: AlbumsView?
        public var coverSize: Int?
        public var glow: Bool?

        public init(
            interfaceFont: String? = nil, headingFont: String? = nil, corners: Double? = nil,
            covers: CoverShape? = nil, shadows: Bool? = nil, albums: AlbumsView? = nil,
            coverSize: Int? = nil, glow: Bool? = nil
        ) {
            self.interfaceFont = interfaceFont
            self.headingFont = headingFont
            self.corners = corners
            self.covers = covers
            self.shadows = shadows
            self.albums = albums
            self.coverSize = coverSize
            self.glow = glow
        }

        /// This layer laid over `base`: what this one sets wins.
        public func over(_ base: Style) -> Style {
            Style(
                interfaceFont: interfaceFont ?? base.interfaceFont,
                headingFont: headingFont ?? base.headingFont,
                corners: corners ?? base.corners,
                covers: covers ?? base.covers,
                shadows: shadows ?? base.shadows,
                albums: albums ?? base.albums,
                coverSize: coverSize ?? base.coverSize,
                glow: glow ?? base.glow
            )
        }

        public var isEmpty: Bool { self == Style() }
    }

    /// Exact colors for one mode. Whatever is left out is worked out from the
    /// scheme's accent.
    public struct Colors: Equatable, Sendable {
        public var window: ThemeColor?
        public var view: ThemeColor?
        public var sidebar: ThemeColor?
        public var headerbar: ThemeColor?
        public var card: ThemeColor?
        public var popover: ThemeColor?
        public var text: ThemeColor?
        public var accent: ThemeColor?
        public var accentText: ThemeColor?
        public var onAccent: ThemeColor?
        public var washA: ThemeColor?
        public var washB: ThemeColor?

        public init() {}
    }

    public enum Accent: Equatable, Sendable {
        /// Follows the cover of the album that is playing.
        case artwork
        case fixed(ThemeColor)
    }

    public struct Scheme: Equatable, Sendable {
        public var id: String
        public var name: String
        public var accent: Accent
        public var muted: Bool
        public var appearance: Appearance?
        public var dark: Colors
        public var light: Colors
    }

    public struct Variant: Equatable, Sendable {
        public var id: String
        public var name: String
        public var style: Style
    }

    public var id: String
    public var name: String
    public var author: String
    public var description: String
    public var appearance: Appearance
    public var style: Style
    public var schemes: [Scheme]
    public var variants: [Variant]
    public var isBuiltin: Bool
    public var warnings: [String]

    /// Why a document could not be used as a theme at all.
    public struct Refusal: Error, Equatable, Sendable {
        public let reason: String
    }

    /// A name cut down to what an id may hold: lowercase letters, digits and
    /// single dashes.
    public static func slug(_ name: String) -> String {
        var out = ""
        for scalar in name.unicodeScalars {
            let character = Character(scalar)
            if scalar.isASCII, character.isLetter || character.isNumber {
                out.append(character.lowercased())
            } else if !out.isEmpty, !out.hasSuffix("-") {
                out.append("-")
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// Reads a `theme.toml`. A file that is not TOML, has no name or was
    /// written for a newer Flaccy is refused with the reason; anything smaller
    /// (a misspelt key, a color that is not one) is skipped and listed in
    /// `warnings`, and the rest of the theme still applies.
    public static func parse(id: String, document: String) throws(Refusal) -> ThemePack {
        let table: ThemeDocument.Table
        do {
            table = try ThemeDocument.read(document)
        } catch {
            throw Refusal(reason: "theme.toml is not valid TOML (\(error.message)).")
        }
        let notes = Notes()
        let root = Reader(table: table, path: "", notes: notes)

        let format = root.number("format") ?? Double(ThemePack.format)
        if format > Double(ThemePack.format) {
            throw Refusal(
                reason: "This theme is written for a newer Flaccy (format \(Reader.shown(format)), this one reads up to \(ThemePack.format))."
            )
        }
        guard let name = root.text("name") else {
            throw Refusal(reason: "theme.toml has no name. Add a line like name = \"My Theme\".")
        }
        var pack = ThemePack(
            id: id,
            name: name,
            author: root.text("author") ?? "",
            description: root.text("description") ?? "",
            appearance: root.choice("appearance", Reader.appearances) ?? .any,
            style: Reader.style(root),
            schemes: Reader.schemes(root),
            variants: Reader.variants(root),
            isBuiltin: false,
            warnings: []
        )
        root.finish()
        pack.warnings = notes.all
        return pack
    }
}

/// The mistakes found while reading one document, in the order they were met.
private final class Notes {
    var all: [String] = []
}

/// Reads one table of a theme document, noting every key it cannot use and
/// every key nobody asked for, so a typo is named instead of silently ignored.
private final class Reader {
    let table: ThemeDocument.Table
    let path: String
    let notes: Notes
    var asked: [String] = []

    static let appearances: [(String, ThemePack.Appearance)] = [("any", .any), ("dark", .dark), ("light", .light)]
    static let views: [(String, ThemePack.AlbumsView)] = [
        ("grid", .grid), ("wall", .wall), ("list", .list), ("carousel", .carousel),
    ]
    static let shapes: [(String, ThemePack.CoverShape)] = [
        ("rounded", .rounded), ("square", .square), ("circle", .circle),
    ]
    static let cornerNames: [(String, Double)] = [
        ("sharp", ThemePack.cornersSharp), ("standard", ThemePack.cornersStandard), ("round", ThemePack.cornersRound),
    ]

    init(table: ThemeDocument.Table, path: String, notes: Notes) {
        self.table = table
        self.path = path
        self.notes = notes
    }

    /// A number as a message shows it: whole numbers without a fraction.
    static func shown(_ number: Double) -> String {
        number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : String(number)
    }

    func named(_ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }

    func note(_ text: String) {
        notes.all.append(text)
    }

    func value(_ key: String) -> ThemeDocument.Value? {
        asked.append(key)
        return table[key]
    }

    func text(_ key: String) -> String? {
        switch value(key) {
        case nil: return nil
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default:
            note("\(named(key)) must be text in quotes")
            return nil
        }
    }

    func flag(_ key: String) -> Bool? {
        switch value(key) {
        case nil: return nil
        case .flag(let flag): return flag
        default:
            note("\(named(key)) must be true or false")
            return nil
        }
    }

    func number(_ key: String) -> Double? {
        switch value(key) {
        case nil: return nil
        case .integer(let number): return Double(number)
        case .float(let number) where number.isFinite: return number
        default:
            note("\(named(key)) must be a number")
            return nil
        }
    }

    func color(_ key: String) -> ThemeColor? {
        guard let text = text(key) else { return nil }
        guard let color = ThemeColor(hex: text) else {
            note("\(named(key)): \"\(text)\" is not a color (write it as #rrggbb)")
            return nil
        }
        return color
    }

    func choice<T>(_ key: String, _ options: [(String, T)]) -> T? {
        guard let text = text(key) else { return nil }
        if let found = options.first(where: { $0.0.lowercased() == text.lowercased() }) {
            return found.1
        }
        note("\(named(key)): \"\(text)\" is not one of \(options.map(\.0).joined(separator: ", "))")
        return nil
    }

    func child(_ key: String) -> Reader? {
        switch value(key) {
        case nil: return nil
        case .table(let table): return Reader(table: table, path: named(key), notes: notes)
        default:
            note("\(named(key)) must be a [\(named(key))] table")
            return nil
        }
    }

    func children(_ key: String) -> [Reader] {
        switch value(key) {
        case nil: return []
        case .list(let items):
            return items.enumerated().compactMap { index, item in
                guard case .table(let table) = item else { return nil }
                return Reader(table: table, path: "\(named(key)) \(index + 1)", notes: notes)
            }
        default:
            note("\(named(key)) must be written as [[\(named(key))]] blocks")
            return []
        }
    }

    /// Names every key of this table that nothing read.
    func finish() {
        for key in table.keys where !asked.contains(key) {
            note("\(named(key)) is not something a theme can set")
        }
    }

    static func corners(_ shape: Reader) -> Double? {
        shape.asked.append("corners")
        switch shape.table["corners"] {
        case nil: return nil
        case .text: return shape.choice("corners", cornerNames)
        case .integer, .float:
            guard let scale = shape.number("corners") else { return nil }
            if !(0.0...ThemePack.cornersMax).contains(scale) {
                shape.note(
                    "\(shape.named("corners")): \(shown(scale)) is outside 0 to \(shown(ThemePack.cornersMax)), so the nearest end is used"
                )
            }
            return min(max(scale, 0.0), ThemePack.cornersMax)
        default:
            shape.note(
                "\(shape.named("corners")) must be sharp, standard, round or a number from 0 to \(shown(ThemePack.cornersMax))"
            )
            return nil
        }
    }

    static func coverSize(_ layout: Reader) -> Int? {
        guard let size = layout.number("cover_size") else { return nil }
        if !(Double(ThemePack.coverSizeMin)...Double(ThemePack.coverSizeMax)).contains(size) {
            layout.note(
                "\(layout.named("cover_size")): \(shown(size)) is outside \(ThemePack.coverSizeMin) to \(ThemePack.coverSizeMax), so the nearest end is used"
            )
        }
        let clamped = min(max(size.rounded(), Double(ThemePack.coverSizeMin)), Double(ThemePack.coverSizeMax))
        return Int(clamped)
    }

    /// The `[fonts]`, `[shape]` and `[layout]` tables of a theme or of one variant.
    static func style(_ root: Reader) -> ThemePack.Style {
        var style = ThemePack.Style()
        if let fonts = root.child("fonts") {
            style.interfaceFont = fonts.text("interface")
            style.headingFont = fonts.text("headings")
            fonts.finish()
        }
        if let shape = root.child("shape") {
            style.corners = corners(shape)
            style.covers = shape.choice("covers", shapes)
            style.shadows = shape.flag("shadows")
            shape.finish()
        }
        if let layout = root.child("layout") {
            style.albums = layout.choice("albums", views)
            style.coverSize = coverSize(layout)
            style.glow = layout.flag("glow")
            layout.finish()
        }
        return style
    }

    static func colors(_ scheme: Reader, _ key: String) -> ThemePack.Colors {
        guard let mode = scheme.child(key) else { return ThemePack.Colors() }
        var colors = ThemePack.Colors()
        colors.window = mode.color("window")
        colors.view = mode.color("view")
        colors.sidebar = mode.color("sidebar")
        colors.headerbar = mode.color("headerbar")
        colors.card = mode.color("card")
        colors.popover = mode.color("popover")
        colors.text = mode.color("text")
        colors.accent = mode.color("accent")
        colors.accentText = mode.color("accent_text")
        colors.onAccent = mode.color("on_accent")
        colors.washA = mode.color("wash_a")
        colors.washB = mode.color("wash_b")
        mode.finish()
        return colors
    }

    static func accent(_ scheme: Reader) -> ThemePack.Accent {
        guard let text = scheme.text("accent") else { return .artwork }
        if text.lowercased() == "artwork" { return .artwork }
        if let color = ThemeColor(hex: text) { return .fixed(color) }
        scheme.note(
            "\(scheme.named("accent")): \"\(text)\" is not a color (write it as #rrggbb, or \"artwork\" to follow the cover)"
        )
        return .artwork
    }

    /// An id for the `index`th entry: its own `id`, else its name's slug, else
    /// its position, and never one an earlier entry already took.
    static func entryID(_ reader: Reader, name: String, kind: String, index: Int, taken: [String]) -> String {
        let own = reader.text("id").map(ThemePack.slug).flatMap { $0.isEmpty ? nil : $0 }
        let named = ThemePack.slug(name)
        let wanted = own ?? (named.isEmpty ? "\(kind)-\(index + 1)" : named)
        guard taken.contains(wanted) else { return wanted }
        reader.note("\(reader.path): the id \"\(wanted)\" is used twice, so this one becomes \"\(wanted)-\(index + 1)\"")
        return "\(wanted)-\(index + 1)"
    }

    static func schemes(_ root: Reader) -> [ThemePack.Scheme] {
        var schemes: [ThemePack.Scheme] = []
        for (index, reader) in root.children("scheme").enumerated() {
            let name = reader.text("name") ?? "Colors \(index + 1)"
            let id = entryID(reader, name: name, kind: "scheme", index: index, taken: schemes.map(\.id))
            let accent = accent(reader)
            let muted = reader.flag("muted") ?? false
            let appearance = reader.choice("appearance", appearances)
            let dark = colors(reader, "dark")
            let light = colors(reader, "light")
            reader.finish()
            schemes.append(
                ThemePack.Scheme(
                    id: id, name: name, accent: accent, muted: muted, appearance: appearance, dark: dark, light: light
                )
            )
        }
        if schemes.isEmpty {
            schemes.append(
                ThemePack.Scheme(
                    id: "default", name: "Default", accent: .artwork, muted: false, appearance: nil,
                    dark: ThemePack.Colors(), light: ThemePack.Colors()
                )
            )
        }
        return schemes
    }

    static func variants(_ root: Reader) -> [ThemePack.Variant] {
        var variants: [ThemePack.Variant] = []
        for (index, reader) in root.children("variant").enumerated() {
            let name = reader.text("name") ?? "Variant \(index + 1)"
            let id = entryID(reader, name: name, kind: "variant", index: index, taken: variants.map(\.id))
            let style = style(reader)
            reader.finish()
            variants.append(ThemePack.Variant(id: id, name: name, style: style))
        }
        return variants
    }
}
