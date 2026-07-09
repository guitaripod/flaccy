import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let shots = ["dark-01-library-grid", "dark-04-now-playing", "dark-06-queue", "dark-10-settings"]
let rawDir = "/tmp/flaccy-shots/raw"
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "screenshot.png"

func rgba(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func load(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

let images = shots.compactMap { load("\(rawDir)/\($0).png") }
guard let first = images.first else { fatalError("no raw shots at \(rawDir)") }

let shotW = CGFloat(first.width)
let shotH = CGFloat(first.height)
let scale: CGFloat = 0.5
let cellW = shotW * scale
let cellH = shotH * scale
let gap: CGFloat = 60
let margin: CGFloat = 90
let radius: CGFloat = 56

let W = margin * 2 + cellW * CGFloat(images.count) + gap * CGFloat(images.count - 1)
let H = margin * 2 + cellH

let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

let bg = CGGradient(colorsSpace: nil, colors: [rgba(0x25262E), rgba(0x0B0C10)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
let glow = CGGradient(colorsSpace: nil, colors: [rgba(0xFF7A3C, 0.14), rgba(0xFF7A3C, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: W / 2, y: H / 2), startRadius: 0,
                       endCenter: CGPoint(x: W / 2, y: H / 2), endRadius: W * 0.5, options: [])

for (index, image) in images.enumerated() {
    let x = margin + CGFloat(index) * (cellW + gap)
    let rect = CGRect(x: x, y: margin, width: cellW, height: cellH)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 60, color: rgba(0x000000, 0.5))
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(rgba(0x17181D))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    ctx.draw(image, in: rect)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setStrokeColor(rgba(0xFFFFFF, 0.08))
    ctx.setLineWidth(2)
    ctx.strokePath()
    ctx.restoreGState()
}

let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("wrote \(output) (\(Int(W))x\(Int(H)))")
