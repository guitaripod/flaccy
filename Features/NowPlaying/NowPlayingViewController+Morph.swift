import AVFoundation
import MidgarCore
import AVKit
import Combine
import UIKit

extension NowPlayingViewController {

    /// The frame the morph proxy should land on, in this controller's own
    /// coordinate space (identical to the morph container's, since this view is
    /// pinned full-screen and never transformed — a transform would corrupt the
    /// safe-area-derived layout): the big artwork card normally, or the compact
    /// header's artwork when lyrics/queue are shown.
    func artworkMorphFrame() -> CGRect {
        view.layoutIfNeeded()
        if centerState != .artwork {
            return compactArtworkView.convert(compactArtworkView.bounds, to: view)
        }
        guard let parent = artworkContainer.superview else { return artworkContainer.frame }
        return parent.convert(artworkContainer.frame, to: view)
    }

    var artworkMorphCornerRadius: CGFloat {
        centerState == .artwork ? 20 : 10
    }

    /// Hides the player's own artwork views so the morph proxy owns the
    /// artwork while the surrounding chrome cross-fades independently.
    func setArtworkHiddenForMorph(_ hidden: Bool) {
        let alpha: CGFloat = hidden ? 0 : 1
        artworkContainer.alpha = alpha
        compactArtworkView.alpha = alpha
    }

    /// Drives the ambient backdrop from the morph container: it runs only while
    /// the player is expanded, and stays paused behind the docked mini player.
    func setBackdropActive(_ active: Bool) {
        morphBackdropActive = active
        if active {
            guard !scrubber.isScrubbing else { return }
            backdropView.setPaused(false)
        } else {
            backdropView.setPaused(true)
        }
    }

    func setPaneMode(_ enabled: Bool) {
        isPaneMode = enabled
        grabberControl.isHidden = enabled
        if enabled {
            onFocusRequest?(centerState != .artwork)
        } else {
            setFocused(false)
        }
    }

    /// Asked for by the container once the window gives the player the whole
    /// width, or taken back when the library returns beside it.
    func setFocused(_ focused: Bool) {
        guard focused != isFocused else { return }
        isFocused = focused
        view.setNeedsLayout()
    }

    func showQueueCenterState() {
        setCenterState(.queue)
    }

    func showLyricsCenterState() {
        setCenterState(.lyrics)
    }

    /// Whether a downward drag at the given point should collapse the player
    /// rather than be consumed by an interactive control or a mid-scroll list.
    /// Always refused mid-scrub so a drifting scrub finger can never hand the
    /// touch to the collapse gesture.
    func morphCollapseAllowed(at point: CGPoint) -> Bool {
        guard !scrubber.isScrubbing else { return false }
        guard let hit = view.hitTest(point, with: nil) else { return true }
        var node: UIView? = hit
        while let current = node, current !== view {
            if current === scrubber || current === volumeSlider {
                return false
            }
            if let scroll = current as? UIScrollView,
               scroll.contentOffset.y > -scroll.adjustedContentInset.top + 0.5 {
                return false
            }
            node = current.superview
        }
        return true
    }
}
