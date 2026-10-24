import AVFoundation
import MidgarCore
import AVKit
import Combine
import UIKit

extension NowPlayingViewController {

    func bindViewModel() {
        viewModel.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.applyState(state) }
            .store(in: &cancellables)
        viewModel.progressPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in self?.applyProgress(progress) }
            .store(in: &cancellables)
    }

    func applyProgress(_ progress: NowPlayingViewModel.Progress) {
        recoverFromStaleScrubIfNeeded()
        scrubber.setProgress(currentTime: progress.currentTime, duration: progress.duration)
        if !scrubber.isScrubbing {
            scrubber.accessibilityValue = progress.currentTimeFormatted
            currentTimeLabel.text = progress.currentTimeFormatted
            remainingTimeLabel.text = progress.remainingTimeFormatted
        }
    }

    func applyState(_ state: NowPlayingViewModel.State) {
        let trackKey = "\(state.title)\0\(state.artist)\0\(state.albumTitle)"
        if trackKey != lastTrackKey {
            lastTrackKey = trackKey
            invalidateScrubForTrackChange()
            applyTrackMetadata(state)
        } else if let artwork = state.artwork, artwork !== lastAppliedArtwork {
            setArtwork(artwork)
            updateBackdropPalette(artwork: artwork, state: state)
        }
        if state.isPlaying != lastIsPlaying {
            lastIsPlaying = state.isPlaying
            applyPlaybackState(isPlaying: state.isPlaying)
        }
        recoverFromStaleScrubIfNeeded()
        scrubber.setProgress(currentTime: state.currentTime, duration: state.duration)
        if !scrubber.isScrubbing {
            scrubber.accessibilityValue = state.currentTimeFormatted
            currentTimeLabel.text = state.currentTimeFormatted
            remainingTimeLabel.text = state.remainingTimeFormatted
        }
    }

    /// Watchdog for a scrub whose touch died without the slider ever hearing
    /// about it (endTracking swallowed by an ancestor recognizer): once the
    /// control reports it is no longer tracking a touch but the scrub state is
    /// still latched, the scrub is force-ended two progress ticks in a row
    /// later, seeking to the grabbed position and releasing the UI.
    func recoverFromStaleScrubIfNeeded() {
        guard scrubber.isScrubbing, !scrubber.isTracking else {
            staleScrubTicks = 0
            return
        }
        staleScrubTicks += 1
        guard staleScrubTicks >= 2 else { return }
        staleScrubTicks = 0
        MidgarLog.notice("Recovering stale scrub via progress watchdog", category: .ui)
        scrubber.abortScrub()
        scrubEnded(at: scrubber.currentTime)
    }

    /// A track change makes any in-flight scrub or chase seek meaningless —
    /// its target was computed against the old item's timeline — so the scrub
    /// is aborted without seeking and pending chase completions are orphaned.
    func invalidateScrubForTrackChange() {
        seekGeneration += 1
        chaseTime = 0
        guard scrubber.isScrubbing || scrubBubble.alpha > 0 else { return }
        scrubber.abortScrub()
        UIView.animate(withDuration: 0.12) { self.scrubBubble.alpha = 0 }
        if presentedViewController == nil, view.window != nil {
            backdropView.setPaused(false)
        }
    }

    func applyTrackMetadata(_ state: NowPlayingViewModel.State) {
        titleMarquee.text = state.title
        artistButton.setTitle(state.artist, for: .normal)
        albumLabel.text = state.albumTitle
        compactTitleLabel.text = state.title
        compactArtistLabel.text = state.artist
        compactHeader.accessibilityLabel = String(localized: "Now playing: \(state.title), \(state.artist)")

        let hasArtist = !state.artist.isEmpty
        let hasAlbum = !state.albumTitle.isEmpty
        dashLabel.isHidden = !(hasArtist && hasAlbum)
        playingFromLabel.text = hasAlbum ? String(localized: "Playing from \(state.albumTitle)") : ""
        playingFromLabel.isHidden = !hasAlbum

        refreshTrackSignals()
        setArtwork(state.artwork)
        updateBackdropPalette(artwork: state.artwork, state: state)
        updateArtistImage(artist: state.artist)
        let track = AudioPlayer.shared.currentTrack
        LyricsService.shared.prefetch(
            track: state.title, artist: state.artist, album: state.albumTitle,
            fileURL: track?.title == state.title ? track?.fileURL : nil,
            duration: track?.duration ?? 0
        )
    }

    /// Resolves the artist photo off-main and applies it to the ambient
    /// backdrop layer and avatar, skipping redundant fetches for the same artist.
    func updateArtistImage(artist: String) {
        let key = artist.lowercased()
        guard key != currentArtistKey else { return }
        currentArtistKey = key
        artistImageTask?.cancel()

        guard !artist.isEmpty else {
            applyArtistImage(nil)
            return
        }
        artistImageTask = Task { [weak self] in
            let image = await ArtistImageService.shared.image(for: artist)
            guard !Task.isCancelled, let self, self.currentArtistKey == key else { return }
            self.applyArtistImage(image)
        }
    }

    func applyArtistImage(_ image: UIImage?) {
        backdropView.setArtistImage(image, animated: hasAppliedInitialState)
        let showAvatar = image != nil
        artistAvatarButton.setImage(image, for: .normal)
        guard artistAvatarButton.isHidden == showAvatar else { return }
        let update = { self.artistAvatarButton.isHidden = !showAvatar }
        if hasAppliedInitialState, hasAnimatedAppearance, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.2, animations: update)
        } else {
            update()
        }
    }

    func setArtwork(_ image: UIImage?) {
        lastAppliedArtwork = image
        applyCompactArtwork(image)
        if isInteractiveTrackTransitionActive {
            deferredArtwork = .some(image)
            return
        }
        if hasAppliedInitialState, !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(
                with: artworkView, duration: 0.22,
                options: [.transitionCrossDissolve, .allowUserInteraction]
            ) { self.applyArtworkDirect(image) }
        } else {
            applyArtworkDirect(image)
        }
    }

    func applyCompactArtwork(_ image: UIImage?) {
        if let image {
            compactArtworkView.contentMode = .scaleAspectFill
            compactArtworkView.image = image
        } else {
            compactArtworkView.contentMode = .center
            compactArtworkView.image = UIImage(systemName: "music.note")
        }
    }

    func applyArtworkDirect(_ image: UIImage?) {
        if let image {
            artworkView.contentMode = .scaleAspectFill
            artworkView.image = image
        } else {
            artworkView.contentMode = .center
            artworkView.image = UIImage(systemName: "music.note")
        }
    }

    func updateBackdropPalette(artwork: UIImage?, state: NowPlayingViewModel.State) {
        let cacheKey = "\(state.albumTitle)\0\(state.artist)"
        let seed = state.title.isEmpty ? "flaccy" : "\(state.title)\(state.artist)"
        let animated = hasAppliedInitialState
        ArtworkPaletteExtractor.palette(for: artwork, cacheKey: cacheKey, fallbackSeed: seed) { [weak self] palette in
            self?.backdropView.apply(palette, animated: animated)
            self?.equalizerBadge.accent = EqualizerTheme.accent(from: palette)
        }
    }

    func applyPlaybackState(isPlaying: Bool) {
        let iconName = isPlaying ? "pause.fill" : "play.fill"
        let image = UIImage(systemName: iconName, withConfiguration: Self.playIconConfig)!
        if hasAppliedInitialState {
            playPauseIconView.setSymbolImage(image, contentTransition: .replace)
        } else {
            playPauseIconView.image = image
        }
        playPauseButton.accessibilityLabel = isPlaying ? String(localized: "Pause") : String(localized: "Play")
        animateBreathe(isPlaying: isPlaying)
    }

    /// Springs the artwork card between full scale while playing and a dimmed,
    /// smaller presentation while paused; skipped entirely under Reduce Motion.
    func animateBreathe(isPlaying: Bool) {
        guard !UIAccessibility.isReduceMotionEnabled else {
            artworkContainer.transform = .identity
            artworkView.alpha = 1
            return
        }
        breatheAnimator?.stopAnimation(true)
        let scale = isPlaying ? 1.0 : Self.pausedArtworkScale
        artworkRestScale = scale
        let animator = UIViewPropertyAnimator(duration: 0.42, dampingRatio: 0.76) { [self] in
            artworkContainer.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
        animator.startAnimation()
        breatheAnimator = animator
    }

    func skip(by seconds: TimeInterval) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let target = min(max(0, AudioPlayer.shared.currentTime + seconds), AudioPlayer.shared.duration)
        viewModel.seek(to: target)
    }

    func updateShuffleRepeatState() {
        let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let animated = hasAppliedInitialState
        let shuffleActive = AudioPlayer.shared.shuffleEnabled
        shuffleButton.tintColor = shuffleActive ? .white : .white.withAlphaComponent(0.55)
        shuffleButton.accessibilityValue = shuffleActive ? String(localized: "On") : String(localized: "Off")
        shuffleCapsule?.setActive(shuffleActive, animated: animated)

        switch AudioPlayer.shared.repeatMode {
        case .off:
            repeatButton.setImage(UIImage(systemName: "repeat", withConfiguration: config), for: .normal)
            repeatButton.tintColor = .white.withAlphaComponent(0.55)
            repeatButton.accessibilityValue = String(localized: "Off")
            repeatCapsule?.setActive(false, animated: animated)
            repeatCapsule?.setBadge(nil)
        case .all:
            repeatButton.setImage(UIImage(systemName: "repeat", withConfiguration: config), for: .normal)
            repeatButton.tintColor = .white
            repeatButton.accessibilityValue = String(localized: "All")
            repeatCapsule?.setActive(true, animated: animated)
            repeatCapsule?.setBadge(String(localized: "ALL"))
        case .one:
            repeatButton.setImage(UIImage(systemName: "repeat.1", withConfiguration: config), for: .normal)
            repeatButton.tintColor = .white
            repeatButton.accessibilityValue = String(localized: "One")
            repeatCapsule?.setActive(true, animated: animated)
            repeatCapsule?.setBadge("1")
        }
    }

    func updateQueueBadge() {
        let count = AudioPlayer.shared.queue.count
        queueCapsule?.setBadge(count > 1 ? (count > 99 ? "99+" : "\(count)") : nil)
        let countPart = count > 0 ? String(localized: "\(count) tracks") : nil
        let shownPart = centerState == .queue ? String(localized: "Shown") : nil
        let parts = [countPart, shownPart].compactMap { $0 }
        queueButton.accessibilityValue = parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    @objc func queueDidChange() {
        updateQueueBadge()
    }
}
