import FlaccyCore
import UIKit

/// The gallery row: every theme as a card that slides sideways, each a
/// drawing of the app in that theme over its name. Tapping one puts it on.
final class ThemeGalleryCell: UITableViewCell, UICollectionViewDataSource, UICollectionViewDelegate {

    static let reuseID = "ThemeGalleryCell"

    private static let cardSize = CGSize(width: 126, height: 196)

    private let collectionView: UICollectionView
    private var looks: [ThemeLook] = []
    private var worn = ""
    private var onPick: ((String) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = ThemeGalleryCell.cardSize
        layout.minimumLineSpacing = 12
        layout.sectionInset = UIEdgeInsets(top: 14, left: 16, bottom: 10, right: 16)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(ThemeCardCell.self, forCellWithReuseIdentifier: ThemeCardCell.reuseID)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.accessibilityIdentifier = "themes.gallery"
        contentView.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: contentView.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            collectionView.heightAnchor.constraint(equalToConstant: ThemeGalleryCell.cardSize.height + 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows every theme as it was last worn, with nothing of the person's
    /// own on it, so a card is the theme and not the theme plus their choices.
    func configure(library: ThemeLibrary, wardrobe: ThemeWardrobe, onPick: @escaping (String) -> Void) {
        looks = library.packs.map { pack in
            let remembered = wardrobe.remembered(pack.id)
            return ThemeLook(
                pack: pack, choice: .init(pack: pack.id, scheme: remembered.scheme, variant: remembered.variant)
            )
        }
        let changed = worn != wardrobe.wornPackID
        worn = wardrobe.wornPackID
        self.onPick = onPick
        collectionView.reloadData()
        guard changed, let index = looks.firstIndex(where: { $0.pack.id == worn }) else { return }
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredHorizontally, animated: false)
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        looks.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ThemeCardCell.reuseID, for: indexPath) as! ThemeCardCell
        let look = looks[indexPath.item]
        cell.configure(look: look, isWorn: look.pack.id == worn)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onPick?(looks[indexPath.item].pack.id)
    }
}

/// One theme in the gallery.
final class ThemeCardCell: UICollectionViewCell {

    static let reuseID = "ThemeCardCell"

    private let preview = ThemePreviewView()
    private let ring = UIView()
    private let nameLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        ring.layer.borderWidth = 2.5
        ring.layer.themedCornerRadius = 16
        ring.layer.cornerCurve = .continuous
        ring.isUserInteractionEnabled = false
        nameLabel.font = .scaled(.footnote, size: 13, weight: .semibold)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textAlignment = .center
        nameLabel.textColor = .flaccyLabel
        for view in [ring, preview, nameLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            preview.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            preview.widthAnchor.constraint(equalTo: contentView.widthAnchor, constant: -10),
            preview.heightAnchor.constraint(
                equalTo: preview.widthAnchor,
                multiplier: ThemePreviewView.designSize.height / ThemePreviewView.designSize.width
            ),
            ring.topAnchor.constraint(equalTo: preview.topAnchor, constant: -4.5),
            ring.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: -4.5),
            ring.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: 4.5),
            ring.bottomAnchor.constraint(equalTo: preview.bottomAnchor, constant: 4.5),
            nameLabel.topAnchor.constraint(equalTo: ring.bottomAnchor, constant: 6),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeEpochTrait.self]) { (cell: ThemeCardCell, _) in
            cell.updateRing()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var isWorn = false

    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateRing()
    }

    private func updateRing() {
        ring.layer.borderColor = (isWorn ? tintColor : UIColor.clear).resolvedColor(with: traitCollection).cgColor
    }

    func configure(look: ThemeLook, isWorn: Bool) {
        self.isWorn = isWorn
        preview.look = look
        nameLabel.text = look.pack.name
        updateRing()
        isAccessibilityElement = true
        accessibilityLabel = look.pack.name
        accessibilityTraits = isWorn ? [.button, .selected] : .button
        accessibilityIdentifier = "themes.card.\(look.pack.id)"
    }
}

/// The colors row: one disc per color scheme of the worn theme.
final class ThemeSwatchesCell: UITableViewCell {

    static let reuseID = "ThemeSwatchesCell"

    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let scroll = UIScrollView()
    private let row = UIStackView()
    private var onPick: ((String) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        titleLabel.text = ThemeCopy.colors
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .flaccyLabel
        valueLabel.font = .preferredFont(forTextStyle: .body)
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.textColor = .flaccySecondaryLabel
        valueLabel.textAlignment = .right
        let heading = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        heading.axis = .horizontal
        row.axis = .horizontal
        row.spacing = 10
        scroll.showsHorizontalScrollIndicator = false
        scroll.addSubview(row)
        let stack = UIStackView(arrangedSubviews: [heading, scroll])
        stack.axis = .vertical
        stack.spacing = 12
        for view in [stack, row] { view.translatesAutoresizingMaskIntoConstraints = false }
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor, constant: 2),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor, constant: -2),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -2),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            scroll.frameLayoutGuide.heightAnchor.constraint(equalTo: row.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(look: ThemeLook, onPick: @escaping (String) -> Void) {
        self.onPick = onPick
        valueLabel.text = ThemeSwatchesCell.name(of: look.wornScheme, in: look.pack)
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for scheme in look.pack.schemes {
            let swatch = ThemeSwatch(color: ThemeSwatchesCell.color(of: scheme, in: look.pack))
            swatch.isChosen = scheme.id == look.wornScheme.id
            swatch.accessibilityLabel = ThemeSwatchesCell.name(of: scheme, in: look.pack)
            swatch.accessibilityIdentifier = "themes.scheme.\(scheme.id)"
            let id = scheme.id
            swatch.addAction(UIAction { [weak self] _ in self?.onPick?(id) }, for: .touchUpInside)
            row.addArrangedSubview(swatch)
        }
    }

    /// A scheme's name. Flaccy's own schemes are the accents, which already
    /// have names in every language.
    private static func name(of scheme: ThemePack.Scheme, in pack: ThemePack) -> String {
        pack.id == ThemeLibrary.defaultID ? AccentChoice(id: scheme.id).displayName : scheme.name
    }

    /// The color a scheme is shown by: its accent in each mode.
    private static func color(of scheme: ThemePack.Scheme, in pack: ThemePack) -> UIColor {
        if pack.id == ThemeLibrary.defaultID { return AccentChoice(id: scheme.id).color }
        let look = ThemeLook(pack: pack, choice: .init(pack: pack.id, scheme: scheme.id))
        let dark = UIColor(ThemeInk(look.palette(dark: true).accent))
        let light = UIColor(ThemeInk(look.palette(dark: false).accent))
        return UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }
}

/// One round swatch: a disc of a scheme's accent, ringed when it is the one on.
final class ThemeSwatch: UIControl {

    private let disc = UIView()
    private let ring = UIView()
    private let color: UIColor

    var isChosen = false {
        didSet {
            ring.isHidden = !isChosen
            accessibilityTraits = isChosen ? [.button, .selected] : .button
        }
    }

    init(color: UIColor) {
        self.color = color
        super.init(frame: .zero)
        disc.backgroundColor = color
        disc.layer.themedCornerRadius = 14
        disc.isUserInteractionEnabled = false
        ring.layer.themedCornerRadius = 19
        ring.layer.borderWidth = 2.5
        ring.isUserInteractionEnabled = false
        ring.isHidden = true
        for view in [ring, disc] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 44),
            heightAnchor.constraint(equalToConstant: 44),
            disc.centerXAnchor.constraint(equalTo: centerXAnchor),
            disc.centerYAnchor.constraint(equalTo: centerYAnchor),
            disc.widthAnchor.constraint(equalToConstant: 28),
            disc.heightAnchor.constraint(equalToConstant: 28),
            ring.centerXAnchor.constraint(equalTo: centerXAnchor),
            ring.centerYAnchor.constraint(equalTo: centerYAnchor),
            ring.widthAnchor.constraint(equalToConstant: 38),
            ring.heightAnchor.constraint(equalToConstant: 38),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        updateRing()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeEpochTrait.self]) { (swatch: ThemeSwatch, _) in
            swatch.updateRing()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func updateRing() {
        ring.layer.borderColor = color.resolvedColor(with: traitCollection).cgColor
    }
}

/// A row that chooses one of a few things from a pop-up menu, the way the
/// system's own settings do.
final class ThemeChoiceCell: UITableViewCell {

    static let reuseID = "ThemeChoiceCell"

    private let button = UIButton(configuration: .plain())

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        button.showsMenuAsPrimaryAction = true
        button.configuration?.image = UIImage(
            systemName: "chevron.up.chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        )
        button.configuration?.imagePlacement = .trailing
        button.configuration?.imagePadding = 5
        button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 0)
        button.configuration?.baseForegroundColor = .flaccySecondaryLabel
        accessoryView = button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `themesValue` is what the theme itself has, shown beside "Theme's
    /// Choice" while that is what is picked.
    func configure(
        title: String, options: [String], selected: Int, themesValue: String?, onPick: @escaping (Int) -> Void
    ) {
        var content = defaultContentConfiguration()
        content.text = title
        content.textProperties.color = .flaccyLabel
        contentConfiguration = content
        let shown = themesValue ?? options[min(selected, options.count - 1)]
        button.configuration?.title = shown
        button.menu = UIMenu(
            children: options.enumerated().map { index, option in
                UIAction(title: option, state: index == selected ? .on : .off) { _ in onPick(index) }
            }
        )
        button.sizeToFit()
        button.accessibilityLabel = title
        button.accessibilityValue = shown
    }
}
