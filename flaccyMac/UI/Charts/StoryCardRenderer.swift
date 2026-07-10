import AppKit

/// Pure CoreGraphics re-implementation of the iOS YearInMusicStoryView: the
/// five editorial slides drawn straight into a bitmap context (no detached
/// view hierarchy, so exports can never come out blank). Layout constants
/// mirror the iOS renderer: 360-wide canvas, 30pt margins, hairline rules,
/// rotated year watermark, monogram tiles for missing art.
enum StoryCardRenderer {

    private static let margin: CGFloat = 30

    static func makeImage(
        slide: StorySlide, data: YearInMusicData, artwork: StoryArtwork,
        theme: StoryTheme, format: StoryFormat = .story, scale: CGFloat = 3
    ) -> NSImage? {
        let size = format.canvasSize
        guard let context = CGContext(
            data: nil,
            width: Int(size.width * scale), height: Int(size.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)

        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics

        let canvas = Canvas(context: context, size: size, theme: theme)
        canvas.drawBackground()
        canvas.drawWatermark(year: data.year, fontSize: format == .post ? 104 : 150)
        canvas.drawChrome(year: data.year)

        var cursor: CGFloat = format == .post ? 62 : 74
        switch slide {
        case .overview:
            drawOverview(canvas, data: data, artwork: artwork, cursor: &cursor)
        case .artists:
            drawRanked(
                canvas, caption: "MY TOP ARTISTS",
                entries: data.topArtists.map { ($0.name, nil, $0.playCount) },
                rowArt: artwork.artistRows,
                footnote: "\(RecapFormat.count(data.distinctArtists)) artists this year",
                cursor: &cursor
            )
        case .tracks:
            drawRanked(
                canvas, caption: "MY TOP TRACKS",
                entries: data.topTracks.map { ($0.name, $0.artistName, $0.playCount) },
                rowArt: artwork.trackRows,
                footnote: "\(RecapFormat.count(data.distinctTracks)) tracks this year",
                cursor: &cursor
            )
        case .numbers:
            drawNumbers(canvas, data: data, cursor: &cursor)
        case .poster:
            drawPoster(canvas, data: data, artwork: artwork, compact: format == .post, cursor: &cursor)
        }

        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: size)
    }

    private static func drawOverview(_ canvas: Canvas, data: YearInMusicData, artwork: StoryArtwork, cursor: inout CGFloat) {
        cursor = canvas.text("MY YEAR IN MUSIC", style: .caption, at: cursor) + 4
        cursor = canvas.text(String(data.year), font: .systemFont(ofSize: 84, weight: .heavy), color: .white, at: cursor) + 18

        let collageSide: CGFloat = 148
        canvas.drawCollage(artwork: artwork, albums: data.topAlbums, side: collageSide, x: margin, y: cursor)
        var highlightY = cursor + 10
        let highlightX = margin + collageSide + 18
        if let topArtist = data.topArtists.first {
            highlightY = canvas.text("TOP ARTIST", style: .caption, at: highlightY, x: highlightX) + 3
            highlightY = canvas.text(
                topArtist.name, font: .systemFont(ofSize: 21, weight: .heavy), color: .white,
                at: highlightY, x: highlightX, maxWidth: canvas.size.width - highlightX - margin
            ) + 14
        }
        if let topTrack = data.topTracks.first {
            highlightY = canvas.text("TOP TRACK", style: .caption, at: highlightY, x: highlightX) + 3
            highlightY = canvas.text(
                topTrack.name, font: .systemFont(ofSize: 16, weight: .heavy), color: .white,
                at: highlightY, x: highlightX, maxWidth: canvas.size.width - highlightX - margin
            ) + 2
            highlightY = canvas.text(topTrack.artistName, style: .subtitle(12), at: highlightY, x: highlightX)
        }
        cursor += collageSide + 22

        cursor = canvas.statTable([
            ("MINUTES LISTENED", RecapFormat.count(data.totalMinutes)),
            ("TRACKS PLAYED", RecapFormat.count(data.totalPlays)),
            ("ARTISTS", RecapFormat.count(data.distinctArtists)),
        ], at: cursor) + 20
        canvas.drawPersonaPill(data.persona, x: margin, topY: cursor)
    }

    private static func drawRanked(
        _ canvas: Canvas, caption: String,
        entries: [(title: String, subtitle: String?, plays: Int)],
        rowArt: [NSImage?], footnote: String, cursor: inout CGFloat
    ) {
        cursor = canvas.text(caption, style: .caption, at: cursor) + 18
        guard let first = entries.first else { return }

        let heroSide: CGFloat = 128
        canvas.drawTile(
            image: rowArt.first ?? nil, name: first.title, rect:
                CGRect(x: margin, y: cursor, width: heroSide, height: heroSide),
            cornerRadius: 20, monogramFontSize: heroSide * 0.42
        )
        var blockY = cursor + 8
        let blockX = margin + heroSide + 18
        let blockWidth = canvas.size.width - blockX - margin
        blockY = canvas.text("#1", font: .systemFont(ofSize: 20, weight: .heavy), color: canvas.theme.accent, at: blockY, x: blockX) + 4
        blockY = canvas.text(
            first.title, font: .systemFont(ofSize: 25, weight: .heavy), color: .white,
            at: blockY, x: blockX, maxWidth: blockWidth, lines: 3
        ) + 4
        if let subtitle = first.subtitle {
            blockY = canvas.text(subtitle, style: .subtitle(14), at: blockY, x: blockX, maxWidth: blockWidth) + 2
        }
        blockY = canvas.text(
            "\(RecapFormat.count(first.plays)) plays", font: .systemFont(ofSize: 13, weight: .semibold),
            color: canvas.theme.accent, at: blockY + 2, x: blockX
        )
        cursor += heroSide + 24

        for (index, entry) in entries.dropFirst().prefix(4).enumerated() {
            canvas.hairline(at: cursor)
            cursor += 9
            let art = rowArt.indices.contains(index + 1) ? rowArt[index + 1] : nil
            cursor = canvas.rankedRow(rank: index + 2, entry: entry, art: art, topY: cursor) + 9
        }
        canvas.hairline(at: cursor)
        cursor += 20
        canvas.text(footnote, style: .subtitle(13), at: cursor)
    }

    private static func drawNumbers(_ canvas: Canvas, data: YearInMusicData, cursor: inout CGFloat) {
        cursor = canvas.text("THE NUMBERS", style: .caption, at: cursor) + 14
        cursor = canvas.text(
            RecapFormat.count(data.totalMinutes), font: .systemFont(ofSize: 62, weight: .heavy),
            color: canvas.theme.accent, at: cursor
        ) + 2
        cursor = canvas.text("MINUTES LISTENED", style: .caption, at: cursor) + 22

        cursor = canvas.statTable([
            ("TRACKS PLAYED", RecapFormat.count(data.totalPlays)),
            ("ARTISTS", RecapFormat.count(data.distinctArtists)),
            ("ALBUMS", RecapFormat.count(data.distinctAlbums)),
            ("DIFFERENT TRACKS", RecapFormat.count(data.distinctTracks)),
        ], at: cursor) + 22

        if let peakDay = data.peakDay {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMMM d"
            cursor = canvas.factRow(
                symbol: "calendar",
                text: "Biggest day: \(formatter.string(from: peakDay)) — \(RecapFormat.count(data.peakDayPlays)) plays",
                topY: cursor
            ) + 10
        }
        if let peakHour = data.peakHour {
            cursor = canvas.factRow(symbol: "clock.fill", text: "Power hour: \(hourLabel(peakHour))", topY: cursor) + 10
        }
        if data.longestStreak > 1 {
            cursor = canvas.factRow(symbol: "flame.fill", text: "Longest streak: \(data.longestStreak) days", topY: cursor) + 10
        }
        cursor += 10
        canvas.drawPersonaPill(data.persona, x: margin, topY: cursor)
    }

    private static func drawPoster(
        _ canvas: Canvas, data: YearInMusicData, artwork: StoryArtwork, compact: Bool, cursor: inout CGFloat
    ) {
        if !compact {
            cursor = canvas.text("MY YEAR IN MUSIC", style: .caption, at: cursor) + 2
        }
        cursor = canvas.text(
            String(data.year), font: .systemFont(ofSize: compact ? 38 : 46, weight: .heavy),
            color: .white, at: cursor
        ) + (compact ? 10 : 14)

        let side: CGFloat = compact ? 86 : 104
        canvas.drawCollage(artwork: artwork, albums: data.topAlbums, side: side, x: margin, y: cursor)
        var statY = cursor + 2
        let statX = margin + side + 16
        statY = canvas.text(
            RecapFormat.count(data.totalMinutes), font: .systemFont(ofSize: 30, weight: .heavy),
            color: canvas.theme.accent, at: statY, x: statX
        ) + 2
        statY = canvas.text("MINUTES LISTENED", style: .caption, at: statY, x: statX) + 8
        canvas.text(
            "\(RecapFormat.count(data.totalPlays)) plays · \(RecapFormat.count(data.distinctArtists)) artists",
            style: .subtitle(13), at: statY, x: statX
        )
        cursor += side + (compact ? 12 : 16)

        canvas.hairline(at: cursor)
        cursor += compact ? 10 : 14

        let columnWidth = (canvas.size.width - margin * 2 - 18) / 2
        let listTop = cursor
        let leftBottom = canvas.miniList(
            caption: "TOP ARTISTS", entries: data.topArtists.map { ($0.name, $0.playCount) },
            x: margin, topY: listTop, width: columnWidth, compact: compact
        )
        let rightBottom = canvas.miniList(
            caption: "TOP TRACKS", entries: data.topTracks.map { ($0.name, $0.playCount) },
            x: margin + columnWidth + 18, topY: listTop, width: columnWidth, compact: compact
        )
        cursor = max(leftBottom, rightBottom) + (compact ? 10 : 14)

        canvas.hairline(at: cursor)
        cursor += compact ? 10 : 14

        if !compact {
            if let peakDay = data.peakDay {
                let formatter = DateFormatter()
                formatter.dateFormat = "MMMM d"
                cursor = canvas.factRow(
                    symbol: "calendar",
                    text: "Biggest day: \(formatter.string(from: peakDay)) — \(RecapFormat.count(data.peakDayPlays)) plays",
                    topY: cursor
                ) + 7
            }
            if data.longestStreak > 1 {
                cursor = canvas.factRow(symbol: "flame.fill", text: "Longest streak: \(data.longestStreak) days", topY: cursor) + 7
            }
            cursor += 7
        }
        canvas.drawPersonaPill(data.persona, x: margin, topY: cursor)
    }

    private static func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? Date(timeIntervalSince1970: 0)
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Drawing helper bound to one flipped bitmap context: y grows downward
    /// and every `text` call returns the next cursor position.
    private final class Canvas {

        enum Style {
            case caption
            case subtitle(CGFloat)
        }

        let context: CGContext
        let size: CGSize
        let theme: StoryTheme

        init(context: CGContext, size: CGSize, theme: StoryTheme) {
            self.context = context
            self.size = size
            self.theme = theme
        }

        func drawBackground() {
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(origin: .zero, size: size))

            let colors = theme.gradientColors.map { ($0.usingColorSpace(.deviceRGB) ?? $0).cgColor } as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1]
            ) {
                context.drawLinearGradient(
                    gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: []
                )
            }

            let glowCenter = CGPoint(x: size.width * 0.82, y: size.height * 0.06)
            let glowColors = [
                theme.accent.withAlphaComponent(0.28).cgColor, NSColor.clear.cgColor,
            ] as CFArray
            if let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glowColors, locations: [0, 1]) {
                context.drawRadialGradient(
                    glow, startCenter: glowCenter, startRadius: 0,
                    endCenter: glowCenter, endRadius: size.width * 0.5, options: []
                )
            }
        }

        func drawWatermark(year: Int, fontSize: CGFloat) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
                .foregroundColor: NSColor.white.withAlphaComponent(0.05),
            ]
            let text = String(year) as NSString
            let textSize = text.size(withAttributes: attributes)
            context.saveGState()
            context.translateBy(x: size.width - 28, y: size.height / 2 + 40)
            context.rotate(by: .pi / 2)
            text.draw(
                at: CGPoint(x: -textSize.width / 2, y: -textSize.height / 2),
                withAttributes: attributes
            )
            context.restoreGState()
        }

        func drawChrome(year: Int) {
            chromeText("FLACCY", x: StoryCardRenderer.margin, topY: 26)
            let yearText = String(year)
            let width = chromeWidth(yearText)
            chromeText(yearText, x: size.width - StoryCardRenderer.margin - width, topY: 26)

            let footerRuleY = size.height - 24 - 16 - 12
            hairline(at: footerRuleY)
            chromeText("YEAR IN MUSIC", x: StoryCardRenderer.margin, topY: footerRuleY + 12)
            drawSymbol(
                "sparkles", pointSize: 10, weight: .bold, tint: theme.accent,
                rect: CGRect(x: size.width - StoryCardRenderer.margin - 12, y: footerRuleY + 12, width: 12, height: 12)
            )
        }

        @discardableResult
        func text(
            _ string: String, font: NSFont, color: NSColor, at topY: CGFloat,
            x: CGFloat = StoryCardRenderer.margin, maxWidth: CGFloat? = nil,
            lines: Int = 1, kern: CGFloat = 0
        ) -> CGFloat {
            let width = maxWidth ?? (size.width - x - StoryCardRenderer.margin)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .kern: kern, .paragraphStyle: paragraph,
            ]
            let attributed = NSAttributedString(string: string, attributes: attributes)
            let bounding = attributed.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin]
            )
            let lineHeight = font.ascender - font.descender + font.leading
            let height = min(bounding.height, lineHeight * CGFloat(lines) + 2)
            attributed.draw(with: CGRect(x: x, y: topY, width: width, height: height), options: [.usesLineFragmentOrigin])
            return topY + height
        }

        @discardableResult
        func text(_ string: String, style: Style, at topY: CGFloat, x: CGFloat = StoryCardRenderer.margin, maxWidth: CGFloat? = nil) -> CGFloat {
            switch style {
            case .caption:
                return text(
                    string, font: .systemFont(ofSize: 12, weight: .bold),
                    color: NSColor.white.withAlphaComponent(0.65), at: topY, x: x, maxWidth: maxWidth, kern: 2.2
                )
            case .subtitle(let fontSize):
                return text(
                    string, font: .systemFont(ofSize: fontSize, weight: .semibold),
                    color: NSColor.white.withAlphaComponent(0.6), at: topY, x: x, maxWidth: maxWidth
                )
            }
        }

        private func chromeText(_ string: String, x: CGFloat, topY: CGFloat) {
            text(
                string, font: .systemFont(ofSize: 11, weight: .heavy),
                color: NSColor.white.withAlphaComponent(0.8), at: topY, x: x, kern: 3
            )
        }

        private func chromeWidth(_ string: String) -> CGFloat {
            (string as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .heavy), .kern: 3,
            ]).width
        }

        func hairline(at y: CGFloat, x: CGFloat = StoryCardRenderer.margin, width: CGFloat? = nil) {
            context.setFillColor(NSColor.white.withAlphaComponent(0.16).cgColor)
            context.fill(CGRect(x: x, y: y, width: width ?? (size.width - x - StoryCardRenderer.margin), height: 0.5))
        }

        func statTable(_ rows: [(caption: String, value: String)], at topY: CGFloat) -> CGFloat {
            var y = topY
            for row in rows {
                hairline(at: y)
                y += 9
                let captionFont = NSFont.systemFont(ofSize: 11, weight: .bold)
                let valueFont = NSFont.systemFont(ofSize: 21, weight: .heavy)
                let valueWidth = (row.value as NSString).size(withAttributes: [.font: valueFont]).width
                let rowHeight = valueFont.ascender - valueFont.descender
                text(
                    row.caption, font: captionFont, color: NSColor.white.withAlphaComponent(0.55),
                    at: y + (rowHeight - captionFont.ascender + captionFont.descender) / 2, kern: 1.5
                )
                text(
                    row.value, font: valueFont, color: theme.accent,
                    at: y, x: size.width - StoryCardRenderer.margin - valueWidth - 2
                )
                y += rowHeight + 9
            }
            hairline(at: y)
            return y + 1
        }

        func factRow(symbol: String, text string: String, topY: CGFloat) -> CGFloat {
            drawSymbol(
                symbol, pointSize: 12, weight: .semibold, tint: theme.accent,
                rect: CGRect(x: StoryCardRenderer.margin, y: topY + 1, width: 14, height: 14)
            )
            return text(
                string, font: .systemFont(ofSize: 14, weight: .semibold),
                color: NSColor.white.withAlphaComponent(0.85),
                at: topY, x: StoryCardRenderer.margin + 22
            )
        }

        func rankedRow(rank: Int, entry: (title: String, subtitle: String?, plays: Int), art: NSImage?, topY: CGFloat) -> CGFloat {
            let rowHeight: CGFloat = 34
            text(
                "\(rank)", font: .systemFont(ofSize: 15, weight: .heavy), color: theme.accent,
                at: topY + 8, x: StoryCardRenderer.margin
            )
            drawTile(
                image: art, name: entry.title,
                rect: CGRect(x: StoryCardRenderer.margin + 30, y: topY, width: rowHeight, height: rowHeight),
                cornerRadius: 8, monogramFontSize: 15
            )
            let playsText = RecapFormat.compact(entry.plays)
            let playsFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
            let playsWidth = (playsText as NSString).size(withAttributes: [.font: playsFont]).width
            let textX = StoryCardRenderer.margin + 30 + rowHeight + 10
            let textWidth = size.width - textX - StoryCardRenderer.margin - playsWidth - 10
            var textY = topY + (entry.subtitle == nil ? 8 : 2)
            textY = text(
                entry.title, font: .systemFont(ofSize: 16, weight: .bold), color: .white,
                at: textY, x: textX, maxWidth: textWidth
            ) + 1
            if let subtitle = entry.subtitle {
                text(subtitle, style: .subtitle(12), at: textY, x: textX, maxWidth: textWidth)
            }
            text(
                playsText, font: playsFont, color: NSColor.white.withAlphaComponent(0.55),
                at: topY + 9, x: size.width - StoryCardRenderer.margin - playsWidth
            )
            return topY + rowHeight
        }

        func miniList(caption: String, entries: [(name: String, plays: Int)], x: CGFloat, topY: CGFloat, width: CGFloat, compact: Bool) -> CGFloat {
            var y = text(caption, style: .caption, at: topY, x: x, maxWidth: width) + (compact ? 7 : 9)
            for (index, entry) in entries.prefix(5).enumerated() {
                let playsText = RecapFormat.compact(entry.plays)
                let playsFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
                let playsWidth = (playsText as NSString).size(withAttributes: [.font: playsFont]).width
                text("\(index + 1)", font: .systemFont(ofSize: 12, weight: .heavy), color: theme.accent, at: y, x: x)
                let nameBottom = text(
                    entry.name, font: .systemFont(ofSize: 13, weight: .bold), color: .white,
                    at: y, x: x + 18, maxWidth: width - 18 - playsWidth - 6
                )
                text(
                    playsText, font: playsFont, color: NSColor.white.withAlphaComponent(0.5),
                    at: y + 1.5, x: x + width - playsWidth
                )
                y = nameBottom + (compact ? 5 : 7)
            }
            return y
        }

        func drawPersonaPill(_ persona: String, x: CGFloat, topY: CGFloat) {
            let font = NSFont.systemFont(ofSize: 14, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let text = persona as NSString
            let textSize = text.size(withAttributes: attributes)
            let pillRect = CGRect(x: x, y: topY, width: 16 + 15 + 6 + textSize.width + 16, height: 34)
            let path = CGPath(roundedRect: pillRect, cornerWidth: 17, cornerHeight: 17, transform: nil)
            context.addPath(path)
            context.setFillColor(NSColor.white.withAlphaComponent(0.12).cgColor)
            context.fillPath()
            context.addPath(path)
            context.setStrokeColor(theme.accent.withAlphaComponent(0.5).cgColor)
            context.setLineWidth(0.5)
            context.strokePath()
            drawSymbol(
                RecapPersona.symbol(for: persona), pointSize: 13, weight: .semibold, tint: theme.accent,
                rect: CGRect(x: pillRect.minX + 16, y: pillRect.midY - 7.5, width: 15, height: 15)
            )
            text.draw(
                at: CGPoint(x: pillRect.minX + 16 + 15 + 6, y: pillRect.midY - textSize.height / 2),
                withAttributes: attributes
            )
        }

        func drawCollage(artwork: StoryArtwork, albums: [ChartAlbum], side: CGFloat, x: CGFloat, y: CGFloat) {
            let container = CGRect(x: x, y: y, width: side, height: side)
            context.saveGState()
            context.addPath(CGPath(roundedRect: container, cornerWidth: 18, cornerHeight: 18, transform: nil))
            context.clip()
            let gap: CGFloat = 2
            let tileSide = (side - gap) / 2
            for index in 0..<4 {
                let tileRect = CGRect(
                    x: x + CGFloat(index % 2) * (tileSide + gap),
                    y: y + CGFloat(index / 2) * (tileSide + gap),
                    width: tileSide, height: tileSide
                )
                if index < artwork.collage.count, let image = artwork.collage[index] {
                    drawImageFill(image, in: tileRect)
                } else if index < albums.count {
                    drawMonogram(name: albums[index].name, rect: tileRect, fontSize: 26)
                } else {
                    context.setFillColor(NSColor.white.withAlphaComponent(0.06).cgColor)
                    context.fill(tileRect)
                }
            }
            context.restoreGState()
            strokeRounded(container, radius: 18)
        }

        func drawTile(image: NSImage?, name: String, rect: CGRect, cornerRadius: CGFloat, monogramFontSize: CGFloat) {
            context.saveGState()
            context.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
            context.clip()
            if let image {
                drawImageFill(image, in: rect)
            } else {
                drawMonogram(name: name, rect: rect, fontSize: monogramFontSize)
            }
            context.restoreGState()
            strokeRounded(rect, radius: cornerRadius)
        }

        private func strokeRounded(_ rect: CGRect, radius: CGFloat) {
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.2).cgColor)
            context.setLineWidth(0.5)
            context.strokePath()
        }

        private func drawMonogram(name: String, rect: CGRect, fontSize: CGFloat) {
            context.setFillColor(theme.accent.withAlphaComponent(0.16).cgColor)
            context.fill(rect)
            let initial = name.first.map(String.init)?.uppercased() ?? "♪"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
                .foregroundColor: theme.accent.withAlphaComponent(0.85),
            ]
            let text = initial as NSString
            let textSize = text.size(withAttributes: attributes)
            text.draw(
                at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
                withAttributes: attributes
            )
        }

        private func drawImageFill(_ image: NSImage, in rect: CGRect) {
            guard let cgImage = image.cgImage else { return }
            let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
            let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
            let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let drawRect = CGRect(
                x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2,
                width: drawSize.width, height: drawSize.height
            )
            context.saveGState()
            context.clip(to: rect)
            context.translateBy(x: 0, y: drawRect.maxY + drawRect.minY)
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: drawRect)
            context.restoreGState()
        }

        func drawSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, tint: NSColor, rect: CGRect) {
            let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
                .applying(.init(paletteColors: [tint]))
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration),
                  let cgImage = symbol.cgImage else { return }
            let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
            let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
            let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let drawRect = CGRect(
                x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2,
                width: drawSize.width, height: drawSize.height
            )
            context.saveGState()
            context.translateBy(x: 0, y: drawRect.maxY + drawRect.minY)
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: drawRect)
            context.restoreGState()
        }
    }
}
