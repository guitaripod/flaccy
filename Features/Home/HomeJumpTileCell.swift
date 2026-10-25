import FlaccyCore
import UIKit

/// One entry of Jump Back In: a 56 pt cover beside a two-line title.
final class HomeJumpTileCell: UICollectionViewCell {

    static let reuseID = "HomeJumpTileCell"
    static let height: CGFloat = 56

    private let art = HomeArtView(cornerRadius: 0)
    private let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor.label.withAlphaComponent(0.08)
        contentView.layer.cornerRadius = 10
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true

        art.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .scaled(.subheadline, size: 14, weight: .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 2
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(art)
        contentView.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            art.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            art.topAnchor.constraint(equalTo: contentView.topAnchor),
            art.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            art.widthAnchor.constraint(equalToConstant: Self.height),
            art.heightAnchor.constraint(equalToConstant: Self.height),
            titleLabel.leadingAnchor.constraint(equalTo: art.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        art.reset()
    }

    func configure(with item: HomeFeed.Item) {
        titleLabel.text = item.context.title
        art.show(albums: item.coverAlbums, glyph: item.context.kind == .radio ? "dot.radiowaves.left.and.right" : nil)
        accessibilityLabel = item.context.subtitle.isEmpty
            ? item.context.title
            : "\(item.context.title), \(item.context.subtitle)"
    }
}
