import MediaPlayer
import UIKit

/// Hosts MPVolumeView with a usable touch surface. The row is a full 44pt
/// tall so the system slider is no longer a sliver, the redundant route
/// button is hidden (AirPlay lives in the action row), the slider gets a
/// visible thumb and track tints matching the scrubber, and touches that land
/// on the row but miss the tiny thumb drive the slider's value directly so
/// the whole row is draggable.
final class SystemVolumeSlider: UIView {

    private let volumeView = MPVolumeView()
    private var hasStyledSlider = false
    private let grabGenerator = UIImpactFeedbackGenerator(style: .light)

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
        volumeView.isUserInteractionEnabled = false
        addSubview(volumeView)
        isAccessibilityElement = true
        accessibilityLabel = "Volume"
        accessibilityTraits = .adjustable
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 44)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        volumeView.frame = bounds
        hideRouteButton()
        styleSliderIfNeeded()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: 0, dy: -6).contains(point)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        grabGenerator.impactOccurred()
        applyVolume(from: touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        applyVolume(from: touches)
    }

    private func applyVolume(from touches: Set<UITouch>) {
        guard let touch = touches.first, let slider = internalSlider(), bounds.width > 0 else { return }
        let fraction = Float(min(max(touch.location(in: self).x / bounds.width, 0), 1))
        slider.setValue(fraction, animated: false)
        slider.sendActions(for: .valueChanged)
    }

    private func internalSlider() -> UISlider? {
        volumeView.subviews.lazy.compactMap { $0 as? UISlider }.first
    }

    private func hideRouteButton() {
        for subview in volumeView.subviews where subview is UIButton {
            subview.isHidden = true
        }
    }

    private func styleSliderIfNeeded() {
        guard !hasStyledSlider, let slider = internalSlider() else { return }
        hasStyledSlider = true
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = .white.withAlphaComponent(0.25)
        volumeView.setVolumeThumbImage(thumbImage, for: .normal)
    }

    override func accessibilityIncrement() {
        adjustVolume(by: 0.0625)
    }

    override func accessibilityDecrement() {
        adjustVolume(by: -0.0625)
    }

    override var accessibilityValue: String? {
        get {
            guard let slider = internalSlider() else { return nil }
            return "\(Int(round(slider.value * 100))) percent"
        }
        set {}
    }

    private func adjustVolume(by delta: Float) {
        guard let slider = internalSlider() else { return }
        slider.setValue(min(max(slider.value + delta, 0), 1), animated: false)
        slider.sendActions(for: .valueChanged)
    }
}
