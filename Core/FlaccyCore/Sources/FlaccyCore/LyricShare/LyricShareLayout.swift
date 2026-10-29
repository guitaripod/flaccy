import Foundation

/// A rectangle in canvas pixels, the origin at the top left.
public struct LyricShareRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

public enum LyricShareAlignment: Sendable, Equatable {
    case leading
    case center
}

/// Where everything sits on a clip's canvas. `artwork` is the cover, or for
/// pulse the disc whether or not a cover is drawn on it; `visualizer` is the
/// strip of bars, or for pulse the square the ring fills. Mirrored in Rust as
/// `linux/shared/src/lyric_share/layout.rs`.
public struct LyricShareLayout: Sendable, Equatable {
    public var width: Double
    public var height: Double
    public var artwork: LyricShareRect?
    public var artworkRadius: Double
    public var header: LyricShareRect
    public var headerAlignment: LyricShareAlignment
    public var titleSize: Double
    public var artistSize: Double
    public var lyrics: LyricShareRect
    public var lyricSize: Double
    public var lyricAlignment: LyricShareAlignment
    public var visualizer: LyricShareRect?
    public var mark: LyricShareRect
    public var markSize: Double

    public static let markHeight = 40.0
    public static let markGap = 28.0
    public static let markSize = 28.0
    public static let stripHeight = 112.0
    public static let stripGap = 40.0
    public static let waveHeight = 56.0
    public static let waveGap = 32.0
    public static let headerGap = 48.0
    public static let headerHeight = 100.0
    /// The most a line of lyrics may shrink below the template's size to fit.
    public static let minimumLyricScale = 0.55

    /// The part of the canvas content stays inside, clear of the buttons and
    /// captions that apps lay over a post in each format.
    public static func safeArea(_ format: LyricShareFormat) -> LyricShareRect {
        switch format {
        case .story: return LyricShareRect(x: 84, y: 220, width: 912, height: 1420)
        case .portrait: return LyricShareRect(x: 84, y: 96, width: 912, height: 1158)
        case .square: return LyricShareRect(x: 80, y: 80, width: 920, height: 920)
        case .wide: return LyricShareRect(x: 120, y: 96, width: 1680, height: 888)
        }
    }

    public static func baseLyricSize(_ template: LyricShareTemplate, _ format: LyricShareFormat) -> Double {
        let sizes: [Double]
        switch template {
        case .spotlight: sizes = [88, 76, 68, 72]
        case .verse: sizes = [64, 58, 54, 56]
        case .poster: sizes = [54, 46, 42, 50]
        case .pulse: sizes = [64, 54, 48, 56]
        }
        return sizes[LyricShareFormat.allCases.firstIndex(of: format) ?? 0]
    }

    public static func make(
        format: LyricShareFormat, template: LyricShareTemplate, showArtwork: Bool, showVisualizer: Bool
    ) -> LyricShareLayout {
        let safe = safeArea(format)
        let mark = LyricShareRect(x: safe.x, y: safe.maxY - markHeight, width: safe.width, height: markHeight)
        let content = LyricShareRect(
            x: safe.x, y: safe.y, width: safe.width, height: safe.height - markHeight - markGap
        )
        var layout = LyricShareLayout(
            width: Double(format.pixelWidth),
            height: Double(format.pixelHeight),
            artwork: nil,
            artworkRadius: 28,
            header: content,
            headerAlignment: .center,
            titleSize: 44,
            artistSize: 34,
            lyrics: content,
            lyricSize: baseLyricSize(template, format),
            lyricAlignment: .center,
            visualizer: nil,
            mark: mark,
            markSize: markSize
        )
        if format == .wide {
            layoutWide(&layout, content: content, template: template, showArtwork: showArtwork, showVisualizer: showVisualizer)
        } else {
            switch template {
            case .spotlight, .verse:
                layoutStack(&layout, content: content, format: format, template: template, showArtwork: showArtwork, showVisualizer: showVisualizer)
            case .poster:
                layoutPoster(&layout, content: content, showArtwork: showArtwork, showVisualizer: showVisualizer)
            case .pulse:
                layoutPulse(&layout, content: content, format: format, showVisualizer: showVisualizer)
            }
        }
        if template == .poster && !showArtwork {
            layout.lyricSize *= 1.25
        }
        return layout
    }

    /// A header row with a small cover beside the title, the lyrics under it
    /// and the bars along the bottom.
    private static func layoutStack(
        _ layout: inout LyricShareLayout, content: LyricShareRect, format: LyricShareFormat,
        template: LyricShareTemplate, showArtwork: Bool, showVisualizer: Bool
    ) {
        var bottom = content.maxY
        if showVisualizer {
            layout.visualizer = LyricShareRect(
                x: content.x, y: content.maxY - stripHeight, width: content.width, height: stripHeight
            )
            bottom -= stripHeight + stripGap
        }
        if showArtwork {
            let thumb = format == .square ? 112.0 : 128.0
            layout.artwork = LyricShareRect(x: content.x, y: content.y, width: thumb, height: thumb)
            layout.artworkRadius = 20
            layout.header = LyricShareRect(
                x: content.x + thumb + 28, y: content.y, width: content.width - thumb - 28, height: thumb
            )
        } else {
            layout.header = LyricShareRect(x: content.x, y: content.y, width: content.width, height: 96)
        }
        layout.headerAlignment = .leading
        layout.titleSize = 40
        layout.artistSize = 32
        let top = layout.header.maxY + headerGap
        layout.lyrics = LyricShareRect(x: content.x, y: top, width: content.width, height: bottom - top)
        layout.lyricAlignment = template == .spotlight ? .center : .leading
    }

    /// A large cover at the top, the title under it and the lyrics under
    /// that, with a slim waveform at the foot.
    private static func layoutPoster(
        _ layout: inout LyricShareLayout, content: LyricShareRect, showArtwork: Bool, showVisualizer: Bool
    ) {
        var bottom = content.maxY
        if showVisualizer {
            layout.visualizer = LyricShareRect(
                x: content.x + content.width * 0.15, y: content.maxY - waveHeight,
                width: content.width * 0.7, height: waveHeight
            )
            bottom -= waveHeight + waveGap
        }
        if showArtwork {
            let side = min(content.width, (bottom - content.y) * 0.46).rounded()
            let artwork = LyricShareRect(x: content.midX - side / 2, y: content.y, width: side, height: side)
            layout.artwork = artwork
            layout.header = LyricShareRect(x: content.x, y: artwork.maxY + 36, width: content.width, height: headerHeight)
        } else {
            layout.header = LyricShareRect(x: content.x, y: content.y, width: content.width, height: headerHeight)
        }
        let top = layout.header.maxY + 36
        layout.lyrics = LyricShareRect(x: content.x, y: top, width: content.width, height: bottom - top)
    }

    /// The title at the top, the disc and its ring under it, the line below.
    private static func layoutPulse(
        _ layout: inout LyricShareLayout, content: LyricShareRect, format: LyricShareFormat, showVisualizer: Bool
    ) {
        layout.header = LyricShareRect(x: content.x, y: content.y, width: content.width, height: headerHeight)
        let factor = format == .story ? 0.25 : 0.19
        let radius = (min(content.width, content.height) * factor).rounded()
        let ring = radius * (LyricShareVisualizer.ringInner + LyricShareVisualizer.ringLength)
        let centreY = layout.header.maxY + 56 + ring
        placeDisc(&layout, centreX: content.midX, centreY: centreY, radius: radius, showVisualizer: showVisualizer)
        let top = centreY + ring + 40
        layout.lyrics = LyricShareRect(x: content.x, y: top, width: content.width, height: content.maxY - top)
    }

    /// Landscape: the cover or the disc on the left, the words on the right.
    private static func layoutWide(
        _ layout: inout LyricShareLayout, content: LyricShareRect, template: LyricShareTemplate,
        showArtwork: Bool, showVisualizer: Bool
    ) {
        let left = LyricShareRect(x: content.x, y: content.y, width: 640, height: content.height)
        let right = LyricShareRect(
            x: content.x + 640 + 96, y: content.y, width: content.width - 736, height: content.height
        )
        if template == .pulse {
            let radius = (min(left.width, left.height) / 2
                / (LyricShareVisualizer.ringInner + LyricShareVisualizer.ringLength) * 0.96).rounded()
            placeDisc(&layout, centreX: left.midX, centreY: left.midY, radius: radius, showVisualizer: showVisualizer)
            layout.header = LyricShareRect(x: right.x, y: right.y, width: right.width, height: headerHeight)
            layout.headerAlignment = .leading
            let top = layout.header.maxY + headerGap
            layout.lyrics = LyricShareRect(x: right.x, y: top, width: right.width, height: right.maxY - top)
            layout.lyricAlignment = .leading
            return
        }
        var text: LyricShareRect
        if showArtwork {
            let side = min(left.width, left.height - 136)
            let artwork = LyricShareRect(x: left.x, y: left.y + (left.height - side - 136) / 2, width: side, height: side)
            layout.artwork = artwork
            layout.header = LyricShareRect(x: left.x, y: artwork.maxY + 36, width: left.width, height: headerHeight)
            layout.headerAlignment = .center
            text = right
        } else {
            layout.header = LyricShareRect(x: content.x, y: content.y, width: content.width, height: headerHeight)
            layout.headerAlignment = .leading
            let top = layout.header.maxY + headerGap
            text = LyricShareRect(x: content.x, y: top, width: content.width, height: content.maxY - top)
        }
        if showVisualizer {
            if template == .poster {
                layout.visualizer = LyricShareRect(
                    x: text.x + text.width * 0.15, y: text.maxY - waveHeight, width: text.width * 0.7, height: waveHeight
                )
                text.height -= waveHeight + waveGap
            } else {
                layout.visualizer = LyricShareRect(x: text.x, y: text.maxY - stripHeight, width: text.width, height: stripHeight)
                text.height -= stripHeight + stripGap
            }
        }
        layout.lyrics = text
        layout.lyricAlignment = template == .spotlight ? .center : .leading
    }

    private static func placeDisc(
        _ layout: inout LyricShareLayout, centreX: Double, centreY: Double, radius: Double, showVisualizer: Bool
    ) {
        layout.artwork = LyricShareRect(x: centreX - radius, y: centreY - radius, width: radius * 2, height: radius * 2)
        layout.artworkRadius = radius
        if showVisualizer {
            let ring = radius * (LyricShareVisualizer.ringInner + LyricShareVisualizer.ringLength)
            layout.visualizer = LyricShareRect(x: centreX - ring, y: centreY - ring, width: ring * 2, height: ring * 2)
        }
    }
}

/// The name a shared clip or card is saved under.
public enum LyricShareNaming {

    public static let maximumLength = 120

    /// "Artist – Title (Lyrics).ext", with the characters no file system
    /// accepts and control characters dropped, runs of spaces collapsed and
    /// the name before " (Lyrics)" cut to `maximumLength` characters.
    public static func fileName(title: String, artist: String, fileExtension: String) -> String {
        let cleanTitle = clean(title)
        let cleanArtist = clean(artist)
        var stem: String
        switch (cleanArtist.isEmpty, cleanTitle.isEmpty) {
        case (false, false): stem = "\(cleanArtist) \u{2013} \(cleanTitle)"
        case (true, false): stem = cleanTitle
        case (false, true): stem = cleanArtist
        case (true, true): stem = "Flaccy"
        }
        if stem.unicodeScalars.count > maximumLength {
            stem = LyricsText.trimEnd(LyricsText.string(stem.unicodeScalars.prefix(maximumLength)))
        }
        return "\(stem) (Lyrics).\(fileExtension)"
    }

    private static let forbidden: Set<Unicode.Scalar> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]

    private static func clean(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if LyricsText.isWhitespace(scalar) {
                pendingSpace = !out.isEmpty
                continue
            }
            if forbidden.contains(scalar) || scalar.properties.generalCategory == .control {
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(scalar)
        }
        return String(out)
    }
}
