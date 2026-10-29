import Foundation

/// How a lyric clip moves: one line at a time, the verse scrolling past, a
/// poster that lights line by line, or a disc that breathes with the music.
public enum LyricShareTemplate: String, CaseIterable, Sendable {
    case spotlight
    case verse
    case poster
    case pulse
}

/// The canvas a clip is made for, named after where people post it.
public enum LyricShareFormat: String, CaseIterable, Sendable {
    case story
    case portrait
    case square
    case wide

    public var pixelWidth: Int {
        self == .wide ? 1920 : 1080
    }

    public var pixelHeight: Int {
        switch self {
        case .story: return 1920
        case .portrait: return 1350
        case .square, .wide: return 1080
        }
    }
}

/// Where a clip's colours come from.
public enum LyricShareTheme: String, CaseIterable, Sendable {
    case artwork
    case vivid
    case dark
    case light
}

/// The family the lyrics are set in. Each client maps it onto its own fonts.
public enum LyricShareTypeface: String, CaseIterable, Sendable {
    case modern
    case serif
    case rounded
    case mono
}

/// Every choice a person makes about a lyric clip apart from which lines it
/// holds. Mirrored in Rust as `linux/shared/src/lyric_share/style.rs`.
public struct LyricShareStyle: Sendable, Equatable {
    public var template: LyricShareTemplate
    public var format: LyricShareFormat
    public var theme: LyricShareTheme
    public var typeface: LyricShareTypeface
    public var showArtwork: Bool
    public var showVisualizer: Bool
    public var showMark: Bool

    public init(
        template: LyricShareTemplate = .spotlight,
        format: LyricShareFormat = .story,
        theme: LyricShareTheme = .artwork,
        typeface: LyricShareTypeface = .modern,
        showArtwork: Bool = true,
        showVisualizer: Bool = true,
        showMark: Bool = true
    ) {
        self.template = template
        self.format = format
        self.theme = theme
        self.typeface = typeface
        self.showArtwork = showArtwork
        self.showVisualizer = showVisualizer
        self.showMark = showMark
    }

    public static let standard = LyricShareStyle()

    /// The style as one line of `key=value` pairs, the form every client
    /// remembers the last clip's look in.
    public var encoded: String {
        [
            "template=\(template.rawValue)",
            "format=\(format.rawValue)",
            "theme=\(theme.rawValue)",
            "typeface=\(typeface.rawValue)",
            "artwork=\(showArtwork ? 1 : 0)",
            "visualizer=\(showVisualizer ? 1 : 0)",
            "mark=\(showMark ? 1 : 0)",
        ].joined(separator: ";")
    }

    /// Reads what `encoded` wrote. Anything unknown or malformed keeps the
    /// standard value, so a style saved by a newer build still opens.
    public init(encoded: String) {
        self.init()
        for pair in encoded.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let value = parts[1]
            switch parts[0] {
            case "template": template = LyricShareTemplate(rawValue: value) ?? template
            case "format": format = LyricShareFormat(rawValue: value) ?? format
            case "theme": theme = LyricShareTheme(rawValue: value) ?? theme
            case "typeface": typeface = LyricShareTypeface(rawValue: value) ?? typeface
            case "artwork": showArtwork = Self.flag(value) ?? showArtwork
            case "visualizer": showVisualizer = Self.flag(value) ?? showVisualizer
            case "mark": showMark = Self.flag(value) ?? showMark
            default: continue
            }
        }
    }

    private static func flag(_ value: String) -> Bool? {
        switch value {
        case "1": return true
        case "0": return false
        default: return nil
        }
    }
}
