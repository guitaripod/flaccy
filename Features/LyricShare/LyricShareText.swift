import CoreGraphics
import CoreText
import FlaccyCore
import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The weights a clip sets text in.
nonisolated enum LyricShareWeight {
    case lyric
    case title
    case artist
    case mark
}

/// The fonts a clip's typeface stands for on Apple platforms, built as Core
/// Text fonts so drawing works off the main thread.
nonisolated enum LyricShareFonts {

    static func font(_ typeface: LyricShareTypeface, weight: LyricShareWeight, size: CGFloat) -> CTFont {
        #if canImport(UIKit)
        let systemWeight: UIFont.Weight
        #else
        let systemWeight: NSFont.Weight
        #endif
        switch weight {
        case .lyric: systemWeight = typeface == .mono ? .bold : .heavy
        case .title: systemWeight = .bold
        case .artist: systemWeight = .medium
        case .mark: systemWeight = .heavy
        }
        let face: LyricShareTypeface = weight == .mark ? .modern : typeface
        #if canImport(UIKit)
        let base = UIFont.systemFont(ofSize: size, weight: systemWeight)
        let design: UIFontDescriptor.SystemDesign
        switch face {
        case .modern: design = .default
        case .serif: design = .serif
        case .rounded: design = .rounded
        case .mono: design = .monospaced
        }
        let descriptor = base.fontDescriptor.withDesign(design) ?? base.fontDescriptor
        return UIFont(descriptor: descriptor, size: size) as CTFont
        #else
        let base = NSFont.systemFont(ofSize: size, weight: systemWeight)
        let design: NSFontDescriptor.SystemDesign
        switch face {
        case .modern: design = .default
        case .serif: design = .serif
        case .rounded: design = .rounded
        case .mono: design = .monospaced
        }
        let descriptor = base.fontDescriptor.withDesign(design) ?? base.fontDescriptor
        return (NSFont(descriptor: descriptor, size: size) ?? base) as CTFont
        #endif
    }
}

/// A run of text broken into rows that fit a width, with each row placed for
/// its alignment. Coordinates are y-down from the block's top left; `rows`
/// carry the baseline of each row.
nonisolated final class LyricShareTextBlock {

    struct Row {
        let line: CTLine
        let range: CFRange
        let x: CGFloat
        let baseline: CGFloat
        let width: CGFloat
    }

    static let lineSpacing: CGFloat = 1.14

    let rows: [Row]
    let size: CGSize
    let fontSize: CGFloat
    let isRightToLeft: Bool
    let length: Int

    init(text: String, font: CTFont, width: CGFloat, alignment: LyricShareAlignment) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        let length = string.length
        let fontSize = CTFontGetSize(font)
        let ascent = CTFontGetAscent(font)
        let height = fontSize * Self.lineSpacing
        var rows: [Row] = []
        var start = 0
        var rightToLeft = false
        while start < length {
            let count = max(CTTypesetterSuggestLineBreak(typesetter, start, Double(width)), 1)
            let range = CFRange(location: start, length: count)
            let line = CTTypesetterCreateLine(typesetter, range)
            let rowWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
            if rows.isEmpty {
                rightToLeft = Self.startsRightToLeft(line)
            }
            let x: CGFloat
            switch alignment {
            case .center: x = (width - rowWidth) / 2
            case .leading: x = rightToLeft ? width - rowWidth : 0
            }
            rows.append(Row(line: line, range: range, x: x, baseline: CGFloat(rows.count) * height + ascent, width: rowWidth))
            start += count
        }
        self.rows = rows
        self.fontSize = fontSize
        self.isRightToLeft = rightToLeft
        self.length = length
        let descent = CTFontGetDescent(font)
        let total = rows.isEmpty ? 0 : CGFloat(rows.count - 1) * height + ascent + descent
        self.size = CGSize(width: width, height: total)
    }

    private static func startsRightToLeft(_ line: CTLine) -> Bool {
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], let first = runs.first else { return false }
        return CTRunGetStatus(first).contains(.rightToLeft)
    }

    /// Lays `text` out at `size`, shrinking it until it fits `bounds` or
    /// reaches the smallest size a template allows.
    static func fitting(
        _ text: String, typeface: LyricShareTypeface, size: CGFloat, bounds: CGSize, alignment: LyricShareAlignment
    ) -> LyricShareTextBlock {
        var current = size
        let smallest = size * CGFloat(LyricShareLayout.minimumLyricScale)
        while true {
            let font = LyricShareFonts.font(typeface, weight: .lyric, size: current)
            let block = LyricShareTextBlock(text: text, font: font, width: bounds.width, alignment: alignment)
            if block.size.height <= bounds.height || current <= smallest {
                return block
            }
            current = max(current * 0.92, smallest)
        }
    }

    func draw(in context: CGContext, at origin: CGPoint) {
        for row in rows {
            context.textPosition = CGPoint(x: origin.x + row.x, y: origin.y + row.baseline)
            CTLineDraw(row.line, context)
        }
    }

    /// The row holding a UTF-16 offset into the text and the x of that offset
    /// within the block.
    func position(ofOffset offset: Int) -> (row: Int, x: CGFloat) {
        let clamped = min(max(offset, 0), length)
        var index = rows.count - 1
        for (position, row) in rows.enumerated() where clamped < row.range.location + row.range.length {
            index = position
            break
        }
        guard index >= 0 else { return (0, 0) }
        let row = rows[index]
        let x = CTLineGetOffsetForStringIndex(row.line, clamped, nil)
        return (index, row.x + x)
    }

    func rowRect(_ index: Int, at origin: CGPoint) -> CGRect {
        let row = rows[index]
        let height = fontSize * Self.lineSpacing
        let top = origin.y + row.baseline - fontSize * 0.98
        return CGRect(x: origin.x + row.x - 4, y: top, width: row.width + 8, height: height + fontSize * 0.1)
    }
}
