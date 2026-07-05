import QuartzCore
import UIKit

protocol PlayerMorphContaining: AnyObject {
    func collapseAndPush(_ viewController: UIViewController)
    func requestCollapse()
}

private enum MorphState {
    case dock
    case dragging
    case settling
    case full
}

private enum MorphTuning {
    static let commitProgress: CGFloat = 0.18
    static let commitVelocity: CGFloat = 900
    static let springStiffness: CGFloat = 240
    static let springDamping: CGFloat = 28
    static let reduceMotionDuration: CFTimeInterval = 0.24
    static let dockCorner: CGFloat = 16
    static let fullCorner: CGFloat = 44
    static let dockHeight: CGFloat = 56
    static let dockInset: CGFloat = 12
    static let dockBottomGap: CGFloat = 4
    static let proxyDockCorner: CGFloat = 16
    static let proxyFullCorner: CGFloat = 20
}

/// A window-level overlay whose empty regions pass touches through to the app
/// beneath it while the player is docked, and captures the whole screen once
/// the player is expanding or expanded.
private final class OverlayView: UIView {
    var capturesEverything = false
    var dockRect: CGRect = .zero

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if capturesEverything { return hit }
        return dockRect.contains(point) ? hit : nil
    }
}

/// Hosts the mini-player dock and the full Now Playing screen as two ends of a
/// single continuous morph. A normalized `t ∈ [0,1]` drives the card's frame,
/// corner radius, chrome cross-fades, and a flying artwork proxy; the same
/// interruptible, velocity-seeded spring settles either direction, with a soft
/// haptic on crossing the commit threshold and a rigid one when it locks in.
final class PlayerContainerViewController: UIViewController, PlayerMorphContaining {

    let miniPlayer = MiniPlayerView()
    private let npc = NowPlayingViewController()

    private let cardView = UIView()
    private let cardBackdrop = UIView()
    private let cardShadowView = UIView()
    private let proxyView = UIImageView()

    private var topConstraint: NSLayoutConstraint!
    private var bottomConstraint: NSLayoutConstraint!
    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!

    private var state: MorphState = .dock
    private var currentT: CGFloat = 0
    private var sessionStartTerminal: MorphState = .dock
    private var pastThreshold = false
    private var panBaseT: CGFloat = 0

    private var dockTopConstant: CGFloat = 0
    private var dockBottomConstant: CGFloat = 0
    private var travelDistance: CGFloat = 1
    private var dockArtRect: CGRect = .zero
    private var fullArtRect: CGRect = .zero

    private var displayLink: CADisplayLink?
    private var springVelocity: CGFloat = 0
    private var springTarget: CGFloat = 0
    private var lastTick: CFTimeInterval = 0
    private var linearStart: CFTimeInterval = 0
    private var linearFrom: CGFloat = 0
    private var isLinearSettle = false

    private var dockVisible = false
    private var isApplyingLayout = false
    private var onSettleToDock: (() -> Void)?
    private var fullArtCornerRadius: CGFloat = MorphTuning.proxyFullCorner

    var onRequestPush: ((UIViewController) -> Void)?
    var onMorphProgress: ((CGFloat) -> Void)?

    private var statusBarLight = false {
        didSet {
            guard statusBarLight != oldValue else { return }
            UIView.animate(withDuration: 0.2) { self.setNeedsStatusBarAppearanceUpdate() }
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        statusBarLight ? .lightContent : .default
    }

    private let thresholdGenerator = UIImpactFeedbackGenerator(style: .soft)
    private let lockInGenerator = UIImpactFeedbackGenerator(style: .soft)
    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    override func loadView() {
        view = OverlayView()
        view.backgroundColor = .clear
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupHierarchy()
        setupGesture()
        observeAudioPlayer()
        applyTerminalState(.dock)
        miniPlayer.isHidden = true
    }

    private func setupHierarchy() {
        cardShadowView.backgroundColor = .clear
        cardShadowView.layer.shadowColor = UIColor.black.cgColor
        cardShadowView.layer.shadowOffset = CGSize(width: 0, height: 4)
        cardShadowView.isUserInteractionEnabled = false
        view.addSubview(cardShadowView)

        cardView.clipsToBounds = true
        cardView.layer.cornerCurve = .continuous
        cardView.layer.cornerRadius = MorphTuning.dockCorner
        cardView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cardView)

        cardBackdrop.backgroundColor = .black
        cardBackdrop.alpha = 0
        cardBackdrop.isUserInteractionEnabled = false
        cardBackdrop.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(cardBackdrop)

        npc.isMorphEmbedded = true
        npc.morphContainer = self
        addChild(npc)
        npc.view.translatesAutoresizingMaskIntoConstraints = false
        npc.view.alpha = 0
        npc.view.isUserInteractionEnabled = false
        npc.view.accessibilityElementsHidden = true
        cardView.addSubview(npc.view)
        npc.didMove(toParent: self)

        miniPlayer.translatesAutoresizingMaskIntoConstraints = false
        miniPlayer.onTap = { [weak self] in self?.expand() }
        cardView.addSubview(miniPlayer)

        proxyView.contentMode = .scaleAspectFill
        proxyView.clipsToBounds = true
        proxyView.layer.cornerCurve = .continuous
        proxyView.isHidden = true
        proxyView.isUserInteractionEnabled = false
        view.addSubview(proxyView)

        topConstraint = cardView.topAnchor.constraint(equalTo: view.topAnchor)
        bottomConstraint = cardView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        leadingConstraint = cardView.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        trailingConstraint = cardView.trailingAnchor.constraint(equalTo: view.trailingAnchor)

        NSLayoutConstraint.activate([
            topConstraint, bottomConstraint, leadingConstraint, trailingConstraint,
            cardBackdrop.topAnchor.constraint(equalTo: cardView.topAnchor),
            cardBackdrop.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
            cardBackdrop.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            cardBackdrop.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            miniPlayer.topAnchor.constraint(equalTo: cardView.topAnchor),
            miniPlayer.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            miniPlayer.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            miniPlayer.heightAnchor.constraint(equalToConstant: MorphTuning.dockHeight),
            npc.view.topAnchor.constraint(equalTo: view.topAnchor),
            npc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            npc.view.widthAnchor.constraint(equalTo: view.widthAnchor),
            npc.view.heightAnchor.constraint(equalTo: view.heightAnchor),
        ])
    }

    private func setupGesture() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleMorphPan(_:)))
        pan.delegate = self
        pan.delaysTouchesEnded = false
        cardView.addGestureRecognizer(pan)
    }

    private func observeAudioPlayer() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(trackDidChange), name: AudioPlayer.trackDidChange, object: nil
        )
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !isApplyingLayout else { return }
        if state == .dock || state == .full {
            recomputeGeometry()
            setProgress(currentT)
        }
        updateOverlayCapture()
    }

    // MARK: Dock synchronization

    func syncDock(track: Track?, isPlaying: Bool) {
        if let track {
            miniPlayer.configure(with: track, isPlaying: isPlaying)
            showDock()
        } else {
            if state != .dock { collapse() }
            hideDock()
        }
    }

    private func showDock() {
        guard !dockVisible else { return }
        dockVisible = true
        miniPlayer.isHidden = false
        if state == .dock {
            miniPlayer.alpha = 0
            UIView.animate(withDuration: 0.3) { self.miniPlayer.alpha = 1 }
        }
        updateOverlayCapture()
    }

    private func hideDock() {
        guard dockVisible else { return }
        dockVisible = false
        UIView.animate(withDuration: 0.2, animations: {
            self.miniPlayer.alpha = 0
        }, completion: { _ in
            if !self.dockVisible { self.miniPlayer.isHidden = true }
        })
        updateOverlayCapture()
    }

    // MARK: Programmatic transitions

    func expand() {
        guard state == .dock else { return }
        beginMorphSession(from: .dock)
        startSpring(to: 1, initialPointVelocity: 0)
    }

    func collapse() {
        guard state == .full else { return }
        beginMorphSession(from: .full)
        startSpring(to: 0, initialPointVelocity: 0)
    }

    func requestCollapse() {
        collapse()
    }

    func expandShowingQueue() {
        npc.showQueueCenterState()
        expand()
    }

    func collapseAndPush(_ viewController: UIViewController) {
        guard state != .dock else {
            onRequestPush?(viewController)
            return
        }
        onSettleToDock = { [weak self] in self?.onRequestPush?(viewController) }
        beginMorphSession(from: .full)
        startSpring(to: 0, initialPointVelocity: 0)
    }

    // MARK: Geometry

    private func recomputeGeometry() {
        view.layoutIfNeeded()
        let height = view.bounds.height
        let safeBottom = view.safeAreaInsets.bottom
        dockTopConstant = height - safeBottom - MorphTuning.dockBottomGap - MorphTuning.dockHeight
        dockBottomConstant = -(safeBottom + MorphTuning.dockBottomGap)
        travelDistance = max(dockTopConstant, 1)
        dockArtRect = CGRect(
            x: view.bounds.width - MorphTuning.dockInset - MorphTuning.dockHeight,
            y: dockTopConstant,
            width: MorphTuning.dockHeight,
            height: MorphTuning.dockHeight
        )
        fullArtRect = npc.artworkMorphFrame()
        fullArtCornerRadius = npc.artworkMorphCornerRadius
    }

    // MARK: Morph driver

    /// The single source of truth: maps `t` onto the card geometry, the chrome
    /// cross-fades, and the flying artwork proxy in one pass.
    private func setProgress(_ raw: CGFloat) {
        let t = min(max(raw, 0), 1)
        currentT = t

        isApplyingLayout = true
        topConstraint.constant = lerp(dockTopConstant, 0, t)
        bottomConstraint.constant = lerp(dockBottomConstant, 0, t)
        leadingConstraint.constant = lerp(MorphTuning.dockInset, 0, t)
        trailingConstraint.constant = lerp(-MorphTuning.dockInset, 0, t)
        view.layoutIfNeeded()
        isApplyingLayout = false

        let dockFade = smoothstep(t, 0, 0.22)
        cardBackdrop.alpha = dockFade
        miniPlayer.alpha = dockVisible ? (1 - dockFade) : 0
        npc.view.alpha = smoothstep(t, 0.12, 0.72)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let cornerRadius = lerp(MorphTuning.dockCorner, MorphTuning.fullCorner, t)
        cardView.layer.cornerRadius = cornerRadius
        cardShadowView.frame = cardView.frame
        cardShadowView.layer.shadowPath = UIBezierPath(
            roundedRect: cardShadowView.bounds, cornerRadius: cornerRadius
        ).cgPath
        cardShadowView.layer.shadowOpacity = Float(lerp(0.18, 0, dockFade))
        cardShadowView.layer.shadowRadius = 12

        if reduceMotion {
            miniPlayer.setMorphArtworkHidden(false)
            npc.setArtworkHiddenForMorph(false)
        } else {
            proxyView.frame = interpolate(dockArtRect, fullArtRect, t)
            proxyView.layer.cornerRadius = lerp(MorphTuning.proxyDockCorner, fullArtCornerRadius, t)
            proxyView.layer.maskedCorners = t < 0.03
                ? [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
                : [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        }
        CATransaction.commit()

        onMorphProgress?(t)
        updateThresholdTick()
    }

    private func updateThresholdTick() {
        guard state == .dragging else { return }
        let progress = sessionStartTerminal == .dock ? currentT : (1 - currentT)
        let past = progress >= MorphTuning.commitProgress
        guard past != pastThreshold else { return }
        pastThreshold = past
        thresholdGenerator.impactOccurred(intensity: past ? 1 : 0.7)
        thresholdGenerator.prepare()
    }

    // MARK: Session lifecycle

    private func beginMorphSession(from terminal: MorphState) {
        sessionStartTerminal = terminal
        pastThreshold = (terminal == .dock ? currentT : (1 - currentT)) >= MorphTuning.commitProgress
        recomputeGeometry()
        thresholdGenerator.prepare()
        lockInGenerator.prepare()
        npc.setBackdropActive(true)
        if !reduceMotion {
            applyProxyArtwork()
        }
        npc.view.isUserInteractionEnabled = false
        miniPlayer.isUserInteractionEnabled = false
        view.isUserInteractionEnabled = true
        (view as? OverlayView)?.capturesEverything = true
        setProgress(currentT)
    }

    /// Re-reads the real artwork's frame so the proxy targets where the artwork
    /// actually is now, not where it was when the session began — any relayout
    /// during the flight is absorbed instead of popping at the handoff.
    private func refreshFullArtTarget(context: String) {
        let fresh = npc.artworkMorphFrame()
        let drift = max(
            abs(fresh.midX - fullArtRect.midX) + abs(fresh.midY - fullArtRect.midY),
            abs(fresh.width - fullArtRect.width)
        )
        if drift > 0.5 {
            AppLogger.info(
                "Morph art target drift \(String(format: "%.1f", drift))pt at \(context): \(fullArtRect) -> \(fresh)",
                category: .ui
            )
        }
        fullArtRect = fresh
        fullArtCornerRadius = npc.artworkMorphCornerRadius
    }

    private func endMorphSession(at terminal: MorphState) {
        let landedFull = terminal == .full
        if landedFull, !reduceMotion {
            refreshFullArtTarget(context: "handoff")
        }
        state = terminal
        setProgress(landedFull ? 1 : 0)
        statusBarLight = landedFull
        proxyView.isHidden = true
        npc.setArtworkHiddenForMorph(!landedFull)
        miniPlayer.setMorphArtworkHidden(landedFull)
        npc.view.isUserInteractionEnabled = landedFull
        npc.view.accessibilityElementsHidden = !landedFull
        miniPlayer.isUserInteractionEnabled = !landedFull
        view.accessibilityViewIsModal = landedFull
        npc.setBackdropActive(landedFull)
        updateOverlayCapture()
        if terminal != sessionStartTerminal {
            lockInGenerator.impactOccurred(intensity: 1)
        }
        UIAccessibility.post(notification: .screenChanged, argument: landedFull ? npc.view : miniPlayer)
        AppLogger.info("Player morph settled -> \(landedFull ? "full" : "dock")", category: .ui)
        if !landedFull, let settle = onSettleToDock {
            onSettleToDock = nil
            settle()
        }
    }

    private func applyTerminalState(_ terminal: MorphState) {
        state = terminal
        recomputeGeometry()
        setProgress(terminal == .full ? 1 : 0)
        let landedFull = terminal == .full
        statusBarLight = landedFull
        npc.view.isUserInteractionEnabled = landedFull
        npc.view.accessibilityElementsHidden = !landedFull
        miniPlayer.isUserInteractionEnabled = !landedFull
        view.accessibilityViewIsModal = landedFull
        npc.setBackdropActive(landedFull)
        updateOverlayCapture()
    }

    private func updateOverlayCapture() {
        guard let overlay = view as? OverlayView else { return }
        overlay.capturesEverything = state != .dock
        overlay.dockRect = dockVisible ? cardView.frame : .zero
    }

    // MARK: Pan handling

    @objc private func handleMorphPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view).y
        let velocity = gesture.velocity(in: view).y
        switch gesture.state {
        case .began:
            let origin: MorphState
            if state == .settling {
                stopDisplayLink()
                origin = springTarget >= 0.5 ? .dock : .full
            } else {
                origin = currentT <= 0.5 ? .dock : .full
            }
            onSettleToDock = nil
            beginMorphSession(from: origin)
            state = .dragging
            panBaseT = currentT
        case .changed:
            setProgress(panBaseT - translation / travelDistance)
        case .ended, .cancelled, .failed:
            settle(velocity: velocity)
        default:
            break
        }
    }

    private func settle(velocity: CGFloat) {
        let expanding = sessionStartTerminal == .dock
        let progress = expanding ? currentT : (1 - currentT)
        let velocityTowardOpposite = expanding ? -velocity : velocity
        let commit: Bool
        if abs(velocity) > MorphTuning.commitVelocity {
            commit = velocityTowardOpposite > 0
        } else {
            commit = progress >= MorphTuning.commitProgress
        }
        let target: CGFloat = expanding ? (commit ? 1 : 0) : (commit ? 0 : 1)
        startSpring(to: target, initialPointVelocity: velocity)
    }

    // MARK: Settle animation

    private func startSpring(to target: CGFloat, initialPointVelocity: CGFloat) {
        if target == 1 {
            refreshFullArtTarget(context: "settle start")
        }
        state = .settling
        springTarget = target
        springVelocity = travelDistance > 0 ? -initialPointVelocity / travelDistance : 0
        updateOverlayCapture()
        if reduceMotion {
            startLinearSettle(to: target)
            return
        }
        isLinearSettle = false
        lastTick = CACurrentMediaTime()
        startDisplayLink(#selector(springTick))
    }

    private func startLinearSettle(to target: CGFloat) {
        isLinearSettle = true
        linearStart = CACurrentMediaTime()
        linearFrom = currentT
        springTarget = target
        startDisplayLink(#selector(linearTick))
    }

    @objc private func springTick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 1.0 / 30.0)
        lastTick = now
        let displacement = currentT - springTarget
        let force = -MorphTuning.springStiffness * displacement - MorphTuning.springDamping * springVelocity
        springVelocity += force * CGFloat(dt)
        let next = currentT + springVelocity * CGFloat(dt)
        if abs(displacement) < 0.001, abs(springVelocity) < 0.02 {
            finishSettle(at: springTarget)
            return
        }
        setProgress(next)
    }

    @objc private func linearTick() {
        let progress = min((CACurrentMediaTime() - linearStart) / MorphTuning.reduceMotionDuration, 1)
        setProgress(lerp(linearFrom, springTarget, CGFloat(progress)))
        if progress >= 1 { finishSettle(at: springTarget) }
    }

    private func finishSettle(at target: CGFloat) {
        stopDisplayLink()
        endMorphSession(at: target >= 0.5 ? .full : .dock)
    }

    private func startDisplayLink(_ selector: Selector) {
        stopDisplayLink()
        let link = CADisplayLink(target: self, selector: selector)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func trackDidChange() {
        guard state == .dragging || state == .settling, !reduceMotion else { return }
        applyProxyArtwork()
    }

    /// Points the flying proxy at the current artwork and hides the real
    /// artwork views only when there is a real image to fly, so a placeholder
    /// glyph stays visible for the whole morph instead of blanking out.
    private func applyProxyArtwork() {
        let art = AudioPlayer.shared.currentTrack?.artwork ?? miniPlayer.currentArtwork
        let hasArt = art != nil
        proxyView.image = art
        proxyView.isHidden = !hasArt
        miniPlayer.setMorphArtworkHidden(hasArt)
        npc.setArtworkHiddenForMorph(hasArt)
    }

    // MARK: Interpolation helpers

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    private func smoothstep(_ x: CGFloat, _ edge0: CGFloat, _ edge1: CGFloat) -> CGFloat {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private func interpolate(_ from: CGRect, _ to: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: lerp(from.minX, to.minX, t),
            y: lerp(from.minY, to.minY, t),
            width: lerp(from.width, to.width, t),
            height: lerp(from.height, to.height, t)
        )
    }
}

extension PlayerContainerViewController: UIGestureRecognizerDelegate {

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        switch state {
        case .dragging, .settling:
            return true
        case .dock:
            let drag = dominantDrag(of: pan)
            return abs(drag.y) > abs(drag.x) && drag.y < 0 && dockVisible
        case .full:
            let drag = dominantDrag(of: pan)
            return abs(drag.y) > abs(drag.x) && drag.y > 0
                && npc.morphCollapseAllowed(at: pan.location(in: npc.view))
        }
    }

    /// Direction from accumulated translation rather than instantaneous
    /// velocity: at recognition time velocity is often (0,0) for a slow drag,
    /// which used to refuse legitimate downward swipes and let the horizontal
    /// track-change pan steal the touch.
    private func dominantDrag(of pan: UIPanGestureRecognizer) -> CGPoint {
        let translation = pan.translation(in: view)
        if hypot(translation.x, translation.y) > 2 { return translation }
        return pan.velocity(in: view)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        other.view is UIScrollView
    }
}
