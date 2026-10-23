import AVFoundation
import MidgarCore
import AVKit
import Combine
import UIKit

extension NowPlayingViewController {

    func scrubBegan() {
        backdropView.setPaused(true)
        updateScrubBubble(time: scrubber.currentTime)
        UIView.animate(withDuration: 0.12) { self.scrubBubble.alpha = 1 }
    }

    func scrubChanged(to time: TimeInterval) {
        chaseTime = time
        updateTimeLabelsFromScrubber(time)
        updateScrubBubble(time: time)
        if !isSeeking {
            seekToChaseTime()
        }
    }

    func scrubEnded(at time: TimeInterval) {
        MidgarLog.debug("scrubEnded time=\(time) isSeeking=\(isSeeking)", category: .ui)
        if presentedViewController == nil, view.window != nil {
            backdropView.setPaused(false)
        }
        UIView.animate(withDuration: 0.12) { self.scrubBubble.alpha = 0 }
        chaseTime = time
        seekToChaseTime()
    }

    func updateScrubBubble(time: TimeInterval) {
        let total = Int(time)
        scrubBubbleLabel.text = String(format: "%d:%02d", total / 60, total % 60)
        scrubBubbleLabel.sizeToFit()
        let bubbleSize = CGSize(width: scrubBubbleLabel.bounds.width + 20, height: 24)
        scrubBubble.bounds = CGRect(origin: .zero, size: bubbleSize)
        scrubBubbleLabel.frame = scrubBubble.bounds
        let anchor = scrubber.convert(CGPoint(x: scrubber.playheadX, y: 0), to: view)
        let halfWidth = bubbleSize.width / 2
        let clampedX = min(max(anchor.x, halfWidth + 8), view.bounds.width - halfWidth - 8)
        scrubBubble.center = CGPoint(x: clampedX, y: anchor.y - 18)
    }

    func seekToChaseTime() {
        isSeeking = true
        let generation = seekGeneration
        let target = chaseTime
        let cmTime = CMTime(seconds: target, preferredTimescale: 600)
        let tolerance = scrubber.isScrubbing
            ? CMTime(seconds: 0.5, preferredTimescale: 600)
            : CMTime.zero

        AudioPlayer.shared.seekSmooth(to: cmTime, tolerance: tolerance) { [weak self] in
            guard let self else { return }
            self.isSeeking = false
            guard generation == self.seekGeneration else { return }
            MidgarLog.debug(
                "seek complete target=\(target) chase=\(self.chaseTime) scrubbing=\(self.scrubber.isScrubbing)",
                category: .ui
            )
            if abs(self.chaseTime - target) > 0.5 {
                self.seekToChaseTime()
            }
        }
    }

    func updateTimeLabelsFromScrubber(_ time: TimeInterval) {
        let total = Int(time)
        currentTimeLabel.text = String(format: "%d:%02d", total / 60, total % 60)
        let rem = max(0, scrubber.duration - time)
        let remTotal = Int(rem)
        remainingTimeLabel.text = String(format: "-%d:%02d", remTotal / 60, remTotal % 60)
    }
}
