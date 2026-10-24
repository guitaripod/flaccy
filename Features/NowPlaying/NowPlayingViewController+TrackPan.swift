import AVFoundation
import MidgarCore
import AVKit
import Combine
import UIKit

extension NowPlayingViewController {

    /// Interactive, interruptible track-change gesture. The card tracks the
    /// finger 1:1 via a paused linear animator scrubbed by translation, with
    /// rubber-band resistance past 60% of the width (or from zero when the
    /// direction is blocked), the neighbor's artwork peeking from the opposite
    /// edge, and a velocity-seeded spring settle in either direction.
    @objc func handleTrackPan(_ gesture: UIPanGestureRecognizer) {
        guard !UIAccessibility.isReduceMotionEnabled else {
            handleReducedMotionTrackPan(gesture)
            return
        }
        let width = max(artworkContainer.bounds.width, 1)
        let translation = gesture.translation(in: view).x
        let velocity = gesture.velocity(in: view).x
        switch gesture.state {
        case .began:
            beginTrackPan()
        case .changed:
            scrubTrackPan(translation: translation, width: width)
        case .ended:
            settleTrackPan(velocity: velocity, width: width, cancelled: false)
        case .cancelled, .failed:
            settleTrackPan(velocity: velocity, width: width, cancelled: true)
        default:
            break
        }
    }

    /// Grabs a settling card mid-flight: the running animator is paused at its
    /// current fraction and further scrubbing continues from there.
    func beginTrackPan() {
        thresholdTickGenerator.prepare()
        if let animator = trackPanAnimator, animator.state == .active {
            animator.pauseAnimation()
            animator.isReversed = false
            trackPanBaseFraction = animator.fractionComplete
        } else {
            trackPanAnimator = nil
            trackPanDirection = 0
            trackPanBaseFraction = 0
            trackPanCommitted = false
            trackPanPastThreshold = false
        }
    }

    func startTrackPan(direction: CGFloat, width: CGFloat) {
        trackPanDirection = direction
        trackPanBlocked = isTrackChangeBlocked(direction: direction)
        trackPanBaseFraction = 0
        trackPanCommitted = false
        trackPanPastThreshold = false
        deferredArtwork = nil
        isInteractiveTrackTransitionActive = true
        if !trackPanBlocked {
            configurePeekArtwork(with: neighborTrack(direction: direction))
            peekArtworkView.transform = CGAffineTransform(
                translationX: -direction * width * TrackPan.peekStartMultiplier, y: 0
            ).scaledBy(x: TrackPan.peekScale, y: TrackPan.peekScale)
            peekArtworkView.isHidden = false
        }
        let blocked = trackPanBlocked
        let fullDistance = trackPanFullDistance(width: width)
        let animator = UIViewPropertyAnimator(duration: 0.4, curve: .linear)
        animator.addAnimations { [self] in
            if blocked {
                artworkView.transform = CGAffineTransform(translationX: direction * fullDistance, y: 0)
                    .rotated(by: direction * TrackPan.exitRotation * 0.5)
                    .scaledBy(x: 0.97, y: 0.97)
            } else {
                artworkView.transform = CGAffineTransform(translationX: direction * fullDistance, y: 0)
                    .rotated(by: direction * TrackPan.exitRotation)
                    .scaledBy(x: TrackPan.exitScale, y: TrackPan.exitScale)
                peekArtworkView.transform = .identity
            }
        }
        animator.addCompletion { [weak self] position in
            self?.trackPanDidSettle(at: position)
        }
        animator.pauseAnimation()
        trackPanAnimator = animator
    }

    func scrubTrackPan(translation: CGFloat, width: CGFloat) {
        if trackPanAnimator == nil {
            guard abs(translation) > 0.5 else { return }
            startTrackPan(direction: translation < 0 ? -1 : 1, width: width)
        }
        guard let animator = trackPanAnimator else { return }
        let fullDistance = trackPanFullDistance(width: width)
        let raw = trackPanBaseFraction * fullDistance + trackPanDirection * translation
        if raw < -6, trackPanBaseFraction == 0, !trackPanCommitted {
            flipTrackPanDirection(translation: translation, width: width)
            return
        }
        let mapped = rubberBandedDistance(max(0, raw), width: width)
        animator.fractionComplete = min(mapped / fullDistance, 1)
        updateThresholdTick(distance: mapped, width: width)
    }

    func flipTrackPanDirection(translation: CGFloat, width: CGFloat) {
        let newDirection = -trackPanDirection
        trackPanAnimator?.stopAnimation(true)
        trackPanAnimator = nil
        resetCardPresentation()
        startTrackPan(direction: newDirection, width: width)
        scrubTrackPan(translation: translation, width: width)
    }

    /// Commits when the card is past 35% of the width or flicked faster than
    /// 600 pt/s along the gesture direction (a strong opposite flick cancels);
    /// an already-committed transition always finishes forward.
    func settleTrackPan(velocity: CGFloat, width: CGFloat, cancelled: Bool) {
        guard let animator = trackPanAnimator else { return }
        let fullDistance = trackPanFullDistance(width: width)
        let distance = animator.fractionComplete * fullDistance
        let directionalVelocity = trackPanDirection * velocity
        let shouldCommit = trackPanCommitted
            || (!trackPanBlocked && !cancelled
                && directionalVelocity > -TrackPan.commitVelocity
                && (distance >= width * TrackPan.commitDistanceRatio
                    || directionalVelocity > TrackPan.commitVelocity))
        if shouldCommit {
            commitTrackPan(animator: animator, distance: distance, velocity: directionalVelocity, fullDistance: fullDistance)
        } else {
            cancelTrackPan(animator: animator, distance: distance, velocity: directionalVelocity, fullDistance: fullDistance)
        }
    }

    func commitTrackPan(
        animator: UIViewPropertyAnimator, distance: CGFloat, velocity: CGFloat, fullDistance: CGFloat
    ) {
        if !trackPanCommitted {
            trackPanCommitted = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            fireTrackChange(direction: trackPanDirection)
        }
        let remaining = max(fullDistance - distance, 1)
        let spring = UISpringTimingParameters(
            dampingRatio: 0.86, initialVelocity: CGVector(dx: max(0, velocity) / remaining, dy: 0)
        )
        animator.isReversed = false
        animator.continueAnimation(withTimingParameters: spring, durationFactor: 0.8)
    }

    func cancelTrackPan(
        animator: UIViewPropertyAnimator, distance: CGFloat, velocity: CGFloat, fullDistance: CGFloat
    ) {
        let remaining = max(distance, 1)
        let spring = UISpringTimingParameters(
            dampingRatio: 0.78, initialVelocity: CGVector(dx: max(0, -velocity) / remaining, dy: 0)
        )
        animator.isReversed = true
        animator.continueAnimation(withTimingParameters: spring, durationFactor: 0.7)
    }

    /// Finalizes a settled transition: on commit the peek image is promoted to
    /// the main card before the peek hides, so the swap is pixel-identical, and
    /// any artwork update deferred during the transition is applied directly.
    func trackPanDidSettle(at position: UIViewAnimatingPosition) {
        trackPanAnimator = nil
        isInteractiveTrackTransitionActive = false
        if case .some(let pending) = deferredArtwork {
            applyArtworkDirect(pending)
        } else if position == .end, trackPanCommitted {
            artworkView.contentMode = peekArtworkView.contentMode
            artworkView.image = peekArtworkView.image
        }
        deferredArtwork = nil
        resetCardPresentation()
        trackPanDirection = 0
        trackPanCommitted = false
        trackPanPastThreshold = false
    }

    func resetCardPresentation() {
        artworkView.transform = .identity
        peekArtworkView.isHidden = true
        peekArtworkView.transform = .identity
    }

    /// Maps raw finger distance to card distance: 1:1 up to 60% of the width
    /// then asymptotically resisted, or fully rubber-banded from zero when the
    /// direction has no track to go to.
    func rubberBandedDistance(_ distance: CGFloat, width: CGFloat) -> CGFloat {
        if trackPanBlocked {
            let range = width * TrackPan.blockedRangeRatio
            return range * (1 - 1 / (1 + distance / range))
        }
        let limit = width * TrackPan.linearLimitRatio
        guard distance > limit else { return distance }
        let range = width * TrackPan.rubberRangeRatio
        return limit + range * (1 - 1 / (1 + (distance - limit) / range))
    }

    func trackPanFullDistance(width: CGFloat) -> CGFloat {
        trackPanBlocked ? width * 0.5 : width * TrackPan.exitMultiplier
    }

    func updateThresholdTick(distance: CGFloat, width: CGFloat) {
        guard !trackPanBlocked else { return }
        let past = distance >= width * TrackPan.commitDistanceRatio
        guard past != trackPanPastThreshold else { return }
        trackPanPastThreshold = past
        thresholdTickGenerator.impactOccurred(intensity: past ? 1.0 : 0.6)
        thresholdTickGenerator.prepare()
    }

    func configurePeekArtwork(with track: Track?) {
        guard let track else {
            peekArtworkView.contentMode = .center
            peekArtworkView.image = UIImage(systemName: "music.note")
            return
        }
        let cached = track.artwork
            ?? AlbumArtworkCache.shared.artwork(forAlbum: track.albumTitle, artist: track.artist)
            ?? AlbumArtworkCache.shared.thumbnail(forAlbum: track.albumTitle, artist: track.artist)
        if let cached {
            peekArtworkView.contentMode = .scaleAspectFill
            peekArtworkView.image = cached
            return
        }
        peekArtworkView.contentMode = .center
        peekArtworkView.image = UIImage(systemName: "music.note")
        let key = "\(track.albumTitle)\0\(track.artist)"
        peekArtworkKey = key
        AlbumArtworkCache.shared.loadThumbnail(forAlbum: track.albumTitle, artist: track.artist) { [weak self] image in
            guard let self, self.peekArtworkKey == key, let image else { return }
            self.peekArtworkView.contentMode = .scaleAspectFill
            self.peekArtworkView.image = image
        }
    }

    /// Resolves the track whose artwork should peek in for the given direction,
    /// mirroring AudioPlayer semantics: forward wraps only on repeat-all, and a
    /// backward swipe more than 3s into a track restarts the current one.
    func neighborTrack(direction: CGFloat) -> Track? {
        let player = AudioPlayer.shared
        if direction < 0 {
            if player.currentIndex + 1 < player.queue.count {
                return player.queue[player.currentIndex + 1]
            }
            return player.repeatMode == .all ? player.queue.first : nil
        }
        if player.currentTime > 3 { return player.currentTrack }
        guard player.currentIndex > 0, player.currentIndex - 1 < player.queue.count else { return nil }
        return player.queue[player.currentIndex - 1]
    }

    func isTrackChangeBlocked(direction: CGFloat) -> Bool {
        let player = AudioPlayer.shared
        guard !player.queue.isEmpty else { return true }
        if direction < 0 {
            return player.currentIndex + 1 >= player.queue.count && player.repeatMode != .all
        }
        return player.currentIndex <= 0 && player.currentTime <= 3
    }

    func fireTrackChange(direction: CGFloat) {
        MidgarLog.info(
            "Interactive track change committed (\(direction < 0 ? "next" : "previous"))", category: .ui
        )
        if direction < 0 {
            viewModel.nextTrack()
        } else {
            viewModel.previousTrack()
        }
    }

    func handleReducedMotionTrackPan(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let width = max(artworkContainer.bounds.width, 1)
        let translation = gesture.translation(in: view).x
        let velocity = gesture.velocity(in: view).x
        let dominant = abs(translation) > 1 ? translation : velocity
        guard dominant != 0 else { return }
        let direction: CGFloat = dominant < 0 ? -1 : 1
        guard !isTrackChangeBlocked(direction: direction) else { return }
        guard direction * translation >= width * TrackPan.commitDistanceRatio
            || direction * velocity > TrackPan.commitVelocity else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        fireTrackChange(direction: direction)
    }

    /// Tilts the artwork card in 3D toward the touch point while pressed and
    /// springs it flat on release; disabled under Reduce Motion.
    @objc func handleTilt(_ gesture: UILongPressGestureRecognizer) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        switch gesture.state {
        case .began, .changed:
            let location = gesture.location(in: artworkContainer)
            let bounds = artworkContainer.bounds
            guard bounds.width > 0, bounds.height > 0 else { return }
            let normalizedX = (location.x / bounds.width - 0.5) * 2
            let normalizedY = (location.y / bounds.height - 0.5) * 2
            let maxAngle: CGFloat = 6 * .pi / 180
            var transform = CATransform3DIdentity
            transform.m34 = -1 / 600
            transform = CATransform3DRotate(transform, -normalizedY * maxAngle, 1, 0, 0)
            transform = CATransform3DRotate(transform, normalizedX * maxAngle, 0, 1, 0)
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            artworkView.layer.transform = transform
            CATransaction.commit()
        case .ended, .cancelled, .failed:
            let spring = CASpringAnimation(keyPath: "transform")
            spring.fromValue = artworkView.layer.presentation()?.transform ?? artworkView.layer.transform
            spring.toValue = CATransform3DIdentity
            spring.damping = 14
            spring.stiffness = 160
            spring.duration = spring.settlingDuration
            artworkView.layer.transform = CATransform3DIdentity
            artworkView.layer.add(spring, forKey: "tiltRelease")
        default:
            break
        }
    }
}
