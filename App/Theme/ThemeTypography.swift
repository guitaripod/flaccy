import FlaccyCore
import os
import UIKit

/// The typefaces of the worn theme and how a system font turns into them. A
/// font the app chose for itself (anything that is not the system font) is
/// left as it is.
nonisolated enum ThemeTypography {

    struct Faces: Equatable, Sendable {
        var body: ThemeFontFace?
        var heading: ThemeFontFace?

        var isSystem: Bool { body == nil && heading == nil }
    }

    private static let faces = OSAllocatedUnfairLock(initialState: Faces())

    static var current: Faces { faces.withLock { $0 } }

    static func wear(_ worn: Faces) {
        faces.withLock { $0 = worn }
    }

    /// The faces a look asks for on this device.
    static func faces(for look: ThemeLook) -> Faces {
        let installed: (String) -> Bool = { !UIFont.fontNames(forFamilyName: $0).isEmpty }
        return Faces(
            body: ThemeFontFace.resolve(look.interfaceFont, isInstalled: installed),
            heading: ThemeFontFace.resolve(look.headingFont, isInstalled: installed)
        )
    }

    private static let headingStyles: Set<String> = [
        UIFont.TextStyle.largeTitle.rawValue, UIFont.TextStyle.title1.rawValue, UIFont.TextStyle.title2.rawValue,
        UIFont.TextStyle.title3.rawValue, UIFont.TextStyle.headline.rawValue,
    ]

    private static func weight(of font: UIFont) -> UIFont.Weight {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        return UIFont.Weight((traits?[.weight] as? CGFloat) ?? UIFont.Weight.regular.rawValue)
    }

    /// Whether `font` is set as a title: one of the title text styles, or
    /// heavy enough to be the name of something (an album, a song, a section).
    static func isHeading(_ font: UIFont) -> Bool {
        if let style = font.fontDescriptor.object(forKey: .textStyle) as? String, headingStyles.contains(style) {
            return true
        }
        return weight(of: font).rawValue >= UIFont.Weight.semibold.rawValue
    }

    /// The system's monospaced face is a fifth wider than its text face, so
    /// it is set a little smaller to fit where the text face fitted.
    private static let monospacedScale: CGFloat = 0.9

    private static func isSystemFont(_ font: UIFont) -> Bool {
        font.fontName.hasPrefix(".")
    }

    private static func designed(_ font: UIFont, _ design: UIFontDescriptor.SystemDesign) -> UIFont {
        font.fontDescriptor.withDesign(design).map { UIFont(descriptor: $0, size: 0) } ?? font
    }

    private static func named(_ font: UIFont, family: String) -> UIFont {
        var descriptor = UIFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [UIFontDescriptor.TraitKey.weight: weight(of: font).rawValue],
        ])
        if font.fontDescriptor.symbolicTraits.contains(.traitItalic) {
            descriptor = descriptor.withSymbolicTraits(.traitItalic) ?? descriptor
        }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    /// `font` in the worn theme's face, at the same size and weight.
    static func themed(_ font: UIFont, faces: Faces) -> UIFont {
        guard isSystemFont(font) else { return font }
        guard let face = (isHeading(font) ? faces.heading : nil) ?? faces.body else { return font }
        switch face {
        case .monospaced:
            let narrow = font.withSize((font.pointSize * monospacedScale).rounded())
            return designed(narrow, .monospaced)
        case .serif: return designed(font, .serif)
        case .rounded: return designed(font, .rounded)
        case .family(let family): return named(font, family: family)
        }
    }
}
