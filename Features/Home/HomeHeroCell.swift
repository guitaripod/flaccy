import FlaccyCore
import UIKit

enum HomeHeroAction {
    case resume
    case shuffleResume
    case goToContext
    case playFromBeginning
    case playMix
    case playMixNext
    case shuffleMix
    case shuffleLibrary
    case libraryRadio
}

/// Home's lead card. One surface with three faces: Continue (where you left
/// off, with a segmented progress bar), Up next (a mix made for now) and Day
/// one (a library with no history yet).
final class HomeHeroCell: UICollectionViewCell {

    static let reuseID = "HomeHeroCell"
    private static let coverSide: CGFloat = 132
    private static let buttonHeight: CGFloat = 48

    var onAction: ((HomeHeroAction) -> Void)?

    private let glass = LiquidGlass.view(cornerRadius: 28)
    private let art = HomeArtView(cornerRadius: 12, showsShadow: true, placeholderPointSize: 40)
    private let kickerLabel = UILabel()
    private let titleLabel = UILabel()
    private let lineLabel = UILabel()
    private let detailLabel = UILabel()
    private let badge = QualityBadgeView()
    private let startsWithLabel = UILabel()
    private let progress = HomeSegmentedProgressView()
    private let trackLabel = UILabel()
    private let remainingLabel = UILabel()
    private let primaryButton = UIButton(type: .system)
    private let secondaryButton = UIButton(type: .system)
    private let tertiaryButton = UIButton(type: .system)
    private let content = UIStackView()
    private let textColumn = UIStackView()
    private let topRow = UIStackView()
    private let infoRow = UIStackView()
    private let buttonRow = UIStackView()
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private var circleWidths: [ObjectIdentifier: NSLayoutConstraint] = [:]
    private var isNarrow = false

    private static let narrowWidth: CGFloat = 340

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildHierarchy()
        applyBorder()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: HomeHeroCell, _) in cell.applyBorder() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildHierarchy() {
        glass.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(glass)

        kickerLabel.font = .scaled(.footnote, size: 13, weight: .semibold)
        kickerLabel.textColor = .secondaryLabel
        kickerLabel.numberOfLines = 2
        titleLabel.font = .scaled(.title2, size: 26, weight: .heavy, maxSize: 34)
        titleLabel.numberOfLines = 3
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        lineLabel.font = .scaled(.subheadline, size: 15, weight: .regular)
        lineLabel.textColor = .secondaryLabel
        lineLabel.numberOfLines = 2
        detailLabel.font = .scaled(.footnote, size: 13, weight: .regular)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 2
        startsWithLabel.font = .scaled(.footnote, size: 13, weight: .regular)
        startsWithLabel.textColor = .secondaryLabel
        startsWithLabel.numberOfLines = 3
        trackLabel.font = .scaled(.footnote, size: 13, weight: .medium)
        trackLabel.textColor = .secondaryLabel
        remainingLabel.font = .scaled(.footnote, size: 13, weight: .medium)
        remainingLabel.textColor = .secondaryLabel
        remainingLabel.textAlignment = .right
        remainingLabel.setContentHuggingPriority(.required, for: .horizontal)
        remainingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        for label in [kickerLabel, titleLabel, lineLabel, detailLabel, startsWithLabel, trackLabel, remainingLabel] {
            label.adjustsFontForContentSizeCategory = true
        }

        let badgeHolder = UIStackView(arrangedSubviews: [badge, UIView()])
        badgeHolder.axis = .horizontal
        badgeHolder.tag = Self.badgeHolderTag

        textColumn.axis = .vertical
        textColumn.spacing = 4
        textColumn.alignment = .fill
        [kickerLabel, titleLabel, lineLabel, detailLabel, badgeHolder].forEach(textColumn.addArrangedSubview)
        textColumn.setCustomSpacing(8, after: lineLabel)
        textColumn.setCustomSpacing(8, after: detailLabel)

        art.translatesAutoresizingMaskIntoConstraints = false
        let artHolder = UIStackView(arrangedSubviews: [art, UIView()])
        artHolder.axis = .vertical
        NSLayoutConstraint.activate([
            art.widthAnchor.constraint(equalToConstant: Self.coverSide),
            art.heightAnchor.constraint(equalToConstant: Self.coverSide),
        ])

        topRow.axis = .horizontal
        topRow.spacing = 14
        topRow.alignment = .top
        topRow.addArrangedSubview(artHolder)
        topRow.addArrangedSubview(textColumn)

        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.heightAnchor.constraint(equalToConstant: HomeSegmentedProgressView.height).isActive = true

        infoRow.axis = .horizontal
        infoRow.spacing = 8
        infoRow.addArrangedSubview(trackLabel)
        infoRow.addArrangedSubview(remainingLabel)

        buttonRow.axis = .horizontal
        buttonRow.spacing = 10
        buttonRow.alignment = .fill
        [primaryButton, secondaryButton, tertiaryButton].forEach(buttonRow.addArrangedSubview)

        content.axis = .vertical
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(content)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: contentView.topAnchor),
            glass.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            content.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            content.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])
        for button in [primaryButton, secondaryButton, tertiaryButton] {
            button.heightAnchor.constraint(equalToConstant: Self.buttonHeight).isActive = true
        }
        for button in [secondaryButton, tertiaryButton] {
            circleWidths[ObjectIdentifier(button)] = button.widthAnchor.constraint(equalToConstant: Self.buttonHeight)
        }
    }

    private static let badgeHolderTag = 91

    /// In half a wide window the card is too narrow for a cover beside the
    /// words, so the words move under it.
    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let narrow = layoutAttributes.size.width < Self.narrowWidth
        if narrow != isNarrow {
            isNarrow = narrow
            topRow.axis = narrow ? .vertical : .horizontal
            topRow.alignment = narrow ? .leading : .top
        }
        return super.preferredLayoutAttributesFitting(layoutAttributes)
    }

    private func applyBorder() {
        let color = UIColor.label.withAlphaComponent(0.14).resolvedColor(with: traitCollection)
        glass.layer.borderWidth = 1
        glass.layer.borderColor = color.cgColor
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        art.reset()
    }

    func configure(with model: HomeScreenModel, now: Date = Date()) {
        let feed = model.feed
        switch feed.hero {
        case .resume: if let resume = feed.resume { configureResume(resume, now: now) }
        case .upNext: if let upNext = feed.upNext { configureUpNext(upNext, isPlaying: feed.facts.isPlaying) }
        case .dayOne: if let dayOne = feed.dayOne { configureDayOne(dayOne) }
        case .empty: break
        }
    }

    private func setLayout(rows: [UIView]) {
        content.arrangedSubviews.forEach { content.removeArrangedSubview($0); $0.removeFromSuperview() }
        rows.forEach(content.addArrangedSubview)
    }

    private func setBadge(for track: Track?) {
        badge.configure(with: track.flatMap { $0.isHighResolutionMaster ? $0 : nil })
        textColumn.viewWithTag(Self.badgeHolderTag)?.isHidden = badge.isHidden
    }

    private func configureResume(_ resume: HomeFeed.Resume, now: Date) {
        let point = resume.point
        let track = resume.currentTrack
        art.show(albums: resume.album.map { [$0] } ?? [])
        kickerLabel.text = HomeCopy.resumeKicker(ResumeRecency.of(point.savedAt, now: now, calendar: .current))
        let isAlbum = resume.context.kind == .album
        titleLabel.text = isAlbum ? resume.context.title : (resume.context.title.isEmpty ? HomeCopy.yourQueue : resume.context.title)
        lineLabel.text = resume.context.kind == .queue || resume.context.subtitle.isEmpty
            ? HomeCopy.songCount(point.trackCount)
            : resume.context.subtitle
        detailLabel.text = nil
        detailLabel.isHidden = true
        lineLabel.isHidden = false
        setBadge(for: track)
        progress.setSegments(point.segments())
        trackLabel.text = HomeCopy.trackLine(index: point.trackIndex + 1, title: track.title)
        remainingLabel.text = HomeCopy.remaining(point.remainingSeconds)

        configurePrimary(title: HomeCopy.resume, symbol: "play.fill") { [weak self] in self?.send(.resume) }
        configureCircle(secondaryButton, symbol: "shuffle", label: HomeCopy.shuffle, title: nil) { [weak self] in self?.send(.shuffleResume) }
        configureMore(for: resume.context)
        setLayout(rows: [topRow, progress, infoRow, buttonRow])
        accessibilityLabel = nil
    }

    private func configureUpNext(_ upNext: HomeFeed.UpNext, isPlaying: Bool) {
        art.show(albums: upNext.albums)
        kickerLabel.text = HomeCopy.upNextKicker(isPlaying: isPlaying)
        titleLabel.text = upNext.mix.title
        lineLabel.text = upNext.mix.subtitle
        lineLabel.isHidden = upNext.mix.subtitle.isEmpty
        let seconds = upNext.mix.tracks.reduce(0) { $0 + $1.duration }
        detailLabel.text = HomeCopy.mixMeta(count: upNext.mix.tracks.count, seconds: seconds)
        detailLabel.isHidden = false
        setBadge(for: nil)
        startsWithLabel.text = HomeCopy.startsWith(upNext.albums.map(\.title))
        startsWithLabel.isHidden = startsWithLabel.text == nil

        configurePrimary(title: HomeCopy.play, symbol: "play.fill") { [weak self] in self?.send(.playMix) }
        configureCircle(secondaryButton, symbol: "text.line.first.and.arrowtriangle.forward", label: HomeCopy.playNext, title: nil) { [weak self] in self?.send(.playMixNext) }
        configureCircle(tertiaryButton, symbol: "shuffle", label: HomeCopy.shuffle, title: nil) { [weak self] in self?.send(.shuffleMix) }
        tertiaryButton.menu = nil
        setLayout(rows: [topRow, startsWithLabel, buttonRow])
    }

    private func configureDayOne(_ dayOne: HomeFeed.DayOne) {
        art.show(albums: dayOne.coverAlbums)
        kickerLabel.text = HomeCopy.dayOneKicker
        titleLabel.text = HomeCopy.dayOneTitle
        lineLabel.text = HomeCopy.dayOneCounts(songs: dayOne.songs, albums: dayOne.albums)
        lineLabel.isHidden = false
        detailLabel.text = dayOne.hiRes > 0 ? HomeCopy.hiResCount(dayOne.hiRes) : nil
        detailLabel.isHidden = dayOne.hiRes == 0
        setBadge(for: nil)

        configurePrimary(title: HomeCopy.shuffleLibrary, symbol: "shuffle") { [weak self] in self?.send(.shuffleLibrary) }
        configureCircle(secondaryButton, symbol: "dot.radiowaves.left.and.right", label: HomeCopy.libraryRadio, title: HomeCopy.radio) { [weak self] in self?.send(.libraryRadio) }
        tertiaryButton.isHidden = true
        setLayout(rows: [topRow, buttonRow])
    }

    private func send(_ action: HomeHeroAction) {
        impact.impactOccurred()
        onAction?(action)
    }

    private func configurePrimary(title: String, symbol: String, action: @escaping () -> Void) {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePadding = 8
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = .label
        configuration.baseForegroundColor = .systemBackground
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.scaled(.body, size: 17, weight: .semibold, maxSize: 22)
            attributes.foregroundColor = UIColor.systemBackground
            return attributes
        }
        primaryButton.configuration = configuration
        primaryButton.accessibilityLabel = title
        primaryButton.removeTarget(nil, action: nil, for: .allEvents)
        primaryButton.addAction(UIAction { _ in action() }, for: .touchUpInside)
        primaryButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func configureCircle(
        _ button: UIButton, symbol: String, label: String, title: String?, action: @escaping () -> Void
    ) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
        configuration.title = title
        configuration.imagePadding = 6
        configuration.baseForegroundColor = .label
        configuration.contentInsets = title == nil ? .zero : NSDirectionalEdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 18)
        configuration.background.backgroundColor = UIColor.label.withAlphaComponent(0.12)
        configuration.background.cornerRadius = Self.buttonHeight / 2
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        button.configuration = configuration
        button.isHidden = false
        button.accessibilityLabel = label
        button.menu = nil
        button.showsMenuAsPrimaryAction = false
        button.removeTarget(nil, action: nil, for: .allEvents)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        circleWidths[ObjectIdentifier(button)]?.isActive = title == nil
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func configureMore(for context: PlaybackContext) {
        configureCircle(tertiaryButton, symbol: "ellipsis", label: HomeCopy.more, title: nil) {}
        var actions: [UIMenuElement] = []
        switch context.kind {
        case .album:
            actions.append(UIAction(title: HomeCopy.goToAlbum, image: UIImage(systemName: "square.stack")) { [weak self] _ in self?.send(.goToContext) })
        case .playlist:
            actions.append(UIAction(title: HomeCopy.goToPlaylist, image: UIImage(systemName: "music.note.list")) { [weak self] _ in self?.send(.goToContext) })
        default:
            break
        }
        actions.append(UIAction(title: HomeCopy.playFromBeginning, image: UIImage(systemName: "backward.end")) { [weak self] _ in self?.send(.playFromBeginning) })
        tertiaryButton.menu = UIMenu(children: actions)
        tertiaryButton.showsMenuAsPrimaryAction = true
    }
}
