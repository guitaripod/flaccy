import MediaPlayer
import UIKit

/// Hosts MPVolumeView with its internal UISlider expanded to the full 44pt
/// row and receiving touches natively, so volume drags are as forgiving as
/// any system slider and the sheet's dismiss pan defers to it. The redundant
/// route button is hidden (AirPlay lives in the action row) and the slider
/// gets a visible thumb and track tints matching the scrubber.
///
/// MPVolumeView re-lays its slider out on its own whenever routes, the audio
/// session or the volume warning change, often inside an animation. Its slider
/// and route rects are pinned here so every one of those passes lands on the
/// same full-height frame and the bar never drifts up and down.
private final class FullHeightVolumeView: MPVolumeView {
    override func volumeSliderRect(forBounds bounds: CGRect) -> CGRect {
        bounds
    }

    override func routeButtonRect(forBounds bounds: CGRect) -> CGRect {
        .zero
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for subview in subviews {
            if subview is UISlider {
                pinWithoutAnimation(subview)
            } else if subview is UIButton {
                subview.isHidden = true
            }
        }
    }

    /// Snaps the slider to the row outside any animation in flight, so a
    /// relayout MPVolumeView triggers never shows as motion.
    private func pinWithoutAnimation(_ slider: UIView) {
        guard slider.frame != bounds else { return }
        UIView.performWithoutAnimation { slider.frame = bounds }
    }
}

final class SystemVolumeSlider: UIView {

    private let volumeView = FullHeightVolumeView()
    private var hasStyledSlider = false

    private lazy var thumbImage: UIImage = {
        let size: CGFloat = 18
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { context in
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
        }
    }()

    init() {
        super.init(frame: .zero)
        volumeView.tintColor = .white
        addSubview(volumeView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 44)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if volumeView.frame != bounds {
            UIView.performWithoutAnimation { volumeView.frame = bounds }
        }
        styleSliderIfNeeded()
        #if targetEnvironment(simulator)
        addSimulatorSliderIfNeeded()
        #endif
    }

    #if targetEnvironment(simulator)
    private var simulatorSlider: UISlider?

    /// MPVolumeView renders no slider on the Simulator (there is no volume
    /// hardware), which blanks the row in screenshots. A static stand-in
    /// slider keeps the Now Playing layout truthful to what devices show.
    private func addSimulatorSliderIfNeeded() {
        guard internalSlider() == nil else { return }
        if let simulatorSlider {
            simulatorSlider.frame = bounds
            return
        }
        let slider = UISlider(frame: bounds)
        slider.value = 0.7
        slider.isUserInteractionEnabled = false
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = .white.withAlphaComponent(0.25)
        slider.setThumbImage(thumbImage, for: .normal)
        slider.accessibilityLabel = String(localized: "Volume")
        addSubview(slider)
        simulatorSlider = slider
    }
    #endif

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: 0, dy: -6).contains(point)
    }

    /// Routes every touch on the row to the native slider so its full-width
    /// surface is draggable without hunting for the thumb.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard self.point(inside: point, with: event), let slider = internalSlider() else {
            return super.hitTest(point, with: event)
        }
        return slider
    }

    private func internalSlider() -> UISlider? {
        volumeView.subviews.lazy.compactMap { $0 as? UISlider }.first
    }

    private func styleSliderIfNeeded() {
        guard !hasStyledSlider, let slider = internalSlider() else { return }
        hasStyledSlider = true
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = .white.withAlphaComponent(0.25)
        slider.accessibilityLabel = String(localized: "Volume")
        volumeView.setVolumeThumbImage(thumbImage, for: .normal)
    }
}
