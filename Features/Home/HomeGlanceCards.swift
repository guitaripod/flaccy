import FlaccyCore
import UIKit

/// The surface shared by the two small cards of the pair row.
class HomeGlanceCardCell: UICollectionViewCell {

    let kickerLabel = UILabel()
    let kickerIcon = UIImageView()
    let body = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor.label.withAlphaComponent(0.08)
        contentView.layer.cornerRadius = 22
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true

        kickerIcon.tintColor = .secondaryLabel
        kickerIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        kickerIcon.setContentHuggingPriority(.required, for: .horizontal)
        kickerLabel.font = .scaled(.caption1, size: 12, weight: .semibold)
        kickerLabel.textColor = .secondaryLabel
        kickerLabel.adjustsFontForContentSizeCategory = true
        kickerLabel.numberOfLines = 1
        let kicker = UIStackView(arrangedSubviews: [kickerIcon, kickerLabel])
        kicker.axis = .horizontal
        kicker.spacing = 5
        kicker.alignment = .center

        body.axis = .vertical
        body.spacing = 6
        let column = UIStackView(arrangedSubviews: [kicker, body])
        column.axis = .vertical
        column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            column.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -14),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setKicker(_ text: String, symbol: String) {
        kickerLabel.text = text.uppercased()
        kickerIcon.image = UIImage(systemName: symbol)
    }
}

final class HomeMemoryCardCell: HomeGlanceCardCell {

    static let reuseID = "HomeMemoryCardCell"

    private let art = HomeArtView(cornerRadius: 10)
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        art.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            art.widthAnchor.constraint(equalToConstant: 56),
            art.heightAnchor.constraint(equalToConstant: 56),
        ])
        titleLabel.font = .scaled(.subheadline, size: 15, weight: .semibold)
        titleLabel.numberOfLines = 2
        detailLabel.font = .scaled(.footnote, size: 13, weight: .regular)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 2
        titleLabel.adjustsFontForContentSizeCategory = true
        detailLabel.adjustsFontForContentSizeCategory = true
        let artHolder = UIStackView(arrangedSubviews: [art, UIView()])
        artHolder.axis = .horizontal
        [artHolder, titleLabel, detailLabel].forEach(body.addArrangedSubview)
        body.setCustomSpacing(8, after: artHolder)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        art.reset()
    }

    func configure(with memory: HomeFeed.Memory) {
        setKicker(HomeCopy.title(for: .onThisDay), symbol: "calendar")
        titleLabel.text = memory.album.title
        detailLabel.text = HomeCopy.onThisDayDetail(memory.pick)
        art.show(albums: [memory.album])
        accessibilityLabel = "\(HomeCopy.title(for: .onThisDay)), \(memory.album.title), \(HomeCopy.onThisDayDetail(memory.pick))"
    }
}

final class HomeWeekCardCell: HomeGlanceCardCell {

    static let reuseID = "HomeWeekCardCell"
    static let positiveColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.50, green: 0.88, blue: 0.66, alpha: 1)
            : UIColor(red: 0.05, green: 0.50, blue: 0.27, alpha: 1)
    }
    static let negativeColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.62, blue: 0.58, alpha: 1)
            : UIColor(red: 0.74, green: 0.16, blue: 0.14, alpha: 1)
    }

    private let spark = HomeSparkView()
    private let listeningLabel = UILabel()
    private let deltaLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        spark.translatesAutoresizingMaskIntoConstraints = false
        spark.heightAnchor.constraint(equalToConstant: HomeSparkView.height).isActive = true
        listeningLabel.font = .scaled(.headline, size: 17, weight: .bold)
        listeningLabel.adjustsFontForContentSizeCategory = true
        deltaLabel.font = .scaled(.footnote, size: 13, weight: .semibold)
        deltaLabel.adjustsFontForContentSizeCategory = true
        deltaLabel.numberOfLines = 2
        [spark, listeningLabel, deltaLabel].forEach(body.addArrangedSubview)
        body.setCustomSpacing(8, after: spark)
        body.setCustomSpacing(2, after: listeningLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with week: WeekGlance) {
        setKicker(HomeCopy.thisWeek, symbol: "chart.bar.fill")
        spark.setValues(week.daily)
        listeningLabel.text = HomeCopy.listening(week.seconds)
        let plays = HomeCopy.plays(week.plays)
        let delta = HomeCopy.delta(week.playsDelta)
        if let delta {
            let text = NSMutableAttributedString(
                string: delta,
                attributes: [.foregroundColor: Self.color(for: week.playsDelta)]
            )
            text.append(NSAttributedString(string: " · \(plays)", attributes: [.foregroundColor: UIColor.secondaryLabel]))
            deltaLabel.attributedText = text
        } else {
            deltaLabel.attributedText = nil
            deltaLabel.text = plays
            deltaLabel.textColor = .secondaryLabel
        }
        accessibilityLabel = [HomeCopy.thisWeek, listeningLabel.text, delta, plays].compactMap { $0 }.joined(separator: ", ")
        accessibilityHint = HomeCopy.openRecap
    }

    private static func color(for delta: PeriodDelta) -> UIColor {
        switch delta {
        case .down: negativeColor
        case .up, .new: positiveColor
        default: .secondaryLabel
        }
    }
}
