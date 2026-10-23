import ImageIO
import MidgarCore
import UIKit

final class ClockCell: UICollectionViewCell {
    static let reuseID = "ClockCell"
    let card = recapCard()
    let clock = ListeningClockView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.translatesAutoresizingMaskIntoConstraints = false
        clock.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)
        card.addSubview(clock)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            clock.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            clock.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            clock.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            clock.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: ClockItem, tint: UIColor) {
        clock.configure(buckets: item.buckets, tint: tint)
    }
}

final class StreakCell: UICollectionViewCell {
    static let reuseID = "StreakCell"
    let card = recapCard()
    let flameLabel = UILabel()
    let streakValue = UILabel()
    let streakCaption = UILabel()
    let heatmap = HeatmapView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        flameLabel.text = "\u{1F525}"
        flameLabel.font = .systemFont(ofSize: 30)

        streakValue.font = .scaled(.largeTitle, size: 34, weight: .heavy)
        streakValue.adjustsFontForContentSizeCategory = true
        streakValue.textColor = .white

        streakCaption.font = .scaled(.caption1, size: 12, weight: .semibold)
        streakCaption.adjustsFontForContentSizeCategory = true
        streakCaption.textColor = UIColor.white.withAlphaComponent(0.55)

        let valueRow = UIStackView(arrangedSubviews: [streakValue, streakCaption])
        valueRow.axis = .vertical
        valueRow.spacing = 0

        let topRow = UIStackView(arrangedSubviews: [flameLabel, valueRow])
        topRow.axis = .horizontal
        topRow.spacing = 10
        topRow.alignment = .center

        heatmap.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [topRow, heatmap])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: StreakItem, tint: UIColor) {
        let days = item.streakDays
        streakValue.text = "\(days)"
        streakCaption.text = days == 1 ? String(localized: "DAY STREAK") : String(localized: "DAY STREAK")
        heatmap.configure(counts: item.heatmap, tint: tint)
        isAccessibilityElement = false
    }
}

final class PersonaCell: UICollectionViewCell {
    static let reuseID = "PersonaCell"

    let gradient = CAGradientLayer()
    let card = UIView()
    let iconView = UIImageView()
    let personaLabel = UILabel()
    let blurbLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.addSublayer(gradient)

        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 30, weight: .bold)

        personaLabel.font = .scaled(.title1, size: 28, weight: .heavy)
        personaLabel.adjustsFontForContentSizeCategory = true
        personaLabel.textColor = .white

        blurbLabel.font = .scaled(.subheadline, size: 15, weight: .medium)
        blurbLabel.adjustsFontForContentSizeCategory = true
        blurbLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        blurbLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [iconView, personaLabel, blurbLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        contentView.addSubview(card)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -22),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = card.bounds
    }

    func configure(_ item: PersonaItem, palette: ArtworkPalette) {
        personaLabel.text = RecapPersona.title(for: item.persona)
        blurbLabel.text = RecapPersona.blurb(for: item.persona)
        iconView.image = UIImage(systemName: RecapPersona.symbol(for: item.persona))
        let colors = palette.colors
        let first = (colors.first ?? .systemIndigo).cgColor
        let second = (colors.count > 2 ? colors[2] : colors.last ?? .systemPurple).cgColor
        gradient.colors = [first, second]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        isAccessibilityElement = true
        accessibilityLabel = String(
            localized: "Your persona: \(RecapPersona.title(for: item.persona)). \(RecapPersona.blurb(for: item.persona))"
        )
    }
}

final class PeriodSelectorCell: UICollectionViewCell {
    static let reuseID = "PeriodSelectorCell"

    var capsules: [ChartPeriod: GlassCapsule] = [:]
    let stack = UIStackView()
    var selectedPeriod: ChartPeriod = .allTime
    var onSelect: ((ChartPeriod) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .horizontal
        stack.spacing = 8
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func build() {
        for period in RecapPeriods.all {
            let button = UIButton(type: .system)
            button.setTitle(period.shortName, for: .normal)
            button.titleLabel?.font = .scaled(.footnote, size: 13, weight: .semibold)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.setTitleColor(.white, for: .normal)
            button.accessibilityLabel = period.displayName
            button.addAction(UIAction { [weak self] _ in
                UISelectionFeedbackGenerator().selectionChanged()
                self?.onSelect?(period)
            }, for: .touchUpInside)
            let capsule = GlassCapsule(hosting: button, height: 38)
            capsule.isAccessibilityElement = false
            capsules[period] = capsule
            stack.addArrangedSubview(capsule)
        }
    }

    func configure(selected: ChartPeriod) {
        self.selectedPeriod = selected
        for (period, capsule) in capsules {
            let active = period == selected
            capsule.setActive(active, animated: !UIAccessibility.isReduceMotionEnabled)
            if let button = capsule.subviews.compactMap({ $0 as? UIButton }).first {
                button.accessibilityTraits = active ? [.button, .selected] : .button
            }
        }
    }
}

/// The 7D / 1M / 3M / 1Y / All subset of ChartPeriod the Recap surfaces.
enum RecapPeriods {
    static let all: [ChartPeriod] = [.week, .month, .threeMonths, .year, .allTime]
}
