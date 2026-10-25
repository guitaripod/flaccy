import AppKit
import FlaccyCore

/// "On this day in 2023": the album played most on today's date in an earlier
/// year, with a Play button.
final class MacHomeMemoryCard: MacHomeSurfaceView {

    static let height: CGFloat = 64

    init(memory: HomeFeed.Memory, onOpen: @escaping () -> Void, onPlay: @escaping () -> Void) {
        super.init(cornerRadius: 14)
        let cover = MacHomeCoverView(cornerRadius: 8)
        cover.show(MacHomeCoverView.Subject(albums: [memory.album], seed: memory.album.id, playlistID: nil))
        cover.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cover)

        let headline = NSTextField(labelWithString: HomeCopy.onThisDayHeadline(memory.pick))
        headline.font = .systemFont(ofSize: 12, weight: .semibold)
        headline.textColor = .secondaryLabelColor
        headline.lineBreakMode = .byTruncatingTail
        let line = NSTextField(labelWithString: HomeCopy.onThisDayLine(memory.pick))
        line.font = .systemFont(ofSize: 13, weight: .semibold)
        line.textColor = .labelColor
        line.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [headline, line])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(text)

        let play = MacHomeFilledButton(title: HomeCopy.play, symbol: "play.fill", height: 28)
        play.onClick = onPlay
        play.translatesAutoresizingMaskIntoConstraints = false
        play.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(play)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            cover.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            cover.centerYAnchor.constraint(equalTo: centerYAnchor),
            cover.widthAnchor.constraint(equalToConstant: 40),
            cover.heightAnchor.constraint(equalToConstant: 40),
            text.leadingAnchor.constraint(equalTo: cover.trailingAnchor, constant: 12),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: play.leadingAnchor, constant: -12),
            play.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            play.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        onClick = onOpen
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(HomeCopy.onThisDayHeadline(memory.pick)). \(HomeCopy.onThisDayLine(memory.pick))")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// "This week": hours listened, how the plays moved against the week before,
/// a seven-bar spark and a link into Recap.
final class MacHomeWeekCard: MacHomeSurfaceView {

    init(week: WeekGlance, onOpenRecap: @escaping () -> Void) {
        super.init(cornerRadius: 14)
        let heading = NSTextField(labelWithString: HomeCopy.thisWeek)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.textColor = .secondaryLabelColor

        let listening = NSTextField(labelWithString: HomeCopy.listening(week.seconds))
        listening.font = .systemFont(ofSize: 15, weight: .bold)
        listening.textColor = .labelColor

        var detail: [NSView] = [listening]
        if let delta = HomeCopy.delta(week.playsDelta) {
            let change = NSTextField(labelWithString: delta)
            change.font = .systemFont(ofSize: 12, weight: .semibold)
            change.textColor = Self.color(for: week.playsDelta)
            detail.append(change)
        }
        let plays = NSTextField(labelWithString: HomeCopy.plays(week.plays))
        plays.font = .systemFont(ofSize: 12)
        plays.textColor = .secondaryLabelColor
        plays.lineBreakMode = .byTruncatingTail
        detail.append(plays)
        let detailRow = NSStackView(views: detail)
        detailRow.orientation = .horizontal
        detailRow.alignment = .firstBaseline
        detailRow.spacing = 8

        let text = NSStackView(views: [heading, detailRow])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(text)

        let spark = MacHomeSparkView()
        spark.daily = week.daily
        spark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spark)

        let recap = MacHomeLinkButton(title: HomeCopy.openRecap, size: 12)
        recap.onClick = onOpenRecap
        recap.translatesAutoresizingMaskIntoConstraints = false
        recap.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(recap)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: MacHomeMemoryCard.height),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: spark.leadingAnchor, constant: -16),
            spark.centerYAnchor.constraint(equalTo: centerYAnchor),
            spark.widthAnchor.constraint(equalToConstant: MacHomeSparkView.size.width),
            spark.heightAnchor.constraint(equalToConstant: MacHomeSparkView.size.height),
            spark.trailingAnchor.constraint(equalTo: recap.leadingAnchor, constant: -16),
            recap.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            recap.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        onClick = onOpenRecap
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(HomeCopy.thisWeek). \(HomeCopy.listening(week.seconds)), \(HomeCopy.plays(week.plays))")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func color(for delta: PeriodDelta) -> NSColor {
        switch delta {
        case .up, .new: .systemGreen
        case .down: .systemOrange
        case .even, .none: .secondaryLabelColor
        }
    }
}
