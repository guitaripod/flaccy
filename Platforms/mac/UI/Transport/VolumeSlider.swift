import AppKit

final class VolumeSlider: NSSlider {

    override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width, height: 24)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = Double(event.scrollingDeltaY + event.scrollingDeltaX)
        guard delta != 0 else { return }
        let step = event.hasPreciseScrollingDeltas ? 0.004 : 0.03
        doubleValue = min(maxValue, max(minValue, doubleValue + delta * step))
        sendAction(action, to: target)
    }
}
