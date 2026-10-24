import CoreGraphics
import CoreText
import FlaccyCore
import Foundation

/// Draws the response curve for the iPhone and the Mac from the same code, so a
/// point, a glow and a label look the same on both. Everything is Core Graphics
/// and Core Text in a coordinate space whose y axis grows downward: UIKit views
/// already are, and the Mac view sets `isFlipped`.
enum EqualizerPlotRenderer {

    struct Style {
        var accent: CGColor
        var cut: CGColor
        var bandColors: [CGColor]
        var highContrast = false
        var isEnabled = true
        var isComparing = false
    }

    /// `preview` is the curve of a preset being auditioned, already placed on
    /// the plot (see `EqualizerPlotModel.curvePoints`). It is drawn as the line
    /// being heard, with the curve in force left behind as a thin dashed
    /// reference and the nodes stepped back.
    static func draw(in context: CGContext, bounds: CGRect, plot: CGRect, model: EqualizerPlotModel, style: Style, preview: [CGPoint]? = nil) {
        drawGrid(in: context, plot: plot, style: style)

        context.saveGState()
        context.setAlpha(style.isEnabled || preview != nil ? 1 : 0.45)
        drawSpectrum(in: context, plot: plot, model: model)
        if model.content.mode == .advanced { drawSelectedBand(in: context, plot: plot, model: model, style: style) }
        drawCurve(in: context, plot: plot, model: model, style: style, preview: preview)
        context.restoreGState()

        if model.content.mode == .simple { drawActiveColumn(in: context, plot: plot, model: model, style: style) }
        context.saveGState()
        context.setAlpha(preview != nil ? 0.22 : (style.isEnabled ? 1 : 0.5))
        drawNodes(in: context, plot: plot, model: model, style: style)
        context.restoreGState()
        if model.isDragging { drawBubble(in: context, bounds: bounds, plot: plot, model: model, style: style) }
        drawFrequencyLabels(in: context, plot: plot, model: model)
    }

    // MARK: Pieces

    private static func white(_ alpha: CGFloat) -> CGColor {
        CGColor(gray: 1, alpha: alpha)
    }

    private static func drawGrid(in context: CGContext, plot: CGRect, style: Style) {
        let labelColor = white(style.highContrast ? 0.75 : 0.42)
        for decibels in [12.0, 6, 0, -6, -12] {
            let y = plot.minY + CGFloat(EqualizerPlot.y(forDecibels: decibels, height: Double(plot.height)))
            if decibels == 0 || abs(decibels) == 6 {
                let alpha: CGFloat = decibels == 0 ? (style.highContrast ? 0.5 : 0.26) : (style.highContrast ? 0.22 : 0.07)
                context.setStrokeColor(white(alpha))
                context.setLineWidth(1)
                context.move(to: CGPoint(x: plot.minX, y: y))
                context.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.strokePath()
            }
            let text = decibels > 0 ? "+\(Int(decibels))" : (decibels < 0 ? "\u{2212}\(Int(abs(decibels)))" : "0")
            drawText(text, in: context, at: CGPoint(x: plot.minX - 6, y: y), anchor: .trailing, size: 10, weight: .regular, color: labelColor)
        }
        for frequency in [100.0, 1_000, 10_000] {
            let x = plot.minX + CGFloat(EqualizerPlot.x(forFrequency: frequency, width: Double(plot.width)))
            context.setStrokeColor(white(style.highContrast ? 0.22 : 0.07))
            context.setLineWidth(1)
            context.move(to: CGPoint(x: x, y: plot.minY))
            context.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.strokePath()
        }
    }

    private static func drawFrequencyLabels(in context: CGContext, plot: CGRect, model: EqualizerPlotModel) {
        let active = model.content.mode == .simple ? model.content.selectedIndex : -1
        for (index, centre) in GraphicSolver.centres.enumerated() {
            let isActive = index == active
            let x = plot.minX + CGFloat(EqualizerPlot.x(forFrequency: centre, width: Double(plot.width)))
            drawText(
                EqualizerCopy.shortHertz(centre),
                in: context,
                at: CGPoint(x: x, y: plot.maxY + 17),
                anchor: .center,
                size: 10.5,
                weight: isActive ? .bold : .regular,
                color: white(isActive ? 1 : 0.42)
            )
        }
    }

    private static func drawSpectrum(in context: CGContext, plot: CGRect, model: EqualizerPlotModel) {
        let points = model.spectrumPoints(in: plot)
        guard !points.isEmpty else { return }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        points.forEach { path.addLine(to: $0) }
        path.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        path.closeSubpath()
        context.saveGState()
        context.addPath(path)
        context.clip()
        let colors = [white(0.13), white(0.02)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: plot.minY), end: CGPoint(x: 0, y: plot.maxY), options: [])
        }
        context.restoreGState()
    }

    private static func drawSelectedBand(in context: CGContext, plot: CGRect, model: EqualizerPlotModel, style: Style) {
        let index = model.content.selectedIndex
        guard model.content.bands.indices.contains(index) else { return }
        let points = model.curvePoints([model.content.bands[index]], in: plot)
        let zero = plot.minY + plot.height / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: plot.minX, y: zero))
        points.forEach { path.addLine(to: $0) }
        path.addLine(to: CGPoint(x: plot.maxX, y: zero))
        path.closeSubpath()
        context.setFillColor(style.bandColors[index % style.bandColors.count].copy(alpha: 0.2) ?? white(0.2))
        context.addPath(path)
        context.fillPath()
    }

    private static func drawCurve(in context: CGContext, plot: CGRect, model: EqualizerPlotModel, style: Style, preview: [CGPoint]?) {
        let kept = model.curvePoints(style.isEnabled ? model.resolvedBands : [], in: plot)
        if let preview {
            drawReferenceCurve(kept, in: context)
            drawHeroCurve(preview, in: context, plot: plot, style: style, comparing: false)
        } else {
            drawHeroCurve(kept, in: context, plot: plot, style: style, comparing: style.isComparing && style.isEnabled)
        }
    }

    private static func drawReferenceCurve(_ points: [CGPoint], in context: CGContext) {
        let line = CGMutablePath()
        for (index, point) in points.enumerated() {
            index == 0 ? line.move(to: point) : line.addLine(to: point)
        }
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(1.6)
        context.setLineDash(phase: 0, lengths: [6, 5])
        context.setStrokeColor(white(0.42))
        context.addPath(line)
        context.strokePath()
        context.restoreGState()
    }

    private static func drawHeroCurve(_ points: [CGPoint], in context: CGContext, plot: CGRect, style: Style, comparing: Bool) {
        let zero = plot.minY + plot.height / 2

        if comparing {
            context.setStrokeColor(white(0.5))
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [5, 5])
            context.move(to: CGPoint(x: plot.minX, y: zero))
            context.addLine(to: CGPoint(x: plot.maxX, y: zero))
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [])
        }

        for (above, color) in [(true, style.accent), (false, style.cut)] {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: plot.minX, y: zero))
            for point in points {
                path.addLine(to: CGPoint(x: point.x, y: above ? min(point.y, zero) : max(point.y, zero)))
            }
            path.addLine(to: CGPoint(x: plot.maxX, y: zero))
            path.closeSubpath()
            context.setFillColor(color.copy(alpha: comparing ? 0.05 : (above ? 0.22 : 0.15)) ?? color)
            context.addPath(path)
            context.fillPath()
        }

        let line = CGMutablePath()
        for (index, point) in points.enumerated() {
            index == 0 ? line.move(to: point) : line.addLine(to: point)
        }
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setShadow(offset: .zero, blur: 12, color: style.accent.copy(alpha: comparing ? 0.1 : 0.7))
        context.setStrokeColor(style.accent.copy(alpha: comparing ? 0.2 : 0.85) ?? style.accent)
        context.setLineWidth(style.highContrast ? 5 : 4)
        context.addPath(line)
        context.strokePath()
        context.restoreGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(white(comparing ? 0.35 : 1))
        context.setLineWidth(style.highContrast ? 3.2 : 2.4)
        context.addPath(line)
        context.strokePath()
    }

    private static func drawActiveColumn(in context: CGContext, plot: CGRect, model: EqualizerPlotModel, style: Style) {
        let index = model.content.selectedIndex
        guard index < GraphicSolver.centres.count else { return }
        let x = plot.minX + CGFloat(EqualizerPlot.x(forFrequency: GraphicSolver.centres[index], width: Double(plot.width)))
        let width = plot.width * 0.1
        let rect = CGRect(x: x - width / 2, y: plot.minY, width: width, height: plot.height)
        let colors = [
            style.accent.copy(alpha: 0) ?? style.accent,
            style.accent.copy(alpha: model.isDragging ? 0.2 : 0.11) ?? style.accent,
            style.accent.copy(alpha: 0) ?? style.accent,
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) else { return }
        context.saveGState()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
        context.clip()
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
        context.restoreGState()
    }

    private static func drawNodes(in context: CGContext, plot: CGRect, model: EqualizerPlotModel, style: Style) {
        for index in 0..<model.nodeCount {
            let isSelected = index == model.content.selectedIndex
            let center = model.nodePosition(index, in: plot)
            switch model.content.mode {
            case .simple:
                let radius: CGFloat = isSelected ? 11 : 5.5
                if isSelected {
                    context.setFillColor(style.accent.copy(alpha: 0.34) ?? style.accent)
                    context.fillEllipse(in: CGRect(x: center.x - radius - 6, y: center.y - radius - 6, width: (radius + 6) * 2, height: (radius + 6) * 2))
                    context.setShadow(offset: .zero, blur: 14, color: style.accent.copy(alpha: 0.9))
                }
                context.setFillColor(white(1))
                context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                context.setShadow(offset: .zero, blur: 0, color: nil)
            case .advanced:
                let color = style.bandColors[index % style.bandColors.count]
                let radius: CGFloat = isSelected ? 12 : 8
                if isSelected {
                    context.setStrokeColor(white(0.9))
                    context.setLineWidth(3)
                    context.strokeEllipse(in: CGRect(x: center.x - radius - 1.5, y: center.y - radius - 1.5, width: (radius + 1.5) * 2, height: (radius + 1.5) * 2))
                    context.setShadow(offset: .zero, blur: 12, color: color.copy(alpha: 0.9))
                }
                context.setFillColor(color)
                context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                context.setShadow(offset: .zero, blur: 0, color: nil)
                if isSelected {
                    drawText("\(index + 1)", in: context, at: center, anchor: .center, size: 11, weight: .heavy, color: CGColor(red: 0.1, green: 0.07, blue: 0.15, alpha: 1))
                }
            }
        }
    }

    private static func drawBubble(in context: CGContext, bounds: CGRect, plot: CGRect, model: EqualizerPlotModel, style: Style) {
        let index = model.content.selectedIndex
        guard style.isEnabled, (0..<model.nodeCount).contains(index) else { return }
        let text: String
        switch model.content.mode {
        case .simple:
            text = "\(EqualizerCopy.decibels(model.displayTargets[index])) dB"
        case .advanced:
            let band = model.content.bands[index]
            text = band.type.hasGain
                ? "\(EqualizerCopy.hertz(band.frequency))  \(EqualizerCopy.decibels(band.gain)) dB"
                : EqualizerCopy.hertz(band.frequency)
        }
        let width = textWidth(text, size: 13, weight: .bold) + 22
        let center = model.nodePosition(index, in: plot)
        let x = min(max(center.x - width / 2, bounds.minX + 4), bounds.maxX - width - 4)
        let aboveY = center.y - 48
        let y = aboveY < plot.minY - 6 ? center.y + 24 : aboveY
        let rect = CGRect(x: x, y: y, width: width, height: 28)
        context.setFillColor(CGColor(gray: 0.16, alpha: 0.92))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 14, cornerHeight: 14, transform: nil))
        context.fillPath()
        context.setStrokeColor(white(0.18))
        context.setLineWidth(1)
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 14, cornerHeight: 14, transform: nil))
        context.strokePath()
        drawText(text, in: context, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center, size: 13, weight: .bold, color: white(1))
    }

    // MARK: Text

    enum Anchor {
        case leading
        case center
        case trailing
    }

    private static func font(size: CGFloat, weight: CTFontWeight) -> CTFont {
        let weightValue: CGFloat
        switch weight {
        case .bold: weightValue = 0.4
        case .heavy: weightValue = 0.56
        default: weightValue = 0
        }
        let traits: [CFString: Any] = [kCTFontWeightTrait: weightValue]
        let features: [[CFString: Any]] = [[kCTFontFeatureTypeIdentifierKey: kNumberSpacingType, kCTFontFeatureSelectorIdentifierKey: kMonospacedNumbersSelector]]
        let attributes: [CFString: Any] = [kCTFontTraitsAttribute: traits, kCTFontFeatureSettingsAttribute: features]
        let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let descriptor = CTFontCopyFontDescriptor(base)
        let adjusted = CTFontDescriptorCreateCopyWithAttributes(descriptor, attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(adjusted, size, nil)
    }

    enum CTFontWeight {
        case regular
        case bold
        case heavy
    }

    private static func line(_ text: String, size: CGFloat, weight: CTFontWeight, color: CGColor) -> CTLine {
        let attributes: [CFString: Any] = [kCTFontAttributeName: font(size: size, weight: weight), kCTForegroundColorAttributeName: color]
        let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
        return CTLineCreateWithAttributedString(string)
    }

    static func textWidth(_ text: String, size: CGFloat, weight: CTFontWeight) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(text, size: size, weight: weight, color: CGColor(gray: 1, alpha: 1)), nil, nil, nil))
    }

    static func drawText(_ text: String, in context: CGContext, at point: CGPoint, anchor: Anchor, size: CGFloat, weight: CTFontWeight, color: CGColor) {
        let ctLine = line(text, size: size, weight: weight, color: color)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil))
        let x: CGFloat
        switch anchor {
        case .leading: x = point.x
        case .center: x = point.x - width / 2
        case .trailing: x = point.x - width
        }
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: x, y: point.y + (ascent - descent) / 2)
        CTLineDraw(ctLine, context)
        context.restoreGState()
    }
}
