import AppKit
import FlaccyCore

/// Draws one `ArtworkFraming` of one image: the single routine behind the crop
/// frame and every preview of it. The image sits on a layer whose frame is the
/// framing's geometry scaled to this view, so a 32 pt preview and a 400 pt crop
/// frame show the same pixels and neither has a second implementation to drift.
class ArtworkFramedView: NSView {

    private(set) var image: CGImage?
    private(set) var framing: ArtworkFraming?

    private let imageLayer = CALayer()

    var cornerRadius: CGFloat = 12 {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = cornerRadius
        layer?.backgroundColor = MacColors.fill(0.08).cgColor
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        imageLayer.isHidden = true
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ image: CGImage?, framing: ArtworkFraming?) {
        self.image = image
        self.framing = framing
        imageLayer.contents = image
        imageLayer.isHidden = image == nil
        placeImage(animated: false)
    }

    func update(framing: ArtworkFraming?, animated: Bool) {
        self.framing = framing
        placeImage(animated: animated)
    }

    override func layout() {
        super.layout()
        placeImage(animated: false)
    }

    private func placeImage(animated: Bool) {
        guard let framing, image != nil, bounds.width > 0 else { return }
        let scale = bounds.width / framing.frameSide
        let zoom = framing.zoom * scale
        let frame = CGRect(
            x: bounds.width / 2 - framing.centerX * zoom,
            y: bounds.height / 2 - framing.centerY * zoom,
            width: framing.imageWidth * zoom,
            height: framing.imageHeight * zoom
        )
        let smooth = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setDisableActions(!smooth)
        if smooth {
            CATransaction.setAnimationDuration(0.22)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        }
        imageLayer.frame = frame
        CATransaction.commit()
    }
}
