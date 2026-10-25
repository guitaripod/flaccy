import UIKit

/// A square frame over an image that the person pans and pinches to compose a
/// cover. The image can never be moved off the frame, so whatever is saved
/// always fills the square. Rule-of-thirds guides fade in while a finger is
/// down and out again as it lifts.
final class ArtworkCropView: UIView, UIScrollViewDelegate {

    var onFramingChanged: (() -> Void)?

    private(set) var hasUserFraming = false

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let guides = CropGuidesView()
    private let placeholder = UIImageView()
    private let activity = UIActivityIndicatorView(style: .large)
    private let dim = UIView()
    private var laidOutSide: CGFloat = 0
    private var needsInitialFit = false
    private var image: UIImage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var hasImage: Bool { image != nil }

    private func setup() {
        backgroundColor = UIColor.white.withAlphaComponent(0.08)
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Artwork preview")
        accessibilityHint = String(localized: "Pinch to zoom and drag to reposition")

        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never // duo-audit:ignore crop viewport positions the image itself and sits inside a card, not against a bar
        scrollView.bouncesZoom = true
        scrollView.decelerationRate = .fast
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        scrollView.addSubview(imageView)

        placeholder.image = UIImage(systemName: "music.note")
        placeholder.tintColor = UIColor.white.withAlphaComponent(0.35)
        placeholder.contentMode = .center
        placeholder.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 56, weight: .ultraLight)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)

        guides.alpha = 0
        guides.isUserInteractionEnabled = false
        guides.translatesAutoresizingMaskIntoConstraints = false
        addSubview(guides)

        dim.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        dim.alpha = 0
        dim.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dim)

        activity.color = .white
        activity.hidesWhenStopped = true
        activity.translatesAutoresizingMaskIntoConstraints = false
        addSubview(activity)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholder.topAnchor.constraint(equalTo: topAnchor),
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: trailingAnchor),
            placeholder.bottomAnchor.constraint(equalTo: bottomAnchor),
            guides.topAnchor.constraint(equalTo: topAnchor),
            guides.leadingAnchor.constraint(equalTo: leadingAnchor),
            guides.trailingAnchor.constraint(equalTo: trailingAnchor),
            guides.bottomAnchor.constraint(equalTo: bottomAnchor),
            dim.topAnchor.constraint(equalTo: topAnchor),
            dim.leadingAnchor.constraint(equalTo: leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: trailingAnchor),
            dim.bottomAnchor.constraint(equalTo: bottomAnchor),
            activity.centerXAnchor.constraint(equalTo: centerXAnchor),
            activity.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    func setImage(_ newImage: UIImage, userInitiated: Bool) {
        image = newImage
        hasUserFraming = userInitiated
        placeholder.isHidden = true
        imageView.image = newImage
        imageView.frame = CGRect(origin: .zero, size: newImage.size)
        scrollView.contentSize = newImage.size
        needsInitialFit = true
        fitIfPossible()
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    private func fitIfPossible() {
        guard needsInitialFit, image != nil, bounds.width > 0 else { return }
        needsInitialFit = false
        configureZoomRange()
        scrollView.zoomScale = scrollView.minimumZoomScale
        centerContent(resetOffset: true)
    }

    func setLoading(_ loading: Bool) {
        UIView.animate(withDuration: 0.2) { self.dim.alpha = loading ? 1 : 0 }
        if loading { activity.startAnimating() } else { activity.stopAnimating() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = bounds.width
        guard side > 0, image != nil else { return }
        if needsInitialFit {
            fitIfPossible()
            return
        }
        guard abs(side - laidOutSide) > 0.5 else { return }
        let hadFraming = hasUserFraming
        configureZoomRange()
        scrollView.zoomScale = max(scrollView.zoomScale, scrollView.minimumZoomScale)
        centerContent(resetOffset: false)
        hasUserFraming = hadFraming
    }

    private func configureZoomRange() {
        guard let image, bounds.width > 0 else { return }
        laidOutSide = bounds.width
        let fill = max(bounds.width / image.size.width, bounds.height / image.size.height)
        scrollView.minimumZoomScale = fill
        scrollView.maximumZoomScale = max(fill * 5, 1)
    }

    private func centerContent(resetOffset: Bool) {
        guard let image else { return }
        let scaled = CGSize(
            width: image.size.width * scrollView.zoomScale,
            height: image.size.height * scrollView.zoomScale
        )
        if resetOffset {
            scrollView.contentOffset = CGPoint(
                x: max(0, (scaled.width - bounds.width) / 2),
                y: max(0, (scaled.height - bounds.height) / 2)
            )
        } else {
            let maxX = max(0, scaled.width - bounds.width)
            let maxY = max(0, scaled.height - bounds.height)
            scrollView.contentOffset = CGPoint(
                x: min(max(0, scrollView.contentOffset.x), maxX),
                y: min(max(0, scrollView.contentOffset.y), maxY)
            )
        }
    }

    /// The visible square at `side` pixels, drawn straight from the source so
    /// panning to a corner of a large photo keeps its full detail.
    func croppedImage(side: CGFloat) -> UIImage? {
        guard let image, bounds.width > 0 else { return nil }
        let zoom = scrollView.zoomScale
        let visible = CGRect(
            x: scrollView.contentOffset.x / zoom,
            y: scrollView.contentOffset.y / zoom,
            width: bounds.width / zoom,
            height: bounds.height / zoom
        )
        let outputSide = min(side, max(visible.width, visible.height) * image.scale)
        let factor = outputSide / visible.width
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: outputSide, height: outputSide), format: format)
        return renderer.image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: outputSide, height: outputSide))
            image.draw(in: CGRect(
                x: -visible.minX * factor,
                y: -visible.minY * factor,
                width: image.size.width * factor,
                height: image.size.height * factor
            ))
        }
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard image != nil else { return }
        let atFill = scrollView.zoomScale <= scrollView.minimumZoomScale * 1.01
        if atFill {
            let target = min(scrollView.maximumZoomScale, scrollView.minimumZoomScale * 2.5)
            let point = gesture.location(in: imageView)
            let size = CGSize(width: bounds.width / target, height: bounds.height / target)
            scrollView.zoom(to: CGRect(
                x: point.x - size.width / 2, y: point.y - size.height / 2,
                width: size.width, height: size.height
            ), animated: true)
        } else {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        }
        UISelectionFeedbackGenerator().selectionChanged()
        markFramed()
    }

    private func markFramed() {
        hasUserFraming = true
        onFramingChanged?()
    }

    private func setGuides(visible: Bool) {
        UIView.animate(withDuration: visible ? 0.12 : 0.35, delay: visible ? 0 : 0.25, options: [.beginFromCurrentState]) {
            self.guides.alpha = visible ? 1 : 0
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { setGuides(visible: true) }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { setGuides(visible: true) }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { setGuides(visible: false) }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { setGuides(visible: false) }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        setGuides(visible: false)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView.isTracking || scrollView.isDecelerating || scrollView.isZooming { markFramed() }
    }
}

private final class CropGuidesView: UIView {

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.55).cgColor)
        context.setLineWidth(0.75)
        for step in 1...2 {
            let x = bounds.width * CGFloat(step) / 3
            let y = bounds.height * CGFloat(step) / 3
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: bounds.height))
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: bounds.width, y: y))
        }
        context.strokePath()
    }
}
