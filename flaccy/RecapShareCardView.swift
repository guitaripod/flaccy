import UIKit

/// A self-contained, off-screen card laid out for sharing: renders the current
/// Recap into a 4:5 image via UIGraphicsImageRenderer.
final class RecapShareCardView: UIView {

    private let gradient = CAGradientLayer()

    static func makeImage(data: RecapData, palette: ArtworkPalette) -> UIImage {
        let size = CGSize(width: 360, height: 450)
        let card = RecapShareCardView(frame: CGRect(origin: .zero, size: size))
        card.configure(data: data, palette: palette)
        card.setNeedsLayout()
        card.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            card.drawHierarchy(in: card.bounds, afterScreenUpdates: true)
        }
    }

    private let title = UILabel()
    private let subtitle = UILabel()
    private let playsValue = UILabel()
    private let playsCaption = UILabel()
    private let minutesValue = UILabel()
    private let minutesCaption = UILabel()
    private let artistsTitle = UILabel()
    private let artistsList = UILabel()
    private let personaBadge = UILabel()
    private let footer = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        layer.insertSublayer(gradient, at: 0)

        title.font = .systemFont(ofSize: 30, weight: .heavy)
        title.textColor = .white

        subtitle.font = .systemFont(ofSize: 14, weight: .medium)
        subtitle.textColor = UIColor.white.withAlphaComponent(0.7)

        configureStat(value: playsValue, caption: playsCaption, captionText: "PLAYS")
        configureStat(value: minutesValue, caption: minutesCaption, captionText: "MINUTES")

        artistsTitle.font = .systemFont(ofSize: 13, weight: .bold)
        artistsTitle.textColor = UIColor.white.withAlphaComponent(0.6)
        artistsTitle.text = "TOP ARTISTS"

        artistsList.font = .systemFont(ofSize: 19, weight: .semibold)
        artistsList.textColor = .white
        artistsList.numberOfLines = 0

        personaBadge.font = .systemFont(ofSize: 15, weight: .bold)
        personaBadge.textColor = .white
        personaBadge.textAlignment = .center
        personaBadge.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        personaBadge.layer.cornerRadius = 16
        personaBadge.layer.masksToBounds = true

        footer.font = .systemFont(ofSize: 12, weight: .semibold)
        footer.textColor = UIColor.white.withAlphaComponent(0.6)
        footer.text = "flaccy \u{00B7} Recap"

        let playsCol = column(playsValue, playsCaption)
        let minutesCol = column(minutesValue, minutesCaption)
        let statsRow = UIStackView(arrangedSubviews: [playsCol, minutesCol])
        statsRow.axis = .horizontal
        statsRow.distribution = .fillEqually
        statsRow.spacing = 16

        let stack = UIStackView(arrangedSubviews: [title, subtitle, spacer(10), statsRow, spacer(10), artistsTitle, artistsList])
        stack.axis = .vertical
        stack.spacing = 6
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        personaBadge.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(personaBadge)
        addSubview(footer)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 32),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            personaBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            personaBadge.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -14),
            personaBadge.heightAnchor.constraint(equalToConstant: 34),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
    }

    private func configureStat(value: UILabel, caption: UILabel, captionText: String) {
        value.font = .systemFont(ofSize: 44, weight: .heavy)
        value.textColor = .white
        value.adjustsFontSizeToFitWidth = true
        value.minimumScaleFactor = 0.5
        caption.font = .systemFont(ofSize: 12, weight: .bold)
        caption.textColor = UIColor.white.withAlphaComponent(0.55)
        caption.text = captionText
    }

    private func column(_ value: UILabel, _ caption: UILabel) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: [value, caption])
        stack.axis = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        return stack
    }

    private func spacer(_ height: CGFloat) -> UIView {
        let view = UIView()
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    func configure(data: RecapData, palette: ArtworkPalette) {
        title.text = data.userInfo?.name ?? "Your Recap"
        subtitle.text = "\(data.period.displayName) \u{00B7} flaccy Recap"
        playsValue.text = RecapFormat.count(data.totalPlays)
        minutesValue.text = RecapFormat.count(data.totalMinutes)
        artistsList.text = data.topArtists.prefix(5).enumerated()
            .map { "\($0.offset + 1)  \($0.element.name)" }
            .joined(separator: "\n")
        personaBadge.text = "  \(data.persona)  "

        let colors = palette.colors
        let first = (colors.first ?? .systemIndigo)
        let second = (colors.count > 2 ? colors[2] : colors.last ?? .systemPurple)
        gradient.colors = [
            Self.darken(first, 0.55).cgColor,
            Self.darken(second, 0.7).cgColor,
            UIColor.black.cgColor,
        ]
        gradient.locations = [0, 0.6, 1]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
    }

    private static func darken(_ color: UIColor, _ factor: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r * factor, green: g * factor, blue: b * factor, alpha: 1)
    }
}
