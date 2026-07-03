import MetalKit
import UIKit

final class NowPlayingBackdropView: UIView {

    private struct Uniforms {
        var colors: (
            SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
            SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>
        )
        var time: Float
        var fade: Float
        var padding: SIMD2<Float>
    }

    private var mtkView: MTKView?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var fallbackGradient: CAGradientLayer?
    private let ambientImageView = UIImageView()
    private var hasArtistImage = false
    private let startTime = CACurrentMediaTime()
    private var fadeStartTime: CFTimeInterval?
    private var colorsFrom: [SIMD4<Float>]
    private var colorsTo: [SIMD4<Float>]

    private static let crossfadeDuration: CFTimeInterval = 1.0
    private static let ambientPhotoAlpha: CGFloat = 0.55
    private static let colorFieldOverPhotoAlpha: CGFloat = 0.72
    private static let kenBurnsKey = "kenBurns"

    override init(frame: CGRect) {
        let initial = ArtworkPaletteExtractor.fallbackPalette(seed: "flaccy").simdColors
        colorsFrom = initial
        colorsTo = initial
        super.init(frame: frame)
        isUserInteractionEnabled = false
        configureAmbientImageView()
        if UIAccessibility.isReduceMotionEnabled || !configureMetal() {
            configureFallbackGradient()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ palette: ArtworkPalette, animated: Bool) {
        let target = paddedColors(from: palette)
        if let fallbackGradient {
            CATransaction.begin()
            CATransaction.setAnimationDuration(animated ? Self.crossfadeDuration : 0)
            fallbackGradient.colors = gradientCGColors(from: target)
            CATransaction.commit()
            return
        }
        if animated {
            colorsFrom = currentBlendedColors()
            colorsTo = target
            fadeStartTime = CACurrentMediaTime()
        } else {
            colorsFrom = target
            colorsTo = target
            fadeStartTime = nil
        }
    }

    /// Crossfades a heavily-dimmed artist photo in behind the color field and
    /// drops the field's opacity so the palette flow plays over the photo;
    /// passing nil restores the pure-shader look.
    func setArtistImage(_ image: UIImage?, animated: Bool) {
        let hadImage = hasArtistImage
        hasArtistImage = image != nil

        let applyImage = { self.ambientImageView.image = image }
        if animated, image != nil, hadImage, !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(with: ambientImageView, duration: 0.6, options: [.transitionCrossDissolve], animations: applyImage)
        } else {
            applyImage()
        }

        let targetPhotoAlpha: CGFloat = image == nil ? 0 : Self.ambientPhotoAlpha
        let targetFieldAlpha: CGFloat = image == nil ? 1 : Self.colorFieldOverPhotoAlpha
        let applyAlphas = {
            self.ambientImageView.alpha = targetPhotoAlpha
            self.mtkView?.alpha = targetFieldAlpha
            self.fallbackGradient?.opacity = Float(targetFieldAlpha)
        }
        if animated {
            UIView.animate(withDuration: 0.8, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut], animations: applyAlphas)
        } else {
            applyAlphas()
        }
        updateKenBurns()
    }

    func setPaused(_ paused: Bool) {
        mtkView?.isPaused = paused
        if paused {
            if let presented = ambientImageView.layer.presentation() {
                ambientImageView.layer.transform = presented.transform
            }
            ambientImageView.layer.removeAnimation(forKey: Self.kenBurnsKey)
        } else {
            updateKenBurns()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        mtkView?.contentScaleFactor = 1.0
        fallbackGradient?.frame = bounds
        ambientImageView.frame = bounds
    }

    private func configureAmbientImageView() {
        ambientImageView.contentMode = .scaleAspectFill
        ambientImageView.clipsToBounds = false
        ambientImageView.alpha = 0
        ambientImageView.frame = bounds
        clipsToBounds = true
        addSubview(ambientImageView)
    }

    /// Runs a ~40s autoreversing pan/zoom on the photo layer; pure Core
    /// Animation, restarted after pauses, skipped under Reduce Motion.
    private func updateKenBurns() {
        guard hasArtistImage else {
            ambientImageView.layer.removeAnimation(forKey: Self.kenBurnsKey)
            ambientImageView.layer.transform = CATransform3DIdentity
            return
        }
        guard !UIAccessibility.isReduceMotionEnabled else {
            ambientImageView.layer.transform = CATransform3DMakeScale(1.1, 1.1, 1)
            return
        }
        guard ambientImageView.layer.animation(forKey: Self.kenBurnsKey) == nil else { return }

        let current = ambientImageView.layer.transform
        let from = CATransform3DIsIdentity(current) ? CATransform3DMakeScale(1.12, 1.12, 1) : current
        var to = CATransform3DMakeScale(1.24, 1.24, 1)
        to = CATransform3DTranslate(to, bounds.width * 0.025, bounds.height * -0.02, 0)

        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = 40
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.isRemovedOnCompletion = false
        ambientImageView.layer.transform = from
        ambientImageView.layer.add(animation, forKey: Self.kenBurnsKey)
    }

    /// Sets up the 1×-scale, frame-capped MTKView; returns false when the device
    /// or shader library is unavailable so the gradient fallback takes over.
    private func configureMetal() -> Bool {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "backdrop_vertex"),
              let fragmentFunction = library.makeFunction(name: "backdrop_fragment"),
              let queue = device.makeCommandQueue()
        else {
            AppLogger.warning("Metal backdrop unavailable, using gradient fallback", category: .ui)
            return false
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            AppLogger.error("Backdrop pipeline creation failed, using gradient fallback", category: .ui)
            return false
        }
        commandQueue = queue
        pipelineState = pipeline

        let metalView = MTKView(frame: bounds, device: device)
        metalView.delegate = self
        metalView.preferredFramesPerSecond = 28
        metalView.framebufferOnly = true
        metalView.isOpaque = true
        metalView.contentScaleFactor = 1.0
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(metalView)
        mtkView = metalView
        return true
    }

    private func configureFallbackGradient() {
        let gradient = CAGradientLayer()
        gradient.startPoint = CGPoint(x: 0.1, y: 0)
        gradient.endPoint = CGPoint(x: 0.9, y: 1)
        gradient.colors = gradientCGColors(from: colorsTo)
        layer.addSublayer(gradient)
        fallbackGradient = gradient
    }

    private func paddedColors(from palette: ArtworkPalette) -> [SIMD4<Float>] {
        var colors = palette.simdColors
        while colors.count < 4 {
            colors.append(colors.last ?? SIMD4<Float>(0.2, 0.2, 0.3, 1))
        }
        return Array(colors.prefix(4))
    }

    private func gradientCGColors(from colors: [SIMD4<Float>]) -> [CGColor] {
        colors.map { simd in
            UIColor(
                red: CGFloat(simd.x) * 0.7,
                green: CGFloat(simd.y) * 0.7,
                blue: CGFloat(simd.z) * 0.7,
                alpha: 1
            ).cgColor
        }
    }

    private func currentBlendedColors() -> [SIMD4<Float>] {
        let progress = currentFadeProgress()
        guard progress < 1 else { return colorsTo }
        return zip(colorsFrom, colorsTo).map { simd_mix($0, $1, SIMD4<Float>(repeating: progress)) }
    }

    private func currentFadeProgress() -> Float {
        guard let fadeStartTime else { return 1 }
        return Float(min(1, (CACurrentMediaTime() - fadeStartTime) / Self.crossfadeDuration))
    }
}

extension NowPlayingBackdropView: MTKViewDelegate {

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipelineState,
              let commandQueue,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        let fade = currentFadeProgress()
        if fade >= 1, fadeStartTime != nil {
            colorsFrom = colorsTo
            fadeStartTime = nil
        }
        var uniforms = Uniforms(
            colors: (
                colorsFrom[0], colorsFrom[1], colorsFrom[2], colorsFrom[3],
                colorsTo[0], colorsTo[1], colorsTo[2], colorsTo[3]
            ),
            time: Float(CACurrentMediaTime() - startTime),
            fade: fadeStartTime == nil ? 0 : fade,
            padding: .zero
        )
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
