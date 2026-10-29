import CoreGraphics
import CoreImage
import CoreText
import FlaccyCore
import Foundation

/// Everything a lyric clip is drawn from, gathered on the main actor and then
/// handed to a renderer on any thread. `plainLines` is set for lyrics without
/// timing, whose card shows the chosen lines all at once.
nonisolated struct LyricShareScene: @unchecked Sendable {
    var document: LyricsDocument
    var selection: LyricShareSelection
    var plainLines: [String]?
    var window: LyricShareWindow
    var style: LyricShareStyle
    var palette: LyricSharePalette
    var title: String
    var artist: String
    var artwork: CGImage?
    var analysis: LyricShareAnalysis

    var isTimed: Bool {
        plainLines == nil
    }

    var frameCount: Int {
        LyricShareClip.frameCount(window)
    }
}

/// Draws one frame of a lyric clip, or the still card, the way the Linux
/// client's `lyric_share::render` does: the same layout, motion and
/// visualizer from FlaccyCore, painted with Core Graphics and Core Text.
/// Everything that does not move is drawn once into a base image.
nonisolated final class LyricShareRenderer {

    /// How wide the blurred backdrop is before it is stretched over the
    /// canvas, and how soft its blur is at that size.
    static let backdropWidth = 72
    static let backdropSigma = 5.0
    /// How strongly the deep background colour is laid over the backdrop.
    static let backdropShade = 0.45
    /// Where a verse keeps the line being sung, as a share of the lyrics
    /// box from its top, and how far from either edge lines fade out.
    static let verseAnchor = 0.34
    static let verseFade = 120.0
    /// The gap between stacked lines, in lyric sizes.
    static let stackGap = 0.42
    /// The soft edge of the word fill, in canvas pixels.
    static let fillSoftness = 14.0
    /// How fast the pulse disc turns, in radians a second.
    static let discSpin = 0.12

    let scene: LyricShareScene
    let layout: LyricShareLayout
    let scale: CGFloat
    let pixelWidth: Int
    let pixelHeight: Int

    private let sung: [Int]
    private let texts: [String]
    private var base: CGImage?
    private lazy var singleBlocks: [LyricShareTextBlock] = texts.map { text in
        LyricShareTextBlock.fitting(
            text, typeface: scene.style.typeface, size: CGFloat(layout.lyricSize),
            bounds: CGSize(width: layout.lyrics.width, height: layout.lyrics.height),
            alignment: layout.lyricAlignment)
    }
    private lazy var verseBlocks: [LyricShareTextBlock] = {
        let font = LyricShareFonts.font(scene.style.typeface, weight: .lyric, size: CGFloat(layout.lyricSize))
        return texts.map { LyricShareTextBlock(text: $0, font: font, width: CGFloat(layout.lyrics.width), alignment: layout.lyricAlignment) }
    }()
    private lazy var stackBlocks: [LyricShareTextBlock] = fittedStack()
    private lazy var loudestFrame: Int = {
        let levels = scene.analysis.levels
        return levels.indices.max { levels[$0] < levels[$1] } ?? 0
    }()

    /// `scale` is output pixels per canvas pixel: 1 for the export, less for
    /// a preview.
    init(scene: LyricShareScene, scale: CGFloat = 1) {
        self.scene = scene
        self.scale = scale
        let layout = LyricShareLayout.make(
            format: scene.style.format, template: scene.style.template,
            showArtwork: scene.style.showArtwork, showVisualizer: scene.style.showVisualizer)
        self.layout = layout
        pixelWidth = max(Int((CGFloat(layout.width) * scale).rounded()), 1)
        pixelHeight = max(Int((CGFloat(layout.height) * scale).rounded()), 1)
        if let plain = scene.plainLines {
            sung = Array(scene.selection.first...scene.selection.last)
            texts = sung.map { plain[$0] }
        } else {
            sung = LyricShareMotion.lines(of: scene.selection, in: scene.document)
            texts = sung.map { scene.document.lines[$0].text }
        }
    }

    static func makeContext(width: Int, height: Int, data: UnsafeMutableRawPointer? = nil, bytesPerRow: Int = 0) -> CGContext? {
        CGContext(
            data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// The frame as an image, or the still card for nil.
    func image(frame: Int?) -> CGImage? {
        guard let context = Self.makeContext(width: pixelWidth, height: pixelHeight) else { return nil }
        render(frame: frame, into: context)
        return context.makeImage()
    }

    /// Paints a frame into a context of `pixelWidth` by `pixelHeight`.
    func render(frame: Int?, into context: CGContext) {
        if base == nil {
            base = makeBase()
        }
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.interpolationQuality = .high
        if let base {
            drawImage(base, in: CGRect(x: 0, y: 0, width: layout.width, height: layout.height), context: context)
        }
        let time = frame.map { LyricShareClip.time(ofFrame: $0, in: scene.window) }
        let visualFrame = frame ?? loudestFrame
        drawVisualizer(frame: visualFrame, playhead: frame, context: context)
        if scene.style.template == .pulse {
            drawDisc(frame: visualFrame, context: context)
        }
        if let time, scene.isTimed {
            switch scene.style.template {
            case .spotlight, .pulse: drawSingle(at: time, context: context)
            case .verse: drawVerse(at: time, context: context)
            case .poster: drawStack(at: time, context: context)
            }
        } else {
            drawStack(at: nil, context: context)
        }
        context.restoreGState()
    }

    private func makeBase() -> CGImage? {
        guard let context = Self.makeContext(width: pixelWidth, height: pixelHeight) else { return nil }
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.interpolationQuality = .high
        drawBackground(context)
        drawHeader(context)
        drawMark(context)
        if scene.style.template != .pulse, let rect = layout.artwork {
            drawCover(in: cgRect(rect), radius: CGFloat(layout.artworkRadius), context: context)
        }
        return context.makeImage()
    }

    private func drawBackground(_ context: CGContext) {
        let palette = scene.palette
        let canvas = CGRect(x: 0, y: 0, width: layout.width, height: layout.height)
        let colors = [color(palette.background), color(palette.backgroundDeep)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: canvas.height), options: [])
        }
        guard palette.backdrop > 0, let artwork = scene.artwork, let blurred = Self.backdrop(from: artwork, canvas: canvas.size) else { return }
        context.saveGState()
        context.setAlpha(CGFloat(palette.backdrop))
        drawImage(blurred, in: canvas, context: context)
        context.restoreGState()
        context.setFillColor(color(palette.backgroundDeep, alpha: Self.backdropShade))
        context.fill(canvas)
    }

    /// The artwork filled into the canvas's shape at a small size and blurred
    /// there, so stretching it over the canvas is all the softness it needs.
    static func backdrop(from artwork: CGImage, canvas: CGSize) -> CGImage? {
        let width = backdropWidth
        let height = max(Int((CGFloat(width) * canvas.height / canvas.width).rounded()), 1)
        guard let small = makeContext(width: width, height: height) else { return nil }
        small.interpolationQuality = .high
        small.draw(artwork, in: aspectFill(CGSize(width: artwork.width, height: artwork.height), into: CGRect(x: 0, y: 0, width: width, height: height)))
        guard let filled = small.makeImage() else { return nil }
        let input = CIImage(cgImage: filled).clampedToExtent()
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return filled }
        blur.setValue(input, forKey: kCIInputImageKey)
        blur.setValue(backdropSigma, forKey: kCIInputRadiusKey)
        guard let output = blur.outputImage else { return filled }
        let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any])
        return ciContext.createCGImage(output, from: CGRect(x: 0, y: 0, width: width, height: height)) ?? filled
    }

    static func aspectFill(_ size: CGSize, into rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let factor = max(rect.width / size.width, rect.height / size.height)
        let width = size.width * factor
        let height = size.height * factor
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    private func drawHeader(_ context: CGContext) {
        let rect = cgRect(layout.header)
        let typeface = scene.style.typeface
        let titleFont = LyricShareFonts.font(typeface, weight: .title, size: CGFloat(layout.titleSize))
        let artistFont = LyricShareFonts.font(typeface, weight: .artist, size: CGFloat(layout.artistSize))
        let titleLine = truncatedLine(scene.title, font: titleFont, width: rect.width)
        let artistLine = truncatedLine(scene.artist, font: artistFont, width: rect.width)
        let titleHeight = CTFontGetAscent(titleFont) + CTFontGetDescent(titleFont)
        let artistHeight = CTFontGetAscent(artistFont) + CTFontGetDescent(artistFont)
        let gap: CGFloat = 8
        var top = rect.midY - (titleHeight + gap + artistHeight) / 2
        context.setFillColor(color(scene.palette.ink))
        drawLine(titleLine, font: titleFont, top: top, in: rect, context: context)
        top += titleHeight + gap
        context.setFillColor(color(scene.palette.ink, alpha: 0.72))
        drawLine(artistLine, font: artistFont, top: top, in: rect, context: context)
    }

    private func drawMark(_ context: CGContext) {
        guard scene.style.showMark else { return }
        let rect = cgRect(layout.mark)
        let font = LyricShareFonts.font(.modern, weight: .mark, size: CGFloat(layout.markSize))
        let line = truncatedLine("Flaccy", font: font, width: rect.width)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let height = CTFontGetAscent(font) + CTFontGetDescent(font)
        context.setFillColor(color(scene.palette.ink, alpha: 0.55))
        context.textPosition = CGPoint(x: rect.maxX - width, y: rect.midY - height / 2 + CTFontGetAscent(font))
        CTLineDraw(line, context)
    }

    private func truncatedLine(_ text: String, font: CTFont, width: CGFloat) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: attributes))
        return CTLineCreateTruncatedLine(line, Double(width), .end, ellipsis) ?? line
    }

    private func drawLine(_ line: CTLine, font: CTFont, top: CGFloat, in rect: CGRect, context: CGContext) {
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let x = layout.headerAlignment == .center ? rect.midX - width / 2 : rect.minX
        context.textPosition = CGPoint(x: x, y: top + CTFontGetAscent(font))
        CTLineDraw(line, context)
    }

    /// The cover with rounded corners and a soft shadow, or a gradient tile
    /// with a note when the track has no cover.
    private func drawCover(in rect: CGRect, radius: CGFloat, context: CGContext) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: rect.width * 0.03), blur: rect.width * 0.08, color: color(LyricShareColor(hex: 0), alpha: 0.45))
        context.addPath(path)
        context.setFillColor(color(scene.palette.backgroundDeep))
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(path)
        context.clip()
        if let artwork = scene.artwork {
            drawImage(artwork, in: Self.aspectFill(CGSize(width: artwork.width, height: artwork.height), into: rect), context: context)
        } else {
            drawPlaceholder(in: rect, context: context)
        }
        context.restoreGState()
    }

    private func drawPlaceholder(in rect: CGRect, context: CGContext) {
        let colors = [color(scene.palette.accent), color(scene.palette.backgroundDeep)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
        }
        let font = LyricShareFonts.font(.modern, weight: .title, size: rect.width * 0.42)
        let line = truncatedLine("\u{266A}", font: font, width: rect.width)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.setFillColor(color(scene.palette.ink, alpha: 0.8))
        context.textPosition = CGPoint(x: rect.midX - width / 2, y: rect.midY + CTFontGetAscent(font) * 0.36)
        CTLineDraw(line, context)
    }

    private func drawDisc(frame: Int, context: CGContext) {
        guard let rect = layout.artwork else { return }
        let level = Double(scene.analysis.level(at: frame))
        let radius = CGFloat(layout.artworkRadius * (1 + LyricShareVisualizer.discPulse * level))
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let disc = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
        context.saveGState()
        context.setShadow(offset: .zero, blur: radius * 0.35, color: color(scene.palette.accent, alpha: 0.35 + 0.4 * level))
        context.addEllipse(in: disc)
        context.setFillColor(color(scene.palette.backgroundDeep))
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addEllipse(in: disc)
        context.clip()
        if scene.style.showArtwork, let artwork = scene.artwork {
            let angle = Self.discSpin * Double(frame) / Double(LyricShareClip.fps)
            context.translateBy(x: centre.x, y: centre.y)
            context.rotate(by: CGFloat(angle))
            let side = radius * 2
            drawImage(
                artwork,
                in: Self.aspectFill(CGSize(width: artwork.width, height: artwork.height), into: CGRect(x: -side / 2, y: -side / 2, width: side, height: side)),
                context: context)
        } else {
            let colors = [color(scene.palette.accent), color(scene.palette.backgroundDeep)] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                context.drawRadialGradient(
                    gradient, startCenter: CGPoint(x: centre.x - radius * 0.3, y: centre.y - radius * 0.3), startRadius: 0,
                    endCenter: centre, endRadius: radius, options: [])
            }
        }
        context.restoreGState()
        context.addEllipse(in: disc.insetBy(dx: 1, dy: 1))
        context.setStrokeColor(color(scene.palette.ink, alpha: 0.14))
        context.setLineWidth(2)
        context.strokePath()
    }

    private func drawVisualizer(frame: Int, playhead: Int?, context: CGContext) {
        guard let rect = layout.visualizer else { return }
        switch scene.style.template {
        case .pulse: drawRing(LyricShareVisualizer.ring(scene.analysis.bands(at: frame)), frame: frame, context: context)
        case .poster: drawWave(in: cgRect(rect), playhead: playhead, context: context)
        case .spotlight, .verse: drawStrip(LyricShareVisualizer.strip(scene.analysis.bands(at: frame)), in: cgRect(rect), context: context)
        }
    }

    private func drawStrip(_ values: [Float], in rect: CGRect, context: CGContext) {
        guard !values.isEmpty else { return }
        let slot = rect.width / CGFloat(values.count)
        let width = slot * CGFloat(1 - LyricShareVisualizer.gapRatio)
        context.setFillColor(color(scene.palette.accent, alpha: 0.85))
        for (index, value) in values.enumerated() {
            let height = rect.height * CGFloat(max(Double(value), LyricShareVisualizer.minimumBar))
            let bar = CGRect(x: rect.minX + slot * CGFloat(index) + (slot - width) / 2, y: rect.midY - height / 2, width: width, height: height)
            context.addPath(CGPath(roundedRect: bar, cornerWidth: width / 2, cornerHeight: min(width / 2, height / 2), transform: nil))
        }
        context.fillPath()
    }

    /// The whole clip's loudness as a slim waveform, lit up to the playhead.
    private func drawWave(in rect: CGRect, playhead: Int?, context: CGContext) {
        let levels = scene.analysis.levels
        guard !levels.isEmpty else { return }
        let columns = 96
        let slot = rect.width / CGFloat(columns)
        let width = slot * CGFloat(1 - LyricShareVisualizer.gapRatio)
        let lit = playhead.map { CGFloat($0) / CGFloat(max(levels.count, 1)) } ?? 1
        for column in 0..<columns {
            let from = column * levels.count / columns
            let to = max((column + 1) * levels.count / columns, from + 1)
            let level = levels[from..<min(to, levels.count)].max() ?? 0
            let height = rect.height * CGFloat(max(Double(level), LyricShareVisualizer.minimumBar))
            let bar = CGRect(x: rect.minX + slot * CGFloat(column) + (slot - width) / 2, y: rect.midY - height / 2, width: width, height: height)
            let played = CGFloat(column) / CGFloat(columns) < lit
            context.setFillColor(played ? color(scene.palette.accent, alpha: 0.9) : color(scene.palette.ink, alpha: 0.22))
            context.addPath(CGPath(roundedRect: bar, cornerWidth: width / 2, cornerHeight: min(width / 2, height / 2), transform: nil))
            context.fillPath()
        }
    }

    private func drawRing(_ values: [Float], frame: Int, context: CGContext) {
        guard let rect = layout.artwork, !values.isEmpty else { return }
        let level = Double(scene.analysis.level(at: frame))
        let radius = layout.artworkRadius * (1 + LyricShareVisualizer.discPulse * level)
        let inner = radius * LyricShareVisualizer.ringInner
        let width = 2 * Double.pi * inner / Double(values.count) * (1 - LyricShareVisualizer.gapRatio)
        context.saveGState()
        context.setLineCap(.round)
        context.setLineWidth(CGFloat(width))
        context.setStrokeColor(color(scene.palette.accent, alpha: 0.85))
        for (index, value) in values.enumerated() {
            let angle = -Double.pi / 2 + 2 * Double.pi * Double(index) / Double(values.count)
            let length = radius * LyricShareVisualizer.ringLength * max(Double(value), LyricShareVisualizer.minimumBar)
            let from = CGPoint(x: rect.midX + CGFloat(cos(angle) * inner), y: rect.midY + CGFloat(sin(angle) * inner))
            let to = CGPoint(x: rect.midX + CGFloat(cos(angle) * (inner + length)), y: rect.midY + CGFloat(sin(angle) * (inner + length)))
            context.move(to: from)
            context.addLine(to: to)
        }
        context.strokePath()
        context.restoreGState()
    }

    /// One line at a time: the line being sung rises into place as the one
    /// before it rises away.
    private func drawSingle(at time: Double, context: CGContext) {
        let focus = LyricShareMotion.focus(scene.selection, in: scene.document, at: time, clipStart: scene.window.lyricStart)
        let box = cgRect(layout.lyrics)
        for rank in [focus.rank - 1, focus.rank] where rank >= 0 {
            let opacity = LyricShareMotion.ink(rank: rank, focus: focus, template: scene.style.template)
            guard opacity > 0.002 else { continue }
            let block = singleBlocks[rank]
            let rise = CGFloat(LyricShareMotion.rise) * block.fontSize
            let shift = rank == focus.rank ? (1 - CGFloat(focus.entrance)) * rise : -CGFloat(focus.entrance) * rise
            let origin = CGPoint(x: box.minX, y: box.midY - block.size.height / 2 + shift)
            let line = scene.document.lines[sung[rank]]
            let progress = rank == focus.rank ? line.progress(at: time) : (line.hasWords ? .done : nil)
            drawLyric(block, line: line, progress: progress, at: origin, opacity: opacity, context: context)
        }
    }

    /// The selected lines scrolling past, the one being sung held near the
    /// top third.
    private func drawVerse(at time: Double, context: CGContext) {
        let focus = LyricShareMotion.focus(scene.selection, in: scene.document, at: time, clipStart: scene.window.lyricStart)
        let box = cgRect(layout.lyrics)
        let blocks = verseBlocks
        let gap = CGFloat(layout.lyricSize * Self.stackGap)
        var tops: [CGFloat] = []
        var top: CGFloat = 0
        for block in blocks {
            tops.append(top)
            top += block.size.height + gap
        }
        let position = LyricShareMotion.scrollPosition(focus)
        let lower = min(Int(position.rounded(.down)), tops.count - 1)
        let upper = min(lower + 1, tops.count - 1)
        let fraction = CGFloat(position - Double(lower))
        let scroll = tops[lower] + (tops[upper] - tops[lower]) * fraction
        let anchor = box.minY + box.height * CGFloat(Self.verseAnchor)
        context.saveGState()
        context.clip(to: box.insetBy(dx: -40, dy: 0))
        for (rank, block) in blocks.enumerated() {
            let y = anchor + tops[rank] - scroll
            guard y + block.size.height > box.minY, y < box.maxY else { continue }
            let nearest = min(y + block.size.height - box.minY, box.maxY - y)
            let fade = min(max(nearest / CGFloat(Self.verseFade), 0), 1)
            let line = scene.document.lines[sung[rank]]
            let opacity = LyricShareMotion.ink(rank: rank, focus: focus, template: .verse) * Double(fade)
            let progress: LyricsLineProgress? = rank == focus.rank ? line.progress(at: time) : nil
            drawLyric(block, line: line, progress: progress, at: CGPoint(x: box.minX, y: y), opacity: opacity, fade: Double(fade), context: context)
        }
        context.restoreGState()
    }

    /// Every chosen line at once, fitted to the box: a poster lighting them as
    /// they are sung, or the still card with all of them lit.
    private func drawStack(at time: Double?, context: CGContext) {
        let box = cgRect(layout.lyrics)
        let blocks = stackBlocks
        guard let first = blocks.first else { return }
        let gap = first.fontSize * CGFloat(Self.stackGap)
        let total = blocks.reduce(0) { $0 + $1.size.height } + gap * CGFloat(blocks.count - 1)
        var y = box.midY - total / 2
        let focus = time.map { LyricShareMotion.focus(scene.selection, in: scene.document, at: $0, clipStart: scene.window.lyricStart) }
        for (rank, block) in blocks.enumerated() {
            let origin = CGPoint(x: box.minX, y: y)
            if let focus, let time, scene.isTimed {
                let line = scene.document.lines[sung[rank]]
                let opacity = LyricShareMotion.ink(rank: rank, focus: focus, template: .poster)
                let progress: LyricsLineProgress? = rank == focus.rank ? line.progress(at: time) : nil
                drawLyric(block, line: line, progress: progress, at: origin, opacity: opacity, context: context)
            } else {
                context.setFillColor(color(scene.palette.ink))
                block.draw(in: context, at: origin)
            }
            y += block.size.height + gap
        }
    }

    /// The chosen lines laid out at one size small enough for all of them.
    private func fittedStack() -> [LyricShareTextBlock] {
        let box = layout.lyrics
        var size = CGFloat(layout.lyricSize)
        let smallest = size * CGFloat(LyricShareLayout.minimumLyricScale)
        while true {
            let font = LyricShareFonts.font(scene.style.typeface, weight: .lyric, size: size)
            let blocks = texts.map { LyricShareTextBlock(text: $0, font: font, width: CGFloat(box.width), alignment: layout.lyricAlignment) }
            let gap = size * CGFloat(Self.stackGap)
            let total = blocks.reduce(0) { $0 + $1.size.height } + gap * CGFloat(max(blocks.count - 1, 0))
            if total <= CGFloat(box.height) || size <= smallest {
                return blocks
            }
            size = max(size * 0.92, smallest)
        }
    }

    /// A lyric line at `opacity`. A line with timed words that is being sung
    /// fills from dim to bright through the word under the clock, with a soft
    /// edge; a line without timed words is drawn at `opacity` alone.
    private func drawLyric(
        _ block: LyricShareTextBlock, line: LyricsLine, progress: LyricsLineProgress?, at origin: CGPoint,
        opacity: Double, fade: Double = 1, context: CGContext
    ) {
        let ink = scene.palette.ink
        guard line.hasWords, let progress else {
            context.setFillColor(color(ink, alpha: opacity))
            block.draw(in: context, at: origin)
            return
        }
        let dim = LyricShareMotion.dim * fade
        switch progress {
        case .notStarted:
            context.setFillColor(color(ink, alpha: min(opacity, dim)))
            block.draw(in: context, at: origin)
        case .done:
            context.setFillColor(color(ink, alpha: opacity))
            block.draw(in: context, at: origin)
        case .singing(let word, let fraction):
            let bright = scene.style.template == .spotlight || scene.style.template == .pulse ? opacity : fade
            context.setFillColor(color(ink, alpha: min(opacity, dim)))
            block.draw(in: context, at: origin)
            let edge = fillEdge(block, line: line, word: word, fraction: fraction)
            paintFill(block, upTo: edge, at: origin, alpha: bright, context: context)
        }
    }

    private func fillEdge(_ block: LyricShareTextBlock, line: LyricsLine, word: Int, fraction: Double) -> (row: Int, x: CGFloat) {
        var offset = 0
        for index in 0..<word {
            offset += line.words[index].text.utf16.count
        }
        let text = line.words[word].text
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let start = block.position(ofOffset: offset)
        let end = block.position(ofOffset: offset + max(trimmed.utf16.count, 1))
        guard end.row == start.row else { return (start.row, start.x + CGFloat(fraction) * (block.rows[start.row].x + block.rows[start.row].width - start.x)) }
        return (start.row, start.x + (end.x - start.x) * CGFloat(fraction))
    }

    private func paintFill(_ block: LyricShareTextBlock, upTo edge: (row: Int, x: CGFloat), at origin: CGPoint, alpha: Double, context: CGContext) {
        let softness = CGFloat(Self.fillSoftness)
        let slices = 4
        for row in 0...edge.row {
            let rect = block.rowRect(row, at: origin)
            if row < edge.row {
                paint(block, clip: rect, alpha: alpha, origin: origin, context: context)
                continue
            }
            let x = origin.x + edge.x
            let solid: CGRect
            if block.isRightToLeft {
                solid = CGRect(x: x + softness, y: rect.minY, width: max(rect.maxX - x - softness, 0), height: rect.height)
            } else {
                solid = CGRect(x: rect.minX, y: rect.minY, width: max(x - softness - rect.minX, 0), height: rect.height)
            }
            paint(block, clip: solid, alpha: alpha, origin: origin, context: context)
            for slice in 0..<slices {
                let width = softness / CGFloat(slices)
                let sliceX = block.isRightToLeft ? x + softness - width * CGFloat(slice + 1) : x - softness + width * CGFloat(slice)
                let strength = 1 - (Double(slice) + 0.5) / Double(slices)
                paint(block, clip: CGRect(x: sliceX, y: rect.minY, width: width, height: rect.height), alpha: alpha * strength, origin: origin, context: context)
            }
        }
    }

    private func paint(_ block: LyricShareTextBlock, clip: CGRect, alpha: Double, origin: CGPoint, context: CGContext) {
        guard clip.width > 0, clip.height > 0 else { return }
        context.saveGState()
        context.clip(to: clip)
        context.setFillColor(color(scene.palette.ink, alpha: alpha))
        block.draw(in: context, at: origin)
        context.restoreGState()
    }

    /// Draws an image right way up in the renderer's y-down space.
    private func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }

    private func cgRect(_ rect: LyricShareRect) -> CGRect {
        CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    private func color(_ value: LyricShareColor, alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: value.red, green: value.green, blue: value.blue, alpha: min(max(alpha, 0), 1))
    }
}

/// What a lyric clip takes from the cover: a grid of colour samples for the
/// palette.
nonisolated enum LyricShareArtwork {

    static let sampleGrid = 12

    static func samples(from image: CGImage) -> [LyricShareColor] {
        let side = sampleGrid
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return [] }
        return stride(from: 0, to: pixels.count, by: 4).map { index in
            LyricShareColor(red: Double(pixels[index]) / 255, green: Double(pixels[index + 1]) / 255, blue: Double(pixels[index + 2]) / 255)
        }
    }
}
