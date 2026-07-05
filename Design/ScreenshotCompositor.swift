import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let W: CGFloat = 1320
let H: CGFloat = 2868

struct Frame {
    let input: String
    let output: String
    let headline: String
    let accentWord: String
}

let frames: [Frame] = [
    Frame(input: "dark-01-library-grid", output: "01-library", headline: "The music you own,\nbeautifully organized", accentWord: "own,"),
    Frame(input: "dark-04-now-playing", output: "02-now-playing", headline: "A player worth\nstaring at", accentWord: "staring"),
    Frame(input: "dark-05-lyrics", output: "03-lyrics", headline: "Synced lyrics.\nTap any line to seek", accentWord: "Synced"),
    Frame(input: "dark-02-library-songs", output: "04-quality", headline: "See exactly what\nyou're playing", accentWord: "exactly"),
    Frame(input: "dark-07-recap-charts", output: "05-recap", headline: "Every play counted.\nOffline too", accentWord: "counted."),
    Frame(input: "dark-08-year-in-music", output: "06-year-in-music", headline: "Your Year in Music,\nready to share", accentWord: "Year in Music,"),
    Frame(input: "dark-09-listening-guide", output: "07-listening-guide", headline: "Honest about\nwhat you hear", accentWord: "Honest"),
    Frame(input: "dark-03-album-detail", output: "08-albums", headline: "Albums treated\nwith respect", accentWord: "respect"),
]

func rgba(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let amber = rgba(0xFFC24A)
let coral = rgba(0xFF4D6D)
let coralSoft = rgba(0xFF7A5C)

func loadImage(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func savePNG(_ image: CGImage, to path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

func attributedHeadline(_ text: String, accent: String, fontSize: CGFloat) -> NSAttributedString {
    let font = CTFontCreateWithName("SFPro-Heavy" as CFString, fontSize, nil)
    let fallback = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
    let usedFont = CTFontCopyPostScriptName(font) as String == "SFPro-Heavy" ? font : CTFontCreateCopyWithSymbolicTraits(fallback!, fontSize, nil, .boldTrait, .boldTrait) ?? fallback!
    let attributed = NSMutableAttributedString(string: text, attributes: [
        kCTFontAttributeName as NSAttributedString.Key: usedFont,
        kCTForegroundColorAttributeName as NSAttributedString.Key: rgba(0xF5F5F7),
        kCTKernAttributeName as NSAttributedString.Key: NSNumber(value: -0.5),
    ])
    if let range = text.range(of: accent) {
        attributed.addAttribute(kCTForegroundColorAttributeName as NSAttributedString.Key, value: coralSoft, range: NSRange(range, in: text))
    }
    var alignment = CTTextAlignment.center
    var lineSpacing: CGFloat = 10
    let settings = [
        CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: &alignment),
        CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: &lineSpacing),
    ]
    let style = CTParagraphStyleCreate(settings, settings.count)
    attributed.addAttribute(kCTParagraphStyleAttributeName as NSAttributedString.Key, value: style, range: NSRange(location: 0, length: attributed.length))
    return attributed
}

func compose(_ frame: Frame, rawDir: String, outDir: String) {
    guard let shot = loadImage("\(rawDir)/\(frame.input).png") else {
        print("MISSING \(frame.input)")
        return
    }
    let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    let bg = CGGradient(colorsSpace: nil, colors: [rgba(0x25262E), rgba(0x0B0C10)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
    let glow = CGGradient(colorsSpace: nil, colors: [rgba(0xFF7A3C, 0.16), rgba(0xFF7A3C, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: W / 2, y: H * 0.42), startRadius: 0,
                           endCenter: CGPoint(x: W / 2, y: H * 0.42), endRadius: 900, options: [])

    let scale: CGFloat = 0.855
    let shotW = W * scale
    let shotH = H * scale
    let shotX = (W - shotW) / 2
    let shotY: CGFloat = 96
    let shotRect = CGRect(x: shotX, y: shotY, width: shotW, height: shotH)
    let radius: CGFloat = 88 * scale

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 80, color: rgba(0x000000, 0.55))
    let framePath = CGPath(roundedRect: shotRect.insetBy(dx: -10, dy: -10), cornerWidth: radius + 10, cornerHeight: radius + 10, transform: nil)
    ctx.addPath(framePath)
    ctx.setFillColor(rgba(0x17181D))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: shotRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    ctx.draw(shot, in: shotRect)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: shotRect.insetBy(dx: -10, dy: -10), cornerWidth: radius + 10, cornerHeight: radius + 10, transform: nil))
    ctx.setStrokeColor(rgba(0xFFFFFF, 0.10))
    ctx.setLineWidth(2)
    ctx.strokePath()
    ctx.restoreGState()

    let headline = attributedHeadline(frame.headline, accent: frame.accentWord, fontSize: 88)
    let textPath = CGMutablePath()
    textPath.addRect(CGRect(x: 90, y: shotY + shotH + 20, width: W - 180, height: H - shotY - shotH - 60))
    let framesetter = CTFramesetterCreateWithAttributedString(headline)
    let textFrame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), textPath, [
        kCTFrameProgressionAttributeName: NSNumber(value: 0)
    ] as CFDictionary)
    ctx.textMatrix = .identity
    CTFrameDraw(textFrame, ctx)

    savePNG(ctx.makeImage()!, to: "\(outDir)/\(frame.output).png")
    print("wrote \(frame.output).png")
}

let rawDir = "/tmp/flaccy-shots/raw"
let outDir = "/tmp/flaccy-shots/final"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for frame in frames { compose(frame, rawDir: rawDir, outDir: outDir) }
