import AppKit
import FlaccyCore

/// The typefaces of the worn theme and how a system font turns into them on
/// the Mac. A font the app chose for itself (anything that is not the system
/// font) is left as it is.
@MainActor
enum MacThemeTypography {

    struct Faces: Equatable {
        var body: ThemeFontFace?
        var heading: ThemeFontFace?

        var isSystem: Bool { body == nil && heading == nil }
    }

    /// The faces a look asks for on this Mac.
    static func faces(for look: ThemeLook) -> Faces {
        let families = Set(NSFontManager.shared.availableFontFamilies.map { $0.lowercased() })
        let installed: (String) -> Bool = { families.contains($0.lowercased()) }
        return Faces(
            body: ThemeFontFace.resolve(look.interfaceFont, isInstalled: installed),
            heading: ThemeFontFace.resolve(look.headingFont, isInstalled: installed)
        )
    }

    /// The system's monospaced face is a fifth wider than its text face, so
    /// it is set a little smaller to fit where the text face fitted.
    private static let monospacedScale: CGFloat = 0.92

    /// Whether `font` is set as a title: heavy enough to be the name of
    /// something (an album, a song, a section).
    static func isHeading(_ font: NSFont) -> Bool {
        NSFontManager.shared.weight(of: font) >= 8
    }

    private static func isSystemFont(_ font: NSFont) -> Bool {
        font.fontName.hasPrefix(".")
    }

    private static func designed(_ font: NSFont, _ design: NSFontDescriptor.SystemDesign) -> NSFont {
        guard let descriptor = font.fontDescriptor.withDesign(design) else { return font }
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// `font` in the worn theme's face, at the same size and weight.
    static func themed(_ font: NSFont, faces: Faces) -> NSFont {
        guard isSystemFont(font) else { return font }
        guard let face = (isHeading(font) ? faces.heading : nil) ?? faces.body else { return font }
        switch face {
        case .monospaced:
            let narrow = NSFont(descriptor: font.fontDescriptor, size: (font.pointSize * monospacedScale).rounded()) ?? font
            return designed(narrow, .monospaced)
        case .serif: return designed(font, .serif)
        case .rounded: return designed(font, .rounded)
        case .family(let family): return NSFontManager.shared.convert(font, toFamily: family)
        }
    }
}
