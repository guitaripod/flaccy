import Foundation

/// What the person has on and what they have chosen for themselves: the
/// theme, its color scheme and variant, the Albums view they switched it to,
/// and their own cover shape, corners, font and glow over any theme. Each
/// theme is remembered as it was left, so coming back to one finds it that
/// way. Mirrors the Linux client's `config.toml` keys and `ui/look.rs`.
public struct ThemeWardrobe: Equatable, Sendable, Codable {

    public static let storageKey = "flaccy.theme.wardrobe"

    /// The theme that is on; empty means Flaccy's own.
    public var pack = ""
    public var scheme = ""
    public var variant = ""
    /// The Albums view the person switched this theme to; empty for the theme's.
    public var albumsView = ""
    /// The person's own choices; empty or zero means "as the theme has it".
    public var coverSize = 0
    public var covers = ""
    public var corners = ""
    public var font = ""
    public var glow = ""
    /// `scheme|variant|view` under each theme's id.
    public var memory: [String: String] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pack = try container.decodeIfPresent(String.self, forKey: .pack) ?? ""
        scheme = try container.decodeIfPresent(String.self, forKey: .scheme) ?? ""
        variant = try container.decodeIfPresent(String.self, forKey: .variant) ?? ""
        albumsView = try container.decodeIfPresent(String.self, forKey: .albumsView) ?? ""
        coverSize = try container.decodeIfPresent(Int.self, forKey: .coverSize) ?? 0
        covers = try container.decodeIfPresent(String.self, forKey: .covers) ?? ""
        corners = try container.decodeIfPresent(String.self, forKey: .corners) ?? ""
        font = try container.decodeIfPresent(String.self, forKey: .font) ?? ""
        glow = try container.decodeIfPresent(String.self, forKey: .glow) ?? ""
        memory = try container.decodeIfPresent([String: String].self, forKey: .memory) ?? [:]
    }

    /// The wardrobe as it is stored, or a fresh one when nothing is or what is
    /// there cannot be read.
    public init(stored data: Data?) {
        self = data.flatMap { try? JSONDecoder().decode(ThemeWardrobe.self, from: $0) } ?? ThemeWardrobe()
    }

    public var stored: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// The id of the theme that is on, with the empty default spelled out.
    public var wornPackID: String {
        pack.isEmpty ? ThemeLibrary.defaultID : pack
    }

    public var choice: ThemeLook.Choice {
        ThemeLook.Choice(pack: wornPackID, scheme: scheme, variant: variant)
    }

    /// The person's own choices as a layer over the theme.
    public var ownChoices: ThemePack.Style {
        let scale: Double? =
            switch corners {
            case "sharp": ThemePack.cornersSharp
            case "standard": ThemePack.cornersStandard
            case "round": ThemePack.cornersRound
            default: nil
            }
        let family = font.trimmingCharacters(in: .whitespaces)
        return ThemePack.Style(
            interfaceFont: family.isEmpty ? nil : family,
            corners: scale,
            covers: ThemePack.CoverShape(rawValue: covers),
            albums: ThemePack.AlbumsView(rawValue: albumsView),
            coverSize: coverSize > 0
                ? min(max(coverSize, ThemePack.coverSizeMin), ThemePack.coverSizeMax) : nil,
            glow: glow == "on" ? true : (glow == "off" ? false : nil)
        )
    }

    /// Whether anything of the person's own lies over the theme.
    public var hasOwnChoices: Bool { !ownChoices.isEmpty }

    /// What a theme was last worn with.
    public struct Worn: Equatable, Sendable {
        public var scheme = ""
        public var variant = ""
        public var view = ""

        public init(scheme: String = "", variant: String = "", view: String = "") {
            self.scheme = scheme
            self.variant = variant
            self.view = view
        }

        init(encoded: String) {
            let parts = encoded.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            scheme = parts.count > 0 ? parts[0] : ""
            variant = parts.count > 1 ? parts[1] : ""
            view = parts.count > 2 ? parts[2] : ""
        }

        var encoded: String { "\(scheme)|\(variant)|\(view)" }
    }

    /// How `pack` was last worn, or all defaults when it never was.
    public func remembered(_ pack: String) -> Worn {
        if wornPackID == pack { return Worn(scheme: scheme, variant: variant, view: albumsView) }
        return memory[pack].map(Worn.init(encoded:)) ?? Worn()
    }

    private mutating func rememberWorn() {
        memory[wornPackID] = Worn(scheme: scheme, variant: variant, view: albumsView).encoded
    }

    /// Puts on the theme with this id, as it was last worn.
    public mutating func wear(pack id: String) {
        guard wornPackID != id else { return }
        rememberWorn()
        let worn = remembered(id)
        pack = id
        scheme = worn.scheme
        variant = worn.variant
        albumsView = worn.view
        rememberWorn()
    }

    /// Puts on the copy of the worn theme that was just made under this id,
    /// worn the way the original is: the same colors, variant and view.
    public mutating func wear(copyOfWorn id: String) {
        let worn = remembered(wornPackID)
        wear(pack: id)
        scheme = worn.scheme
        variant = worn.variant
        albumsView = worn.view
        rememberWorn()
    }

    public mutating func wear(scheme id: String) {
        scheme = id
        rememberWorn()
    }

    /// Puts on another variant of the worn theme. A variant is a layout of
    /// its own, so a view the person switched to earlier gives way to it.
    public mutating func wear(variant id: String) {
        variant = id
        albumsView = ""
        rememberWorn()
    }

    /// Switches the worn theme's Albums view; empty goes back to the theme's.
    public mutating func show(albumsAs view: String) {
        albumsView = view
        rememberWorn()
    }

    /// Clears every choice of the person's own, leaving the theme as its
    /// author made it.
    public mutating func resetOwnChoices() {
        albumsView = ""
        coverSize = 0
        covers = ""
        corners = ""
        font = ""
        glow = ""
        rememberWorn()
    }

    /// The look `pack` would have if it were put on now: as it was last
    /// worn, under the person's own choices. What a gallery draws a theme as.
    public func look(wearing pack: ThemePack, in library: ThemeLibrary) -> ThemeLook {
        var tried = self
        tried.wear(pack: pack.id)
        return tried.look(in: library)
    }

    /// The look this wardrobe resolves to in `library`.
    public func look(in library: ThemeLibrary) -> ThemeLook {
        ThemeLook(pack: library.pack(id: wornPackID), choice: choice, overrides: ownChoices)
    }
}
