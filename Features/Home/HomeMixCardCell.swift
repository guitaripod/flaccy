import FlaccyCore
import UIKit

/// A card in Made for You: a mix, Library Radio, or the dashed placeholder
/// that keeps the row from looking empty while the history is thin.
final class HomeMixCardCell: UICollectionViewCell {

    static let reuseID = "HomeMixCardCell"
    static let artSide: CGFloat = 160
    private static let playSide: CGFloat = 34

    var onPlay: (() -> Void)?

    private let art = HomeArtView(cornerRadius: 14, showsShadow: true, placeholderPointSize: 44)
    private let playButton = UIButton(type: .custom)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let placeholderLabel = UILabel()
    private let dashed = CAShapeLayer()
    private let textStack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        art.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(art)

        playButton.backgroundColor = .white
        playButton.layer.cornerRadius = Self.playSide / 2
        playButton.setImage(
            UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)),
            for: .normal
        )
        playButton.tintColor = .black
        playButton.layer.shadowColor = UIColor.black.cgColor
        playButton.layer.shadowOpacity = 0.3
        playButton.layer.shadowRadius = 6
        playButton.layer.shadowOffset = CGSize(width: 0, height: 2)
        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.addAction(UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            self?.onPlay?()
        }, for: .touchUpInside)
        contentView.addSubview(playButton)

        titleLabel.font = .scaled(.subheadline, size: 15, weight: .semibold)
        titleLabel.numberOfLines = 1
        subtitleLabel.font = .scaled(.footnote, size: 13, weight: .regular)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 2
        titleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.adjustsFontForContentSizeCategory = true
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(subtitleLabel)
        textStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(textStack)

        dashed.fillColor = UIColor.clear.cgColor
        dashed.lineWidth = 1.5
        dashed.lineDashPattern = [6, 5]
        dashed.isHidden = true
        art.layer.addSublayer(dashed)
        placeholderLabel.font = .scaled(.footnote, size: 13, weight: .medium)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .secondaryLabel
        placeholderLabel.numberOfLines = 0
        placeholderLabel.textAlignment = .center
        placeholderLabel.isHidden = true
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            art.topAnchor.constraint(equalTo: contentView.topAnchor),
            art.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            art.widthAnchor.constraint(equalToConstant: Self.artSide),
            art.heightAnchor.constraint(equalToConstant: Self.artSide),
            playButton.widthAnchor.constraint(equalToConstant: Self.playSide),
            playButton.heightAnchor.constraint(equalToConstant: Self.playSide),
            playButton.trailingAnchor.constraint(equalTo: art.trailingAnchor, constant: -8),
            playButton.bottomAnchor.constraint(equalTo: art.bottomAnchor, constant: -8),
            textStack.topAnchor.constraint(equalTo: art.bottomAnchor, constant: 8),
            textStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            textStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            placeholderLabel.centerXAnchor.constraint(equalTo: art.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: art.centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: art.leadingAnchor, constant: 18),
            placeholderLabel.trailingAnchor.constraint(equalTo: art.trailingAnchor, constant: -18),
        ])
        isAccessibilityElement = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: HomeMixCardCell, _) in cell.applyDashColor() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        dashed.path = UIBezierPath(
            roundedRect: art.bounds.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 14
        ).cgPath
        dashed.frame = art.bounds
    }

    private func applyDashColor() {
        dashed.strokeColor = UIColor.label.withAlphaComponent(0.3).resolvedColor(with: traitCollection).cgColor
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        art.reset()
        onPlay = nil
    }

    func configure(mix: SuggestedPlaylist, covers: [Album]) {
        showCard()
        titleLabel.text = mix.title
        subtitleLabel.text = mix.subtitle
        art.show(albums: covers, glyph: covers.isEmpty ? mix.systemImage : nil)
        playButton.accessibilityLabel = "\(HomeCopy.play) \(mix.title)"
        contentView.accessibilityLabel = nil
        isAccessibilityElement = false
        accessibilityElements = [contentView, playButton]
        contentView.isAccessibilityElement = true
        contentView.accessibilityLabel = "\(mix.title), \(mix.subtitle)"
        contentView.accessibilityTraits = .button
    }

    func configureRadio() {
        showCard()
        titleLabel.text = HomeCopy.libraryRadio
        subtitleLabel.text = HomeCopy.libraryRadioSubtitle
        art.show(albums: [], glyph: "dot.radiowaves.left.and.right")
        playButton.accessibilityLabel = "\(HomeCopy.play) \(HomeCopy.libraryRadio)"
        accessibilityElements = [contentView, playButton]
        contentView.isAccessibilityElement = true
        contentView.accessibilityLabel = "\(HomeCopy.libraryRadio), \(HomeCopy.libraryRadioSubtitle)"
        contentView.accessibilityTraits = .button
    }

    func configurePlaceholder() {
        art.reset()
        applyDashColor()
        dashed.isHidden = false
        placeholderLabel.isHidden = false
        placeholderLabel.text = HomeCopy.moreMixes
        playButton.isHidden = true
        textStack.isHidden = true
        accessibilityElements = nil
        contentView.isAccessibilityElement = true
        contentView.accessibilityLabel = HomeCopy.moreMixes
        contentView.accessibilityTraits = .staticText
    }

    private func showCard() {
        dashed.isHidden = true
        placeholderLabel.isHidden = true
        playButton.isHidden = false
        textStack.isHidden = false
    }
}
