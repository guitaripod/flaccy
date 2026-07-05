import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

let S: CGFloat = 1024

func makeContext() -> CGContext {
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: S)
    ctx.scaleBy(x: 1, y: -1)
    return ctx
}

func rgba(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func save(_ ctx: CGContext, _ name: String) {
    let img = ctx.makeImage()!
    let url = URL(fileURLWithPath: "/tmp/flaccy-icon/\(name).png") as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

func glyphPath() -> CGPath {
    let p = CGMutablePath()
    let stemX: CGFloat = 392
    let hookR: CGFloat = 132
    let hookCY: CGFloat = 318
    p.move(to: CGPoint(x: stemX, y: 812))
    p.addLine(to: CGPoint(x: stemX, y: hookCY))
    p.addArc(center: CGPoint(x: stemX + hookR, y: hookCY), radius: hookR,
             startAngle: .pi, endAngle: .pi * 1.5, clockwise: false)
    return p
}

let barY: CGFloat = 548

func crossbarPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 282, y: barY))
    p.addLine(to: CGPoint(x: 522, y: barY))
    return p
}

let ticks: [(x: CGFloat, h: CGFloat)] = [(638, 120), (758, 252), (878, 60)]

func tickPath(_ t: (x: CGFloat, h: CGFloat)) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: t.x, y: barY - t.h / 2))
    p.addLine(to: CGPoint(x: t.x, y: barY + t.h / 2))
    return p
}

func strokedGlyph(lineWidth: CGFloat) -> CGPath {
    let combined = CGMutablePath()
    for path in [glyphPath(), crossbarPath()] + ticks.map(tickPath) {
        combined.addPath(path.copy(strokingWithWidth: lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 10))
    }
    return combined
}

func drawBackground(_ ctx: CGContext, top: UInt32, bottom: UInt32, glow: Bool) {
    let grad = CGGradient(colorsSpace: nil, colors: [rgba(top), rgba(bottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: S), options: [])
    if glow {
        let g = CGGradient(colorsSpace: nil,
                           colors: [rgba(0xFF7A3C, 0.22), rgba(0xFF7A3C, 0.0)] as CFArray,
                           locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: 512, y: 500), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: 500), endRadius: 620, options: [])
    }
}

func drawGlyph(_ ctx: CGContext, gradientColors: [CGColor]) {
    ctx.saveGState()
    ctx.translateBy(x: -58, y: 0)
    let shape = strokedGlyph(lineWidth: 82)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 36, color: rgba(0x000000, 0.45))
    ctx.addPath(shape)
    ctx.setFillColor(rgba(0x000000, 0.001))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let grad = CGGradient(colorsSpace: nil, colors: gradientColors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 380, y: 160), end: CGPoint(x: 660, y: 880),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
    ctx.restoreGState()
}

let warm = [rgba(0xFFC24A), rgba(0xFF4D6D)]

let light = makeContext()
drawBackground(light, top: 0x23242C, bottom: 0x0C0D12, glow: true)
drawGlyph(light, gradientColors: warm)
save(light, "AppIcon")

let dark = makeContext()
drawBackground(dark, top: 0x15161B, bottom: 0x060709, glow: true)
drawGlyph(dark, gradientColors: warm)
save(dark, "AppIcon-Dark")

let tinted = makeContext()
tinted.setFillColor(rgba(0x000000))
tinted.fill(CGRect(x: 0, y: 0, width: S, height: S))
drawGlyph(tinted, gradientColors: [rgba(0xF2F2F2), rgba(0x9A9A9A)])
save(tinted, "AppIcon-Tinted")

let watch = makeContext()
drawBackground(watch, top: 0x23242C, bottom: 0x0C0D12, glow: true)
watch.saveGState()
watch.translateBy(x: S / 2, y: S / 2)
watch.scaleBy(x: 0.86, y: 0.86)
watch.translateBy(x: -S / 2, y: -S / 2)
drawGlyph(watch, gradientColors: warm)
watch.restoreGState()
save(watch, "AppIcon-Watch")

print("done")
