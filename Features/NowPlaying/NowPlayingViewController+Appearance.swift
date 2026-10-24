import AVFoundation
import MidgarCore
import AVKit
import Combine
import UIKit

extension NowPlayingViewController {

    func prepareAppearanceAnimationIfNeeded() {
        guard !isMorphEmbedded else { return }
        guard !hasAnimatedAppearance, !UIAccessibility.isReduceMotionEnabled else { return }
        for group in appearanceGroups() {
            for element in group {
                element.alpha = 0
                element.transform = CGAffineTransform(translationX: 0, y: 14)
            }
        }
    }

    func runAppearanceAnimationIfNeeded() {
        guard !hasAnimatedAppearance else { return }
        hasAnimatedAppearance = true
        guard !isMorphEmbedded else { return }
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        for (index, group) in appearanceGroups().enumerated() {
            let animator = UIViewPropertyAnimator(duration: 0.32, dampingRatio: 0.84) { [self] in
                for element in group {
                    element.alpha = 1
                    element.transform = element === artworkContainer
                        ? CGAffineTransform(scaleX: artworkRestScale, y: artworkRestScale)
                        : .identity
                }
            }
            animator.startAnimation(afterDelay: Double(index) * 0.05)
        }
    }

    func appearanceGroups() -> [[UIView]] {
        [
            [artworkContainer],
            [titleMarquee, qualityBadge, equalizerBadge, loveButton, artistAvatarButton, artistButton, dashLabel, albumLabel, playingFromLabel],
            [scrubber, currentTimeLabel, remainingTimeLabel, skipBackButton, previousButton,
             playPauseButton, nextButton, skipForwardButton],
        ]
    }
}
