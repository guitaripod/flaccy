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
    private let startTime = CACurrentMediaTime()
    private var fadeStartTime: CFTimeInterval?
    private var colorsFrom: [SIMD4<Float>]
    private var colorsTo: [SIMD4<Float>]

    private static let crossfadeDuration: CFTimeInterval = 1.0

    override init(frame: CGRect) {
        let initial = ArtworkPaletteExtractor.fallbackPalette(seed: "flaccy").simdColors
        colorsFrom = initial
        colorsTo = initial
        super.init(frame: frame)
        isUserInteractionEnabled = false
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

    func setPaused(_ paused: Bool) {
        mtkView?.isPaused = paused
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        mtkView?.contentScaleFactor = 1.0
        fallbackGradient?.frame = bounds
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
