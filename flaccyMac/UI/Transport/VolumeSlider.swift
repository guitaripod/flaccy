import AppKit

/// App-volume slider that also responds to the scroll wheel, the desktop
/// convention for transport-bar volume controls.
final class VolumeSlider: NSSlider {

    override func scrollWheel(with event: NSEvent) {
        let delta = Double(event.scrollingDeltaY + event.scrollingDeltaX)
        guard delta != 0 else { return }
        let step = event.hasPreciseScrollingDeltas ? 0.004 : 0.03
        doubleValue = min(maxValue, max(minValue, doubleValue + delta * step))
        sendAction(action, to: target)
    }
}
