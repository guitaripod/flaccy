import CoreGraphics
import FlaccyCore
import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

#if canImport(UIKit)
typealias LyricWipeFont = UIFont
typealias LyricWipeColor = UIColor
#else
typealias LyricWipeFont = NSFont
typealias LyricWipeColor = NSColor
#endif

/// How far the fill has got through a laid-out lyric line.
enum LyricWipeEdge: Equatable {
    case nothing
    case everything
    case at(row: Int, x: CGFloat)
}

/// One wrapped row of a line as it is painted: before the fill edge, after it,
/// or split by it.
enum LyricWipeFill: Equatable {
    case unsung
    case sung
    case edge(CGFloat)
}

/// A lyric line laid out by TextKit, so the fill edge sits where the glyphs
/// really are, with the means to paint it in two colours. Mirrors the
/// Linux client's `LyricLine` widget: the same glyphs are drawn twice through
/// clips, sung in one colour and unsung in the other, with a short soft edge
/// where they meet. Rows before the edge are sung, rows after it are not.
final class LyricWipeLayout {

    /// The width of the soft edge between the sung and unsung parts.
    static let edgeSoftness: CGFloat = 10
    /// The edge snaps to half a point, so a fill that moved less than that is not
    /// repainted.
    private static let edgeResolution: CGFloat = 2
    /// How many steps the soft edge is drawn in.
    private static let edgeSlices = 4

    let width: CGFloat
    let isRightToLeft: Bool
    private(set) var rows: [CGRect] = []
    private let wordRanges: [NSRange]
    private let bright: Stack
    private let dim: Stack

    private final class Stack {
        let storage: NSTextStorage
        let manager = NSLayoutManager()
        let container: NSTextContainer

        init(text: NSAttributedString, width: CGFloat) {
            storage = NSTextStorage(attributedString: text)
            container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
        }

        var glyphRange: NSRange {
            manager.glyphRange(for: container)
        }
    }

    init(
        text: String, words: [LyricsWord], font: LyricWipeFont,
        paragraph: NSParagraphStyle? = nil, width: CGFloat,
        bright: LyricWipeColor, dim: LyricWipeColor
    ) {
        self.width = width
        isRightToLeft = Self.startsRightToLeft(text)
        var offset = 0
        wordRanges = words.map { word in
            let length = (word.text as NSString).length
            defer { offset += length }
            return NSRange(location: offset, length: length)
        }
        func attributed(_ color: LyricWipeColor) -> NSAttributedString {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if let paragraph { attributes[.paragraphStyle] = paragraph }
            return NSAttributedString(string: text, attributes: attributes)
        }
        self.bright = Stack(text: attributed(bright), width: width)
        self.dim = Stack(text: attributed(dim), width: width)
        var collected: [CGRect] = []
        let glyphs = self.bright.glyphRange
        if glyphs.length > 0 {
            self.bright.manager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                collected.append(rect)
            }
        }
        rows = collected
    }

    /// The height the whole line needs at this width.
    var height: CGFloat {
        ceil(bright.manager.usedRect(for: bright.container).height)
    }

    /// Where the edge sits for a clock position inside the line.
    func edge(for progress: LyricsLineProgress) -> LyricWipeEdge {
        switch progress {
        case .notStarted:
            return .nothing
        case .done:
            return .everything
        case .singing(let word, let fraction):
            guard wordRanges.indices.contains(word), !rows.isEmpty else { return .everything }
            let range = wordRanges[word]
            let glyphs = bright.manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var first: CGRect?
            bright.manager.enumerateEnclosingRects(
                forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: bright.container
            ) { rect, stop in
                first = rect
                stop.pointee = true
            }
            guard let first else { return .everything }
            let row = rows.firstIndex { first.midY >= $0.minY && first.midY < $0.maxY } ?? 0
            let progress = min(max(fraction, 0), 1)
            let exact = isRightToLeft
                ? first.maxX - first.width * progress
                : first.minX + first.width * progress
            return .at(row: row, x: (exact * Self.edgeResolution).rounded() / Self.edgeResolution)
        }
    }

    /// How each wrapped row is painted for an edge.
    func fills(for edge: LyricWipeEdge) -> [LyricWipeFill] {
        rows.indices.map { index in
            switch edge {
            case .nothing: return .unsung
            case .everything: return .sung
            case .at(let row, let x):
                if index == row { return .edge(x) }
                return index < row ? .sung : .unsung
            }
        }
    }

    /// Paints the line into the current graphics context, whose origin is the
    /// line's top-left corner with y growing downward.
    func draw(edge: LyricWipeEdge, in context: CGContext) {
        let fills = fills(for: edge)
        for (row, fill) in zip(rows, fills) {
            switch fill {
            case .sung:
                paint(bright, clip: CGRect(x: 0, y: row.minY, width: width, height: row.height), in: context)
            case .unsung:
                paint(dim, clip: CGRect(x: 0, y: row.minY, width: width, height: row.height), in: context)
            case .edge(let x):
                paintEdge(row: row, at: x, in: context)
            }
        }
    }

    private func paintEdge(row: CGRect, at x: CGFloat, in context: CGContext) {
        let half = Self.edgeSoftness / 2
        let low = min(max(x - half, 0), width)
        let high = min(max(x + half, 0), width)
        let lit = isRightToLeft
            ? CGRect(x: high, y: row.minY, width: width - high, height: row.height)
            : CGRect(x: 0, y: row.minY, width: low, height: row.height)
        let rest = isRightToLeft
            ? CGRect(x: 0, y: row.minY, width: high, height: row.height)
            : CGRect(x: low, y: row.minY, width: width - low, height: row.height)
        paint(dim, clip: rest, in: context)
        paint(bright, clip: lit, in: context)
        let slice = (high - low) / CGFloat(Self.edgeSlices)
        guard slice > 0 else { return }
        for index in 0..<Self.edgeSlices {
            let share = (CGFloat(index) + 0.5) / CGFloat(Self.edgeSlices)
            let alpha = isRightToLeft ? share : 1 - share
            let band = CGRect(x: low + slice * CGFloat(index), y: row.minY, width: slice, height: row.height)
            paint(bright, clip: band, alpha: alpha, in: context)
        }
    }

    private func paint(_ stack: Stack, clip: CGRect, alpha: CGFloat = 1, in context: CGContext) {
        guard clip.width > 0, clip.height > 0 else { return }
        context.saveGState()
        context.clip(to: clip)
        context.setAlpha(alpha)
        stack.manager.drawGlyphs(forGlyphRange: stack.glyphRange, at: .zero)
        context.restoreGState()
    }

    /// Whether the line's first letter belongs to a right-to-left script.
    static func startsRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF:
                return true
            default:
                return false
            }
        }
        return false
    }
}
