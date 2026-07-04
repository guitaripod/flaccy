import UIKit

/// Off-screen 9:16 story card laid out at 360×640 and rendered at 3× (1080×1920)
/// so it fills the screen when shared to Instagram Stories or similar. The look
/// is editorial: left-aligned type, hairline rules, an oversized vertical year
/// watermark, and monogram tiles standing in for any missing cover art.
final class YearInMusicStoryView: UIView {

    private static let margin: CGFloat = 30

    private let gradient = CAGradientLayer()
    private let glow = CAGradientLayer()
    private var theme = StoryTheme.all(seedPalette: ArtworkPaletteExtractor.fallbackPalette(seed: "flaccy"))[0]

    static func makeImage(slide: StorySlide, data: YearInMusicData, artwork: StoryArtwork, theme: StoryTheme, format: StoryFormat = .story, scale: CGFloat = 3) -> UIImage {
        let size = format.canvasSize
        let card = YearInMusicStoryView(frame: CGRect(origin: .zero, size: size))
        card.configure(slide: slide, data: data, artwork: artwork, theme: theme, format: format)
        card.setNeedsLayout()
        card.layoutIfNeeded()

        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = scale
        rendererFormat.opaque = true
        return UIGraphicsImageRenderer(size: size, format: rendererFormat).image { _ in
            card.drawHierarchy(in: card.bounds, afterScreenUpdates: true)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        layer.insertSublayer(gradient, at: 0)
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        gradient.locations = [0, 0.55, 1]

        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        layer.insertSublayer(glow, at: 1)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
        glow.frame = CGRect(x: bounds.width * 0.35, y: -bounds.height * 0.18, width: bounds.width * 0.95, height: bounds.width * 0.95)
    }

    func configure(slide: StorySlide, data: YearInMusicData, artwork: StoryArtwork, theme: StoryTheme, format: StoryFormat = .story) {
        self.theme = theme
        gradient.colors = theme.gradientColors.map(\.cgColor)
        glow.colors = [theme.accent.withAlphaComponent(0.28).cgColor, UIColor.clear.cgColor]
        subviews.forEach { $0.removeFromSuperview() }

        let compact = format == .post
        addWatermark(year: data.year, fontSize: compact ? 104 : 150)

        let headerRow = UIStackView(arrangedSubviews: [chromeLabel("FLACCY"), UIView(), chromeLabel(String(data.year))])
        headerRow.axis = .horizontal

        let sparkle = UIImageView(image: UIImage(systemName: "sparkles", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)))
        sparkle.tintColor = theme.accent
        sparkle.contentMode = .scaleAspectFit
        let footerRow = UIStackView(arrangedSubviews: [chromeLabel("YEAR IN MUSIC"), UIView(), sparkle])
        footerRow.axis = .horizontal
        footerRow.alignment = .center
        let footer = UIStackView(arrangedSubviews: [hairline(), footerRow])
        footer.axis = .vertical
        footer.spacing = 12

        let content = UIStackView()
        content.axis = .vertical
        content.alignment = .fill

        switch slide {
        case .overview: buildOverview(into: content, data: data, artwork: artwork)
        case .artists: buildRanked(into: content, caption: "MY TOP ARTISTS", entries: data.topArtists.map { ($0.name, nil, $0.playCount) }, rowArt: artwork.artistRows, footnote: "\(RecapFormat.count(data.distinctArtists)) artists this year")
        case .tracks: buildRanked(into: content, caption: "MY TOP TRACKS", entries: data.topTracks.map { ($0.name, $0.artistName, $0.playCount) }, rowArt: artwork.trackRows, footnote: "\(RecapFormat.count(data.distinctTracks)) tracks this year")
        case .numbers: buildNumbers(into: content, data: data)
        case .poster: buildPoster(into: content, data: data, artwork: artwork, compact: compact)
        }

        for view in [headerRow, content, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: topAnchor, constant: 26),
            headerRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.margin),
            headerRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.margin),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.margin),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.margin),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: compact ? 18 : 30),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.margin),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.margin),
            content.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -16),
        ])
    }

    private func buildOverview(into content: UIStackView, data: YearInMusicData, artwork: StoryArtwork) {
        content.addArrangedSubview(captionLabel("MY YEAR IN MUSIC"))
        content.setCustomSpacing(4, after: content.arrangedSubviews.last!)

        let year = UILabel()
        year.text = String(data.year)
        year.font = .systemFont(ofSize: 84, weight: .heavy)
        year.textColor = .white
        content.addArrangedSubview(year)
        content.setCustomSpacing(18, after: year)

        let heroBand = UIStackView(arrangedSubviews: [
            collageView(artwork: artwork, albums: data.topAlbums, side: 148),
            overviewHighlights(data: data),
        ])
        heroBand.axis = .horizontal
        heroBand.spacing = 18
        heroBand.alignment = .center
        content.addArrangedSubview(heroBand)
        content.setCustomSpacing(22, after: heroBand)

        content.addArrangedSubview(statTable([
            ("MINUTES LISTENED", RecapFormat.count(data.totalMinutes)),
            ("TRACKS PLAYED", RecapFormat.count(data.totalPlays)),
            ("ARTISTS", RecapFormat.count(data.distinctArtists)),
        ]))
        content.setCustomSpacing(20, after: content.arrangedSubviews.last!)
        content.addArrangedSubview(wrapLeading(personaPill(data.persona)))
    }

    private func overviewHighlights(data: YearInMusicData) -> UIStackView {
        let column = UIStackView()
        column.axis = .vertical
        column.spacing = 14
        column.alignment = .leading
        if let topArtist = data.topArtists.first {
            column.addArrangedSubview(highlightBlock(caption: "TOP ARTIST", title: topArtist.name, size: 21))
        }
        if let topTrack = data.topTracks.first {
            column.addArrangedSubview(highlightBlock(caption: "TOP TRACK", title: topTrack.name, subtitle: topTrack.artistName, size: 16))
        }
        return column
    }

    private func buildRanked(into content: UIStackView, caption: String, entries: [(title: String, subtitle: String?, plays: Int)], rowArt: [UIImage?], footnote: String) {
        content.addArrangedSubview(captionLabel(caption))
        content.setCustomSpacing(18, after: content.arrangedSubviews.last!)

        guard let first = entries.first else { return }

        let heroImage = heroTile(image: rowArt.first ?? nil, name: first.title, side: 128)
        let firstBlock = UIStackView()
        firstBlock.axis = .vertical
        firstBlock.spacing = 4
        firstBlock.alignment = .leading
        let rankOne = UILabel()
        rankOne.text = "#1"
        rankOne.font = .systemFont(ofSize: 20, weight: .heavy)
        rankOne.textColor = theme.accent
        let firstName = UILabel()
        firstName.text = first.title
        firstName.font = .systemFont(ofSize: 25, weight: .heavy)
        firstName.textColor = .white
        firstName.numberOfLines = 3
        firstBlock.addArrangedSubview(rankOne)
        firstBlock.addArrangedSubview(firstName)
        if let subtitle = first.subtitle {
            firstBlock.addArrangedSubview(subtitleLabel(subtitle, size: 14))
        }
        firstBlock.addArrangedSubview(spacerView(2))
        firstBlock.addArrangedSubview(subtitleLabel("\(RecapFormat.count(first.plays)) plays", size: 13, color: theme.accent))

        let heroBand = UIStackView(arrangedSubviews: [heroImage, firstBlock])
        heroBand.axis = .horizontal
        heroBand.spacing = 18
        heroBand.alignment = .center
        content.addArrangedSubview(heroBand)
        content.setCustomSpacing(24, after: heroBand)

        let list = UIStackView()
        list.axis = .vertical
        list.spacing = 0
        for (index, entry) in entries.dropFirst().prefix(4).enumerated() {
            let art = rowArt.indices.contains(index + 1) ? rowArt[index + 1] : nil
            list.addArrangedSubview(hairline())
            list.addArrangedSubview(rankedRow(rank: index + 2, entry: entry, art: art))
        }
        content.addArrangedSubview(list)
        content.setCustomSpacing(20, after: list)
        content.addArrangedSubview(subtitleLabel(footnote, size: 13))
    }

    private func rankedRow(rank: Int, entry: (title: String, subtitle: String?, plays: Int), art: UIImage?) -> UIStackView {
        let rankLabel = UILabel()
        rankLabel.text = "\(rank)"
        rankLabel.font = .systemFont(ofSize: 15, weight: .heavy)
        rankLabel.textColor = theme.accent
        rankLabel.widthAnchor.constraint(equalToConstant: 20).isActive = true

        let thumb: UIView
        if let art {
            let imageView = UIImageView(image: art)
            imageView.contentMode = .scaleAspectFill
            thumb = imageView
        } else {
            thumb = monogramTile(name: entry.title, fontSize: 15)
        }
        thumb.clipsToBounds = true
        thumb.layer.cornerRadius = 8
        thumb.layer.cornerCurve = .continuous
        thumb.widthAnchor.constraint(equalToConstant: 34).isActive = true
        thumb.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let name = UILabel()
        name.text = entry.title
        name.font = .systemFont(ofSize: 16, weight: .bold)
        name.textColor = .white
        name.adjustsFontSizeToFitWidth = true
        name.minimumScaleFactor = 0.7

        let nameColumn = UIStackView(arrangedSubviews: [name])
        nameColumn.axis = .vertical
        nameColumn.spacing = 1
        if let subtitle = entry.subtitle {
            nameColumn.addArrangedSubview(subtitleLabel(subtitle, size: 12))
        }

        let plays = UILabel()
        plays.text = RecapFormat.compact(entry.plays)
        plays.font = .systemFont(ofSize: 13, weight: .semibold)
        plays.textColor = UIColor.white.withAlphaComponent(0.55)
        plays.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [rankLabel, thumb, nameColumn, UIView(), plays])
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .center
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 9, left: 0, bottom: 9, right: 0)
        return row
    }

    private func buildNumbers(into content: UIStackView, data: YearInMusicData) {
        content.addArrangedSubview(captionLabel("THE NUMBERS"))
        content.setCustomSpacing(14, after: content.arrangedSubviews.last!)

        let minutes = UILabel()
        minutes.text = RecapFormat.count(data.totalMinutes)
        minutes.font = .systemFont(ofSize: 62, weight: .heavy)
        minutes.textColor = theme.accent
        minutes.adjustsFontSizeToFitWidth = true
        minutes.minimumScaleFactor = 0.5
        content.addArrangedSubview(minutes)
        content.setCustomSpacing(2, after: minutes)
        content.addArrangedSubview(captionLabel("MINUTES LISTENED"))
        content.setCustomSpacing(22, after: content.arrangedSubviews.last!)

        content.addArrangedSubview(statTable([
            ("TRACKS PLAYED", RecapFormat.count(data.totalPlays)),
            ("ARTISTS", RecapFormat.count(data.distinctArtists)),
            ("ALBUMS", RecapFormat.count(data.distinctAlbums)),
            ("DIFFERENT TRACKS", RecapFormat.count(data.distinctTracks)),
        ]))
        content.setCustomSpacing(22, after: content.arrangedSubviews.last!)

        let facts = UIStackView()
        facts.axis = .vertical
        facts.spacing = 10
        facts.alignment = .leading
        if let peakDay = data.peakDay {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMMM d"
            facts.addArrangedSubview(factRow(symbol: "calendar", text: "Biggest day: \(formatter.string(from: peakDay)) — \(RecapFormat.count(data.peakDayPlays)) plays"))
        }
        if let peakHour = data.peakHour {
            facts.addArrangedSubview(factRow(symbol: "clock.fill", text: "Power hour: \(Self.hourLabel(peakHour))"))
        }
        if data.longestStreak > 1 {
            facts.addArrangedSubview(factRow(symbol: "flame.fill", text: "Longest streak: \(data.longestStreak) days"))
        }
        content.addArrangedSubview(facts)
        content.setCustomSpacing(20, after: facts)
        content.addArrangedSubview(wrapLeading(personaPill(data.persona)))
    }

    private func buildPoster(into content: UIStackView, data: YearInMusicData, artwork: StoryArtwork, compact: Bool) {
        if !compact {
            content.addArrangedSubview(captionLabel("MY YEAR IN MUSIC"))
            content.setCustomSpacing(2, after: content.arrangedSubviews.last!)
        }

        let year = UILabel()
        year.text = String(data.year)
        year.font = .systemFont(ofSize: compact ? 38 : 46, weight: .heavy)
        year.textColor = .white
        content.addArrangedSubview(year)
        content.setCustomSpacing(compact ? 10 : 14, after: year)

        let band = UIStackView(arrangedSubviews: [
            collageView(artwork: artwork, albums: data.topAlbums, side: compact ? 86 : 104),
            posterStatColumn(data: data),
        ])
        band.axis = .horizontal
        band.spacing = 16
        band.alignment = .center
        content.addArrangedSubview(band)
        content.setCustomSpacing(compact ? 12 : 16, after: band)

        content.addArrangedSubview(hairline())
        content.setCustomSpacing(compact ? 10 : 14, after: content.arrangedSubviews.last!)

        let columns = UIStackView(arrangedSubviews: [
            miniList(caption: "TOP ARTISTS", entries: data.topArtists.map { ($0.name, $0.playCount) }, compact: compact),
            miniList(caption: "TOP TRACKS", entries: data.topTracks.map { ($0.name, $0.playCount) }, compact: compact),
        ])
        columns.axis = .horizontal
        columns.spacing = 18
        columns.distribution = .fillEqually
        columns.alignment = .top
        content.addArrangedSubview(columns)
        content.setCustomSpacing(compact ? 10 : 14, after: columns)

        content.addArrangedSubview(hairline())
        content.setCustomSpacing(compact ? 10 : 14, after: content.arrangedSubviews.last!)

        if !compact {
            let facts = UIStackView()
            facts.axis = .vertical
            facts.spacing = 7
            facts.alignment = .leading
            if let peakDay = data.peakDay {
                let formatter = DateFormatter()
                formatter.dateFormat = "MMMM d"
                facts.addArrangedSubview(factRow(symbol: "calendar", text: "Biggest day: \(formatter.string(from: peakDay)) — \(RecapFormat.count(data.peakDayPlays)) plays"))
            }
            if data.longestStreak > 1 {
                facts.addArrangedSubview(factRow(symbol: "flame.fill", text: "Longest streak: \(data.longestStreak) days"))
            }
            content.addArrangedSubview(facts)
            content.setCustomSpacing(14, after: facts)
        }
        content.addArrangedSubview(wrapLeading(personaPill(data.persona)))
    }

    private func posterStatColumn(data: YearInMusicData) -> UIStackView {
        let minutes = UILabel()
        minutes.text = RecapFormat.count(data.totalMinutes)
        minutes.font = .systemFont(ofSize: 30, weight: .heavy)
        minutes.textColor = theme.accent
        minutes.adjustsFontSizeToFitWidth = true
        minutes.minimumScaleFactor = 0.5

        let column = UIStackView(arrangedSubviews: [
            minutes,
            captionLabel("MINUTES LISTENED"),
            spacerView(6),
            subtitleLabel("\(RecapFormat.count(data.totalPlays)) plays · \(RecapFormat.count(data.distinctArtists)) artists", size: 13),
        ])
        column.axis = .vertical
        column.spacing = 2
        column.alignment = .leading
        return column
    }

    private func miniList(caption: String, entries: [(name: String, plays: Int)], compact: Bool) -> UIStackView {
        let list = UIStackView()
        list.axis = .vertical
        list.spacing = compact ? 5 : 7
        list.alignment = .fill
        list.addArrangedSubview(captionLabel(caption))
        list.setCustomSpacing(compact ? 7 : 9, after: list.arrangedSubviews.last!)

        for (index, entry) in entries.prefix(5).enumerated() {
            let rank = UILabel()
            rank.text = "\(index + 1)"
            rank.font = .systemFont(ofSize: 12, weight: .heavy)
            rank.textColor = theme.accent
            rank.widthAnchor.constraint(equalToConstant: 12).isActive = true

            let name = UILabel()
            name.text = entry.name
            name.font = .systemFont(ofSize: 13, weight: .bold)
            name.textColor = .white
            name.lineBreakMode = .byTruncatingTail

            let plays = UILabel()
            plays.text = RecapFormat.compact(entry.plays)
            plays.font = .systemFont(ofSize: 11, weight: .semibold)
            plays.textColor = UIColor.white.withAlphaComponent(0.5)
            plays.setContentCompressionResistancePriority(.required, for: .horizontal)

            let row = UIStackView(arrangedSubviews: [rank, name, UIView(), plays])
            row.axis = .horizontal
            row.spacing = 6
            row.alignment = .firstBaseline
            list.addArrangedSubview(row)
        }
        return list
    }

    private static func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? Date(timeIntervalSince1970: 0)
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func addWatermark(year: Int, fontSize: CGFloat) {
        let watermark = UILabel()
        watermark.text = String(year)
        watermark.font = .systemFont(ofSize: fontSize, weight: .heavy)
        watermark.textColor = UIColor.white.withAlphaComponent(0.05)
        watermark.transform = CGAffineTransform(rotationAngle: .pi / 2)
        watermark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(watermark)
        NSLayoutConstraint.activate([
            watermark.centerXAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            watermark.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 40),
        ])
    }

    private func hairline() -> UIView {
        let line = UIView()
        line.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        line.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return line
    }

    private func spacerView(_ height: CGFloat) -> UIView {
        let view = UIView()
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    private func wrapLeading(_ view: UIView) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: [view, UIView()])
        stack.axis = .horizontal
        return stack
    }

    private func statTable(_ rows: [(caption: String, value: String)]) -> UIStackView {
        let table = UIStackView()
        table.axis = .vertical
        table.spacing = 0
        for row in rows {
            table.addArrangedSubview(hairline())
            let caption = UILabel()
            caption.attributedText = NSAttributedString(
                string: row.caption,
                attributes: [.kern: 1.5, .font: UIFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: UIColor.white.withAlphaComponent(0.55)]
            )
            let value = UILabel()
            value.text = row.value
            value.font = .systemFont(ofSize: 21, weight: .heavy)
            value.textColor = theme.accent
            value.setContentCompressionResistancePriority(.required, for: .horizontal)
            let line = UIStackView(arrangedSubviews: [caption, UIView(), value])
            line.axis = .horizontal
            line.alignment = .center
            line.isLayoutMarginsRelativeArrangement = true
            line.layoutMargins = UIEdgeInsets(top: 9, left: 0, bottom: 9, right: 0)
            table.addArrangedSubview(line)
        }
        table.addArrangedSubview(hairline())
        return table
    }

    private func factRow(symbol: String, text: String) -> UIStackView {
        let icon = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)))
        icon.tintColor = theme.accent
        icon.contentMode = .scaleAspectFit
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true

        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = UIColor.white.withAlphaComponent(0.85)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.8

        let row = UIStackView(arrangedSubviews: [icon, label])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        return row
    }

    private func chromeLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.attributedText = NSAttributedString(
            string: text,
            attributes: [.kern: 3, .font: UIFont.systemFont(ofSize: 11, weight: .heavy), .foregroundColor: UIColor.white.withAlphaComponent(0.8)]
        )
        return label
    }

    private func captionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.attributedText = NSAttributedString(
            string: text,
            attributes: [.kern: 2.2, .font: UIFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: UIColor.white.withAlphaComponent(0.65)]
        )
        return label
    }

    private func subtitleLabel(_ text: String, size: CGFloat, color: UIColor? = nil) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: size, weight: .semibold)
        label.textColor = color ?? UIColor.white.withAlphaComponent(0.6)
        return label
    }

    private func highlightBlock(caption: String, title: String, subtitle: String? = nil, size: CGFloat) -> UIStackView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: size, weight: .heavy)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2

        let stack = UIStackView(arrangedSubviews: [captionLabel(caption), titleLabel])
        stack.axis = .vertical
        stack.spacing = 3
        stack.alignment = .leading
        if let subtitle {
            stack.addArrangedSubview(subtitleLabel(subtitle, size: 12))
        }
        return stack
    }

    private func personaPill(_ persona: String) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: RecapPersona.symbol(for: persona)))
        icon.tintColor = theme.accent
        icon.contentMode = .scaleAspectFit
        icon.widthAnchor.constraint(equalToConstant: 15).isActive = true

        let label = UILabel()
        label.text = persona
        label.font = .systemFont(ofSize: 14, weight: .bold)
        label.textColor = .white

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        stack.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        stack.layer.cornerRadius = 17
        stack.layer.cornerCurve = .continuous
        stack.layer.borderWidth = 0.5
        stack.layer.borderColor = theme.accent.withAlphaComponent(0.5).cgColor
        stack.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return stack
    }

    private func monogramTile(name: String, fontSize: CGFloat) -> UIView {
        let tile = UIView()
        tile.backgroundColor = theme.accent.withAlphaComponent(0.16)
        let initial = UILabel()
        initial.text = name.first.map(String.init)?.uppercased() ?? "♪"
        initial.font = .systemFont(ofSize: fontSize, weight: .heavy)
        initial.textColor = theme.accent.withAlphaComponent(0.85)
        initial.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(initial)
        NSLayoutConstraint.activate([
            initial.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            initial.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        return tile
    }

    private func heroTile(image: UIImage?, name: String, side: CGFloat) -> UIView {
        let tile: UIView
        if let image {
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleAspectFill
            tile = imageView
        } else {
            tile = monogramTile(name: name, fontSize: side * 0.42)
        }
        tile.clipsToBounds = true
        tile.layer.cornerRadius = 20
        tile.layer.cornerCurve = .continuous
        tile.layer.borderWidth = 0.5
        tile.layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor
        tile.widthAnchor.constraint(equalToConstant: side).isActive = true
        tile.heightAnchor.constraint(equalToConstant: side).isActive = true
        return tile
    }

    private func collageView(artwork: StoryArtwork, albums: [ChartAlbum], side: CGFloat) -> UIView {
        let container = UIView()
        container.layer.cornerRadius = 18
        container.layer.cornerCurve = .continuous
        container.clipsToBounds = true
        container.layer.borderWidth = 0.5
        container.layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor
        container.widthAnchor.constraint(equalToConstant: side).isActive = true
        container.heightAnchor.constraint(equalToConstant: side).isActive = true

        let gap: CGFloat = 2
        let tileSide = (side - gap) / 2
        for index in 0..<4 {
            let tile: UIView
            if index < artwork.collage.count, let image = artwork.collage[index] {
                let imageView = UIImageView(image: image)
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true
                tile = imageView
            } else if index < albums.count {
                tile = monogramTile(name: albums[index].name, fontSize: 26)
            } else {
                tile = UIView()
                tile.backgroundColor = UIColor.white.withAlphaComponent(0.06)
            }
            let x = CGFloat(index % 2) * (tileSide + gap)
            let y = CGFloat(index / 2) * (tileSide + gap)
            tile.frame = CGRect(x: x, y: y, width: tileSide, height: tileSide)
            container.addSubview(tile)
        }
        return container
    }
}
