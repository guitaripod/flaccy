import FlaccyCore
import UIKit

extension AlbumDetailViewController {

    func sizeHeaderToFit() {
        for wrapper in [tableView.tableHeaderView, tableView.tableFooterView] {
            guard let wrapper else { continue }
            let size = wrapper.systemLayoutSizeFitting(
                CGSize(width: tableView.bounds.width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            if wrapper.frame.size.height != size.height {
                wrapper.frame.size.height = size.height
                if wrapper === tableView.tableHeaderView {
                    tableView.tableHeaderView = wrapper
                } else {
                    tableView.tableFooterView = wrapper
                }
            }
        }
    }

    /// Builds the three header pieces once; `applyHeaderStyle()` decides where
    /// they live (above the rows, as a banner, or as a column beside them).
    func buildHeaderComponents() {
        setupArtworkCard()

        titleMarquee.text = album.title
        titleMarquee.font = .scaled(.title2, size: 24, weight: .bold)
        titleMarquee.textColor = .white

        let artistButton = UIButton(type: .system)
        artistButton.setTitle(album.artist, for: .normal)
        artistButton.titleLabel?.font = .scaled(.callout, size: 16, weight: .semibold)
        artistButton.titleLabel?.adjustsFontForContentSizeCategory = true
        artistButton.setTitleColor(.white.withAlphaComponent(0.85), for: .normal)
        artistButton.contentHorizontalAlignment = .leading
        artistButton.accessibilityHint = String(localized: "Shows the artist's albums")
        artistButton.addAction(UIAction { [weak self] _ in self?.artistTapped() }, for: .touchUpInside)

        metaLabel.font = .scaled(.footnote, size: 13, weight: .regular)
        metaLabel.adjustsFontForContentSizeCategory = true
        metaLabel.textColor = .white.withAlphaComponent(0.55)
        renderMetaLine(year: album.year, genre: album.genre)

        playCountLabel.font = .scaled(.footnote, size: 13, weight: .semibold)
        playCountLabel.adjustsFontForContentSizeCategory = true
        playCountLabel.textColor = accentColor
        playCountLabel.numberOfLines = 0
        playCountLabel.isHidden = true

        genreChipsHolder.isHidden = true

        let qualityBadgeRow = buildQualityBadgeRow()

        infoStack.addArrangedSubview(titleMarquee)
        infoStack.addArrangedSubview(artistButton)
        infoStack.addArrangedSubview(metaLabel)
        infoStack.addArrangedSubview(playCountLabel)
        infoStack.axis = .vertical
        infoStack.spacing = 2
        infoStack.alignment = .leading
        if let qualityBadgeRow {
            infoStack.addArrangedSubview(qualityBadgeRow)
            infoStack.setCustomSpacing(10, after: metaLabel)
        }
        infoStack.addArrangedSubview(genreChipsHolder)
        infoStack.setCustomSpacing(10, after: qualityBadgeRow ?? metaLabel)
        genreChipsHolder.widthAnchor.constraint(equalTo: infoStack.widthAnchor).isActive = true
        titleMarquee.widthAnchor.constraint(equalTo: infoStack.widthAnchor).isActive = true

        actionRow = buildActionRow()
        appearanceElements = [artworkCard, infoStack, actionRow]
    }

    /// Arranges the header for the room this page was given. Stacked is the
    /// phone column; the banner puts a modest cover beside the title so rows
    /// start high on a wider page; side by side pins the cover and details in
    /// a column and gives the whole other half to the tracks.
    func applyHeaderStyle() {
        let usable = view.safeAreaLayoutGuide.layoutFrame.size
        guard usable.width > 1 else { return }
        let style = AdaptiveLayout.detailHeaderStyle(forSize: usable)
        guard style != appliedHeaderStyle else { return }
        appliedHeaderStyle = style
        NSLayoutConstraint.deactivate(headerLayoutConstraints)
        headerLayoutConstraints = []
        headerColumn.removeFromSuperview()
        tableView.tableHeaderView = nil
        for piece in [artworkCard, infoStack, actionRow] { piece.removeFromSuperview() }

        switch style {
        case .stacked: installStackedHeader()
        case .banner: installBannerHeader()
        case .sideBySide: installColumnHeader()
        }
        tableLeading.isActive = style != .sideBySide
        tableColumnLeading.isActive = style == .sideBySide
        view.setNeedsLayout()
    }

    func installStackedHeader() {
        let container = UIView()
        let mainStack = UIStackView(arrangedSubviews: [artworkCard, infoStack, actionRow])
        mainStack.axis = .vertical
        mainStack.spacing = 18
        mainStack.setCustomSpacing(22, after: artworkCard)
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(mainStack)
        let guide = container.safeAreaLayoutGuide
        let leading = mainStack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24)
        let trailing = mainStack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24)
        let bottom = mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20)
        for constraint in [leading, trailing, bottom] { constraint.priority = .defaultHigh }
        let cardWidth = artworkCard.widthAnchor.constraint(equalTo: mainStack.widthAnchor, multiplier: 0.8)
        cardWidth.priority = .defaultHigh
        let cardCap = artworkCard.widthAnchor.constraint(lessThanOrEqualToConstant: 340)
        let constraints = [
            mainStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            artworkCard.centerXAnchor.constraint(equalTo: mainStack.centerXAnchor),
            leading, trailing, bottom, cardWidth, cardCap,
        ]
        NSLayoutConstraint.activate(constraints)
        headerLayoutConstraints = constraints
        tableView.tableHeaderView = container
    }

    func installBannerHeader() {
        let container = UIView()
        let artworkSide = min(max(view.safeAreaLayoutGuide.layoutFrame.width * 0.36, 120), 260)
        let topRow = UIStackView(arrangedSubviews: [artworkCard, infoStack])
        topRow.axis = .horizontal
        topRow.spacing = 18
        topRow.alignment = .center
        let mainStack = UIStackView(arrangedSubviews: [topRow, actionRow])
        mainStack.axis = .vertical
        mainStack.spacing = 16
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(mainStack)
        let guide = container.safeAreaLayoutGuide
        let leading = mainStack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24)
        let trailing = mainStack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24)
        let bottom = mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        for constraint in [leading, trailing, bottom] { constraint.priority = .defaultHigh }
        let constraints = [
            mainStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            artworkCard.widthAnchor.constraint(equalToConstant: artworkSide),
            leading, trailing, bottom,
        ]
        NSLayoutConstraint.activate(constraints)
        headerLayoutConstraints = constraints
        tableView.tableHeaderView = container
    }

    func installColumnHeader() {
        let usable = view.safeAreaLayoutGuide.layoutFrame.size
        let artworkSide = min(max(usable.width * 0.4, 240) - 40, usable.height * 0.42, 340)
        let columnWidth = max(artworkSide + 40, 280)
        headerColumn.translatesAutoresizingMaskIntoConstraints = false
        headerColumn.showsVerticalScrollIndicator = false
        headerColumn.alwaysBounceVertical = false
        headerColumn.contentInsetAdjustmentBehavior = .always
        view.addSubview(headerColumn)
        let mainStack = UIStackView(arrangedSubviews: [artworkCard, infoStack, actionRow])
        mainStack.axis = .vertical
        mainStack.spacing = 16
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        headerColumn.addSubview(mainStack)
        let guide = view.safeAreaLayoutGuide
        let constraints = [
            headerColumn.topAnchor.constraint(equalTo: view.topAnchor),
            headerColumn.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            headerColumn.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            headerColumn.widthAnchor.constraint(equalToConstant: columnWidth),
            mainStack.topAnchor.constraint(equalTo: headerColumn.contentLayoutGuide.topAnchor, constant: 12),
            mainStack.bottomAnchor.constraint(equalTo: headerColumn.contentLayoutGuide.bottomAnchor, constant: -24),
            mainStack.leadingAnchor.constraint(equalTo: headerColumn.frameLayoutGuide.leadingAnchor, constant: 24),
            mainStack.trailingAnchor.constraint(equalTo: headerColumn.frameLayoutGuide.trailingAnchor, constant: -16),
            artworkCard.widthAnchor.constraint(equalToConstant: artworkSide),
        ]
        constraints.last?.priority = .defaultHigh
        NSLayoutConstraint.activate(constraints)
        headerLayoutConstraints = constraints
    }

    func setupArtworkCard() {
        artworkCard.layer.shadowColor = UIColor.black.cgColor
        artworkCard.layer.shadowOpacity = 0.45
        artworkCard.layer.shadowOffset = CGSize(width: 0, height: 12)
        artworkCard.layer.shadowRadius = 28
        addMotionParallax(to: artworkCard)

        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.layer.cornerRadius = 16
        artworkView.layer.cornerCurve = .continuous
        artworkView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        artworkView.tintColor = UIColor.white.withAlphaComponent(0.35)
        artworkView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 56, weight: .ultraLight)
        artworkView.isAccessibilityElement = true
        artworkView.accessibilityLabel = String(localized: "Album artwork for \(album.title)")
        artworkView.isUserInteractionEnabled = true
        artworkView.addInteraction(UIContextMenuInteraction(delegate: self))
        artworkView.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "Edit Artwork")) { [weak self] _ in
                self?.presentArtworkEditor()
                return true
            },
        ]

        if let artwork = resolvedArtwork() {
            artworkView.image = artwork
        } else {
            artworkView.contentMode = .center
            artworkView.image = UIImage(systemName: "music.note")
            AlbumArtworkCache.shared.loadArtwork(forAlbum: album.title, artist: album.artist) { [weak self] image in
                guard let self, let image else { return }
                self.artworkView.contentMode = .scaleAspectFill
                self.artworkView.image = image
                self.applyPalette(from: image, animated: true)
            }
        }

        artworkView.translatesAutoresizingMaskIntoConstraints = false
        for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
            artworkView.setContentCompressionResistancePriority(.defaultLow, for: axis)
            artworkView.setContentHuggingPriority(.defaultLow, for: axis)
        }
        artworkCard.addSubview(artworkView)
        NSLayoutConstraint.activate([
            artworkView.topAnchor.constraint(equalTo: artworkCard.topAnchor),
            artworkView.leadingAnchor.constraint(equalTo: artworkCard.leadingAnchor),
            artworkView.trailingAnchor.constraint(equalTo: artworkCard.trailingAnchor),
            artworkView.bottomAnchor.constraint(equalTo: artworkCard.bottomAnchor),
            artworkView.heightAnchor.constraint(equalTo: artworkView.widthAnchor),
        ])
    }

    /// Device-tilt parallax matching the Now Playing artwork card; skipped
    /// under Reduce Motion.
    func addMotionParallax(to card: UIView) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let horizontal = UIInterpolatingMotionEffect(keyPath: "center.x", type: .tiltAlongHorizontalAxis)
        horizontal.minimumRelativeValue = -14
        horizontal.maximumRelativeValue = 14
        let vertical = UIInterpolatingMotionEffect(keyPath: "center.y", type: .tiltAlongVerticalAxis)
        vertical.minimumRelativeValue = -10
        vertical.maximumRelativeValue = 10
        let group = UIMotionEffectGroup()
        group.motionEffects = [horizontal, vertical]
        card.addMotionEffect(group)
    }

    /// A left-aligned glass pill summarizing the album's peak audio quality,
    /// or nil when no track carries codec/quality metadata.
    func buildQualityBadgeRow() -> UIView? {
        guard let summary = DetailChip.albumQualitySummary(tracks: album.tracks) else { return nil }
        let pill = DetailChip.pill(text: summary, systemImage: "waveform", accessibilityPrefix: String(localized: "Audio quality"))
        let row = UIStackView(arrangedSubviews: [pill, UIView()])
        row.axis = .horizontal
        row.alignment = .center
        return row
    }

    func buildActionRow() -> UIView {
        let play = LiquidGlass.actionCapsule(title: String(localized: "Play"), systemImage: "play.fill") { [weak self] in
            self?.playTapped()
        }
        let shuffle = LiquidGlass.actionCapsule(title: String(localized: "Shuffle"), systemImage: "shuffle") { [weak self] in
            self?.shuffleTapped()
        }
        let queue = LiquidGlass.iconCapsule(systemImage: "text.append", accessibilityLabel: String(localized: "Add album to queue"), width: 44) { [weak self] in
            self?.addAlbumToQueue()
        }
        let share = LiquidGlass.iconCapsule(systemImage: "square.and.arrow.up", accessibilityLabel: String(localized: "Share album"), width: 44) { [weak self] in
            guard let self else { return }
            self.shareAlbumViaSonglink(title: self.album.title, artist: self.album.artist, from: self.view)
        }
        let row = UIStackView(arrangedSubviews: [play, shuffle, queue, share])
        row.spacing = 8
        play.widthAnchor.constraint(equalTo: shuffle.widthAnchor).isActive = true
        return LiquidGlass.grouping(row)
    }

    func buildFooterView() -> UIView {
        let container = UIView()
        let label = UILabel()
        label.font = .scaled(.footnote, size: 13, weight: .regular)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white.withAlphaComponent(0.45)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.text = footerText()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -32),
        ])
        let trailing = label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24)
        trailing.priority = .defaultHigh
        trailing.isActive = true
        return container
    }

    func footerText() -> String {
        let count = album.tracks.count
        let totalSeconds = album.tracks.reduce(0) { $0 + Int($1.duration) }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let duration = hours > 0
            ? String(localized: "\(hours) hr \(minutes) min")
            : String(localized: "\(minutes) min")
        return String(localized: "\(count) tracks \u{00B7} \(duration)")
    }
}
