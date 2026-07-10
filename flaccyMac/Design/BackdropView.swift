import AppKit
import MetalKit

/// Animated ambient color-field backdrop driven by the shared Backdrop.metal
/// shader. Renders at half the window's pixel size (the field is soft by
/// design, so half resolution is indistinguishable and four times cheaper),
/// pauses whenever the window is occluded, and falls back to a static
/// gradient under Reduce Motion or without Metal.
final class BackdropView: NSView {

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
    private var occlusionObserver: NSObjectProtocol?
    private var externallyPaused = false

    private static let crossfadeDuration: CFTimeInterval = 1.0
    private static let drawableScale: CGFloat = 0.5

    override init(frame frameRect: NSRect) {
        let initial = ArtworkPaletteExtractor.fallbackPalette(seed: "flaccy").simdColors
        colorsFrom = initial
        colorsTo = initial
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !configureMetal() {
            configureFallbackGradient()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
    }

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
        externallyPaused = paused
        applyPauseState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        guard let window else { return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPauseState() }
        }
        applyPauseState()
    }

    override func layout() {
        super.layout()
        mtkView?.frame = bounds
        updateDrawableSize()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fallbackGradient?.frame = bounds
        CATransaction.commit()
    }

    private func applyPauseState() {
        let occluded = window.map { !$0.occlusionState.contains(.visible) } ?? true
        mtkView?.isPaused = externallyPaused || occluded
    }

    private func updateDrawableSize() {
        guard let mtkView, let window else { return }
        let scale = window.backingScaleFactor * Self.drawableScale
        let size = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
        if mtkView.drawableSize != size {
            mtkView.drawableSize = size
        }
    }

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
        metalView.autoResizeDrawable = false
        metalView.autoresizingMask = [.width, .height]
        addSubview(metalView)
        mtkView = metalView
        return true
    }

    private func configureFallbackGradient() {
        let gradient = CAGradientLayer()
        gradient.startPoint = CGPoint(x: 0.1, y: 0)
        gradient.endPoint = CGPoint(x: 0.9, y: 1)
        gradient.colors = gradientCGColors(from: colorsTo)
        layer?.addSublayer(gradient)
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
            NSColor(
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

extension BackdropView: MTKViewDelegate {

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
