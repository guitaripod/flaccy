import AVFoundation
import MidgarCore
import AVKit
import Combine
import UIKit

extension NowPlayingViewController {

    /// Hosts the three exclusive center states: the artwork column (default),
    /// and the lyrics/queue child content shown below a compact now-playing
    /// header that morphs in when the artwork collapses.
    func setupCenterContainer(infoStack: UIStackView) {
        centerContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(centerContainer)

        artworkGroup.axis = .vertical
        artworkGroup.spacing = 26
        artworkGroup.addArrangedSubview(makeArtworkRow())
        artworkGroup.addArrangedSubview(infoStack)
        artworkGroup.translatesAutoresizingMaskIntoConstraints = false
        centerContainer.addSubview(artworkGroup)

        setupCompactHeader()
        centerContainer.addSubview(compactHeader)

        stateContentContainer.alpha = 0
        stateContentContainer.isUserInteractionEnabled = false
        stateContentContainer.translatesAutoresizingMaskIntoConstraints = false
        centerContainer.addSubview(stateContentContainer)

        NSLayoutConstraint.activate([
            artworkGroup.topAnchor.constraint(equalTo: centerContainer.topAnchor),
            artworkGroup.leadingAnchor.constraint(equalTo: centerContainer.leadingAnchor),
            artworkGroup.bottomAnchor.constraint(lessThanOrEqualTo: centerContainer.bottomAnchor),
            compactHeader.topAnchor.constraint(equalTo: centerContainer.topAnchor),
            compactHeader.leadingAnchor.constraint(equalTo: centerContainer.leadingAnchor),
            compactHeader.trailingAnchor.constraint(equalTo: centerContainer.trailingAnchor),
        ])
        artworkGroupTrailing = artworkGroup.trailingAnchor.constraint(equalTo: centerContainer.trailingAnchor)
        artworkGroupTrailing.isActive = true
    }

    func setupCompactHeader() {
        compactHeader.alpha = 0
        compactHeader.isUserInteractionEnabled = false
        compactHeader.translatesAutoresizingMaskIntoConstraints = false
        compactHeader.accessibilityHint = String(localized: "Returns to the artwork")
        compactHeader.accessibilityTraits = .button
        compactHeader.addAction(UIAction { [weak self] _ in
            self?.setCenterState(.artwork)
        }, for: .touchUpInside)

        compactArtworkView.contentMode = .scaleAspectFill
        compactArtworkView.clipsToBounds = true
        compactArtworkView.layer.cornerRadius = 10
        compactArtworkView.layer.cornerCurve = .continuous
        compactArtworkView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        compactArtworkView.tintColor = UIColor.white.withAlphaComponent(0.35)
        compactArtworkView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .light)
        compactArtworkView.isUserInteractionEnabled = false

        compactTitleLabel.font = .scaled(.subheadline, size: 15, weight: .semibold)
        compactTitleLabel.adjustsFontForContentSizeCategory = true
        compactTitleLabel.textColor = .white
        compactTitleLabel.lineBreakMode = .byTruncatingTail

        compactArtistLabel.font = .scaled(.caption1, size: 13, weight: .regular)
        compactArtistLabel.adjustsFontForContentSizeCategory = true
        compactArtistLabel.textColor = .white.withAlphaComponent(0.6)
        compactArtistLabel.lineBreakMode = .byTruncatingTail

        let textStack = UIStackView(arrangedSubviews: [compactTitleLabel, compactArtistLabel])
        textStack.axis = .vertical
        textStack.spacing = 1
        textStack.isUserInteractionEnabled = false

        let chevron = UIImageView(image: UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        ))
        chevron.tintColor = .white.withAlphaComponent(0.45)
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [compactArtworkView, textStack, chevron])
        row.spacing = 12
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        compactHeader.addSubview(row)

        NSLayoutConstraint.activate([
            compactArtworkView.widthAnchor.constraint(equalToConstant: 44),
            compactArtworkView.heightAnchor.constraint(equalToConstant: 44),
            compactHeader.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            row.topAnchor.constraint(equalTo: compactHeader.topAnchor, constant: 4),
            row.leadingAnchor.constraint(equalTo: compactHeader.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: compactHeader.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: compactHeader.bottomAnchor, constant: -4),
        ])
    }


    /// Device-motion parallax: the artwork card drifts opposite the device tilt
    /// so it reads as floating above the backdrop. Skipped under Reduce Motion.
    func addMotionParallax() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let horizontal = UIInterpolatingMotionEffect(keyPath: "center.x", type: .tiltAlongHorizontalAxis)
        horizontal.minimumRelativeValue = -18
        horizontal.maximumRelativeValue = 18
        let vertical = UIInterpolatingMotionEffect(keyPath: "center.y", type: .tiltAlongVerticalAxis)
        vertical.minimumRelativeValue = -12
        vertical.maximumRelativeValue = 12
        let group = UIMotionEffectGroup()
        group.motionEffects = [horizontal, vertical]
        artworkContainer.addMotionEffect(group)
    }

    /// Wraps the artwork card in a full-width row that is always a centered
    /// square. Size is driven only by the row width / max-height cap — never by
    /// the image's intrinsic aspect ratio — so tall covers can't shove transport.
    func makeArtworkRow() -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        artworkContainer.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(artworkContainer)

        let preferredWidth = artworkContainer.widthAnchor.constraint(equalTo: row.widthAnchor)
        preferredWidth.priority = UILayoutPriority(999)

        NSLayoutConstraint.activate([
            artworkContainer.topAnchor.constraint(equalTo: row.topAnchor),
            artworkContainer.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            artworkContainer.centerXAnchor.constraint(equalTo: row.centerXAnchor),
            artworkContainer.widthAnchor.constraint(equalTo: artworkContainer.heightAnchor),
            artworkContainer.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor),
            preferredWidth,
        ])
        return row
    }

    func setupArtwork() {
        addMotionParallax()
        artworkContainer.layer.shadowColor = UIColor.black.cgColor
        artworkContainer.layer.shadowOpacity = 0.45
        artworkContainer.layer.shadowOffset = CGSize(width: 0, height: 14)
        artworkContainer.layer.shadowRadius = 34

        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.layer.cornerRadius = 20
        artworkView.layer.cornerCurve = .continuous
        artworkView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        artworkView.image = UIImage(systemName: "music.note")
        artworkView.tintColor = UIColor.white.withAlphaComponent(0.35)
        artworkView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 48, weight: .ultraLight)
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        // Image pixel size must not participate in layout — otherwise non-square
        // covers grow the card and bounce the controls on every track change.
        for axis: NSLayoutConstraint.Axis in [.horizontal, .vertical] {
            artworkView.setContentHuggingPriority(.fittingSizeLevel, for: axis)
            artworkView.setContentCompressionResistancePriority(.fittingSizeLevel, for: axis)
        }
        artworkContainer.addSubview(artworkView)
        artworkContainer.isAccessibilityElement = true
        artworkContainer.accessibilityLabel = String(localized: "Album artwork")
        artworkContainer.accessibilityHint = String(localized: "Swipe left or right with two fingers to change track")
        artworkContainer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        NSLayoutConstraint.activate([
            artworkView.topAnchor.constraint(equalTo: artworkContainer.topAnchor),
            artworkView.leadingAnchor.constraint(equalTo: artworkContainer.leadingAnchor),
            artworkView.trailingAnchor.constraint(equalTo: artworkContainer.trailingAnchor),
            artworkView.bottomAnchor.constraint(equalTo: artworkContainer.bottomAnchor),
        ])

        setupPeekArtwork()

        artworkContainer.isUserInteractionEnabled = true
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleTrackPan(_:)))
        pan.delegate = self
        pan.delaysTouchesEnded = false
        artworkContainer.addGestureRecognizer(pan)

        let tilt = UILongPressGestureRecognizer(target: self, action: #selector(handleTilt(_:)))
        tilt.minimumPressDuration = 0.18
        artworkContainer.addGestureRecognizer(tilt)

        artworkContainer.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    func setupPeekArtwork() {
        peekArtworkView.contentMode = .scaleAspectFill
        peekArtworkView.clipsToBounds = true
        peekArtworkView.layer.cornerRadius = 20
        peekArtworkView.layer.cornerCurve = .continuous
        peekArtworkView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        peekArtworkView.tintColor = UIColor.white.withAlphaComponent(0.35)
        peekArtworkView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 48, weight: .ultraLight)
        peekArtworkView.isHidden = true
        peekArtworkView.isUserInteractionEnabled = false
        peekArtworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkContainer.addSubview(peekArtworkView)
        NSLayoutConstraint.activate([
            peekArtworkView.topAnchor.constraint(equalTo: artworkView.topAnchor),
            peekArtworkView.leadingAnchor.constraint(equalTo: artworkView.leadingAnchor),
            peekArtworkView.trailingAnchor.constraint(equalTo: artworkView.trailingAnchor),
            peekArtworkView.bottomAnchor.constraint(equalTo: artworkView.bottomAnchor),
        ])
    }

    func setupInfoBlock() {
        titleMarquee.font = .scaled(.title3, size: 21, weight: .bold)
        titleMarquee.textColor = .white
        titleMarquee.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleMarquee.addInteraction(UIContextMenuInteraction(delegate: self))
        titleMarquee.isUserInteractionEnabled = true
        titleMarquee.accessibilityTraits = .button
        titleMarquee.accessibilityHint = String(localized: "Shows the album")
        titleMarquee.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(albumNavigationTapped))
        )

        artistAvatarButton.contentMode = .scaleAspectFill
        artistAvatarButton.imageView?.contentMode = .scaleAspectFill
        artistAvatarButton.clipsToBounds = true
        artistAvatarButton.layer.cornerRadius = 11
        artistAvatarButton.isHidden = true
        artistAvatarButton.accessibilityLabel = String(localized: "Artist photo")
        artistAvatarButton.accessibilityHint = String(localized: "Shows the artist's albums")
        artistAvatarButton.addAction(UIAction { [weak self] _ in self?.navigateToArtist() }, for: .touchUpInside)
        NSLayoutConstraint.activate([
            artistAvatarButton.widthAnchor.constraint(equalToConstant: 22),
            artistAvatarButton.heightAnchor.constraint(equalToConstant: 22),
        ])

        artistButton.titleLabel?.font = .scaled(.callout, size: 16, weight: .semibold)
        artistButton.titleLabel?.adjustsFontForContentSizeCategory = true
        artistButton.setTitleColor(.white.withAlphaComponent(0.85), for: .normal)
        artistButton.contentHorizontalAlignment = .leading
        artistButton.setContentHuggingPriority(.required, for: .horizontal)
        artistButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        artistButton.accessibilityHint = String(localized: "Shows the artist's albums")
        artistButton.addAction(UIAction { [weak self] _ in self?.navigateToArtist() }, for: .touchUpInside)

        dashLabel.text = " — "
        dashLabel.font = .scaled(.callout, size: 16, weight: .regular)
        dashLabel.adjustsFontForContentSizeCategory = true
        dashLabel.textColor = .white.withAlphaComponent(0.55)
        dashLabel.setContentHuggingPriority(.required, for: .horizontal)
        dashLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        albumLabel.font = .scaled(.callout, size: 16, weight: .regular)
        albumLabel.adjustsFontForContentSizeCategory = true
        albumLabel.textColor = .white.withAlphaComponent(0.55)
        albumLabel.lineBreakMode = .byTruncatingTail
        albumLabel.addInteraction(UIContextMenuInteraction(delegate: self))
        albumLabel.isUserInteractionEnabled = true
        albumLabel.isAccessibilityElement = true
        albumLabel.accessibilityTraits = .button
        albumLabel.accessibilityHint = String(localized: "Shows the album")
        albumLabel.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(albumNavigationTapped))
        )

        playingFromLabel.font = .scaled(.caption1, size: 12, weight: .regular)
        playingFromLabel.adjustsFontForContentSizeCategory = true
        playingFromLabel.textColor = .white.withAlphaComponent(0.4)
        playingFromLabel.isHidden = true
        playingFromLabel.isUserInteractionEnabled = true
        playingFromLabel.accessibilityTraits = .button
        playingFromLabel.accessibilityHint = String(localized: "Shows the album")
        playingFromLabel.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(albumNavigationTapped))
        )
    }

    @objc func albumNavigationTapped() {
        navigateToAlbum()
    }

    /// The song title paired with its quality signature and the love toggle:
    /// title claims the width, the badge and heart hug the trailing edge.
    func makeTitleRow() -> UIStackView {
        loveButton.onToggle = { [weak self] in self?.toggleLove() }

        let row = UIStackView(arrangedSubviews: [titleMarquee, qualityBadge, equalizerBadge, loveButton])
        row.spacing = 8
        row.alignment = .center
        return row
    }

    func toggleLove() {
        guard let track = AudioPlayer.shared.currentTrack else { return }
        let newValue = !LovedTracksService.shared.isLoved(track: track)
        loveButton.setLoved(newValue, animated: true)
        Task { await LovedTracksService.shared.toggleLove(track: track) }
    }

    func refreshTrackSignals() {
        let track = AudioPlayer.shared.currentTrack
        qualityBadge.configure(with: track)
        versionRow.configure(with: track)
        loveButton.isEnabled = track != nil
        let loved = track.map { LovedTracksService.shared.isLoved(track: $0) } ?? false
        loveButton.setLoved(loved, animated: false)
    }

    /// Re-reads the playing song's versions when the library reports a new
    /// mix, so the chip and the export time appear without a track change.
    @objc func tracksRevised() {
        versionRow.configure(with: AudioPlayer.shared.currentTrack)
    }

    @objc func lovedTracksDidChange() {
        let track = AudioPlayer.shared.currentTrack
        let loved = track.map { LovedTracksService.shared.isLoved(track: $0) } ?? false
        loveButton.setLoved(loved, animated: false)
    }

    func makeArtistAlbumRow() -> UIStackView {
        let row = UIStackView(arrangedSubviews: [artistAvatarButton, artistButton, dashLabel, albumLabel])
        row.spacing = 0
        row.setCustomSpacing(7, after: artistAvatarButton)
        row.alignment = .center
        return row
    }

    func setupScrubber() {
        scrubber.onScrubBegan = { [weak self] in self?.scrubBegan() }
        scrubber.onScrubChanged = { [weak self] time in self?.scrubChanged(to: time) }
        scrubber.onScrubEnded = { [weak self] time in self?.scrubEnded(at: time) }
        scrubber.onAccessibilityAdjust = { [weak self] time in
            self?.chaseTime = time
            self?.seekToChaseTime()
        }

        let timeFont = UIFontMetrics(forTextStyle: .caption2)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 11, weight: .medium), maximumPointSize: 18)
        for label in [currentTimeLabel, remainingTimeLabel] {
            label.font = timeFont
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .white.withAlphaComponent(0.5)
        }
        currentTimeLabel.text = "0:00"
        remainingTimeLabel.text = "-0:00"
        remainingTimeLabel.textAlignment = .right
    }

    func makeTimeRow() -> UIStackView {
        UIStackView(arrangedSubviews: [currentTimeLabel, UIView(), remainingTimeLabel])
    }

    func setupScrubBubble() {
        scrubBubble.backgroundColor = UIColor.white.withAlphaComponent(0.95)
        scrubBubble.layer.cornerRadius = 12
        scrubBubble.layer.cornerCurve = .continuous
        scrubBubble.alpha = 0
        scrubBubbleLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        scrubBubbleLabel.textColor = .black
        scrubBubbleLabel.textAlignment = .center
        scrubBubble.addSubview(scrubBubbleLabel)
        view.addSubview(scrubBubble)
    }
}
