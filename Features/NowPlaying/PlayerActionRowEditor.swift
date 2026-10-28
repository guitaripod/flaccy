import UIKit

/// The player's action row. It lays the capsules out itself, in one equal
/// row or two when the column is narrow, so a drag never has to take a control
/// out of the window: the touched view is the view being moved.
@MainActor
final class PlayerActionRowView: UIView {

    static let capsuleHeight: CGFloat = 44
    static let spacing: CGFloat = 8

    private var capsules: [PlayerAction: GlassCapsule] = [:]

    var order: [PlayerAction] = PlayerAction.allCases {
        didSet { setNeedsLayout() }
    }

    var wraps = false {
        didSet {
            guard wraps != oldValue else { return }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    /// The control following the finger, skipped by layout until it is dropped.
    var floating: PlayerAction? {
        didSet { setNeedsLayout() }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(
            width: UIView.noIntrinsicMetric,
            height: wraps ? Self.capsuleHeight * 2 + Self.spacing : Self.capsuleHeight
        )
    }

    func install(_ capsules: [PlayerAction: GlassCapsule]) {
        self.capsules = capsules
        for capsule in capsules.values {
            capsule.translatesAutoresizingMaskIntoConstraints = true
            capsule.autoresizingMask = []
            addSubview(capsule)
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for action in order where action != floating {
            capsules[action]?.frame = frame(for: action)
        }
    }

    /// The slot an action occupies in the current arrangement, in this view's
    /// coordinates. Pure arithmetic, so a drop can head for a slot mid-animation.
    func frame(for action: PlayerAction) -> CGRect {
        var y: CGFloat = 0
        for row in rows() {
            let count = CGFloat(row.count)
            guard count > 0 else { continue }
            let slot = max((bounds.width - Self.spacing * (count - 1)) / count, 0)
            if let index = row.firstIndex(of: action) {
                let width = min(slot, Self.capsuleHeight)
                return CGRect(
                    x: CGFloat(index) * (slot + Self.spacing) + (slot - width) / 2,
                    y: y,
                    width: width,
                    height: Self.capsuleHeight
                )
            }
            y += Self.capsuleHeight + Self.spacing
        }
        return .zero
    }

    func rows() -> [[PlayerAction]] {
        wraps && order.count > 4 ? [Array(order.prefix(4)), Array(order.dropFirst(4))] : [order]
    }

    func center(of action: PlayerAction) -> CGPoint {
        let slot = frame(for: action)
        return CGPoint(x: slot.midX, y: slot.midY)
    }
}

/// Long-press editing for the player's action row. A hold starts a subtle
/// jiggle, dragging carries a control to another slot, and a tap anywhere ends
/// editing. The control itself travels with the finger while its slot opens in
/// the new place.
@MainActor
final class PlayerActionRowEditor: NSObject, UIGestureRecognizerDelegate {

    private enum Timing {
        static let press: TimeInterval = 0.45
        static let lift: TimeInterval = 0.16
        static let reorder: TimeInterval = 0.2
        static let drop: TimeInterval = 0.3
    }

    private static let jiggleKey = "player.actionRow.jiggle"
    private static let maxAngle: Float = 0.019

    private let container: PlayerActionRowView
    private let host: UIView
    private let capsules: [PlayerAction: GlassCapsule]
    private let controls: [PlayerAction: UIView]
    private let store: PlayerActionOrderStore
    private let feedback = UIImpactFeedbackGenerator(style: .medium)
    private let selection = UISelectionFeedbackGenerator()
    private let shield = UIView()

    private(set) var order: PlayerActionOrder
    private(set) var isEditing = false
    var onOrderChanged: (() -> Void)?

    private var grabbedAction: PlayerAction?
    private var grabOffset: CGPoint = .zero

    private lazy var press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    private lazy var exitTap = UITapGestureRecognizer(target: self, action: #selector(endEditing))

    init(
        container: PlayerActionRowView,
        host: UIView,
        capsules: [PlayerAction: GlassCapsule],
        controls: [PlayerAction: UIView],
        store: PlayerActionOrderStore = .shared
    ) {
        self.container = container
        self.host = host
        self.capsules = capsules
        self.controls = controls
        self.store = store
        self.order = store.order
        super.init()
        container.install(capsules)
        container.order = order.actions
        setupGestures()
        installAccessibilityMoves()
    }

    var orderedControls: [UIView] {
        order.actions.compactMap { controls[$0] }
    }

    /// Arranges the capsules from the model, splitting into two equal rows when
    /// the column is too narrow for seven round capsules.
    func applyLayout(wraps: Bool) {
        if isEditing {
            endEditing()
        }
        container.wraps = wraps
        container.order = order.actions
        container.setNeedsLayout()
    }

    /// Moves a control for VoiceOver, whose focus ring has no drag.
    func move(_ action: PlayerAction, by offset: Int) -> Bool {
        guard let index = order.actions.firstIndex(of: action) else { return false }
        let destination = index + offset
        guard order.actions.indices.contains(destination) else { return false }
        order = order.moving(from: index, to: destination)
        store.order = order
        container.order = order.actions
        UIView.animate(withDuration: Timing.reorder, delay: 0, options: [.beginFromCurrentState]) {
            self.container.layoutIfNeeded()
        }
        onOrderChanged?()
        selection.selectionChanged()
        return true
    }

    func beginEditing() {
        guard !isEditing else { return }
        isEditing = true
        pan.isEnabled = true
        exitTap.isEnabled = true
        installShield()
        startJiggle()
        feedback.impactOccurred()
    }

    @objc func endEditing() {
        guard isEditing else { return }
        finishDrag()
        isEditing = false
        pan.isEnabled = false
        exitTap.isEnabled = false
        shield.removeFromSuperview()
        stopJiggle()
    }

    private func setupGestures() {
        press.minimumPressDuration = Timing.press
        press.allowableMovement = 12
        press.cancelsTouchesInView = true
        press.delegate = self

        pan.cancelsTouchesInView = true
        pan.delegate = self
        pan.isEnabled = false

        exitTap.cancelsTouchesInView = true
        exitTap.delegate = self
        exitTap.isEnabled = false

        container.addGestureRecognizer(press)
        container.addGestureRecognizer(pan)
        host.addGestureRecognizer(exitTap)
    }

    private func installAccessibilityMoves() {
        for (action, control) in controls {
            control.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: String(localized: "Move earlier")) { [weak self] _ in
                    self?.move(action, by: -1) ?? false
                },
                UIAccessibilityCustomAction(name: String(localized: "Move later")) { [weak self] _ in
                    self?.move(action, by: 1) ?? false
                },
            ]
        }
    }

    /// Sits above the capsules and below the control being dragged, so a tap
    /// while editing reaches the exit gesture instead of toggling a control.
    private func installShield() {
        guard shield.superview == nil else {
            container.bringSubviewToFront(shield)
            return
        }
        shield.translatesAutoresizingMaskIntoConstraints = false
        shield.backgroundColor = .clear
        shield.isAccessibilityElement = false
        container.addSubview(shield)
        container.bringSubviewToFront(shield)
        NSLayoutConstraint.activate([
            shield.topAnchor.constraint(equalTo: container.topAnchor),
            shield.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            shield.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            shield.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    @objc private func handlePress(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: container)
        switch gesture.state {
        case .began:
            beginEditing()
            if let action = capsule(at: point) {
                beginDrag(action, at: point)
            }
        case .changed:
            updateDrag(to: point)
        case .ended, .cancelled, .failed:
            finishDrag()
        default:
            break
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: container)
        switch gesture.state {
        case .began:
            if let action = capsule(at: point) {
                beginDrag(action, at: point)
            }
        case .changed:
            updateDrag(to: point)
        case .ended, .cancelled, .failed:
            finishDrag()
        default:
            break
        }
    }

    private func beginDrag(_ action: PlayerAction, at point: CGPoint) {
        guard grabbedAction == nil, let capsule = capsules[action] else { return }
        grabbedAction = action
        let frame = container.frame(for: action)
        grabOffset = CGPoint(x: point.x - frame.midX, y: point.y - frame.midY)
        container.floating = action
        container.bringSubviewToFront(capsule)
        capsule.layer.zPosition = 1
        capsule.layer.shadowColor = UIColor.black.cgColor
        capsule.layer.shadowOpacity = 0.28
        capsule.layer.shadowRadius = 14
        capsule.layer.shadowOffset = CGSize(width: 0, height: 8)
        UIView.animate(withDuration: Timing.lift, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            capsule.transform = CGAffineTransform(scaleX: 1.07, y: 1.07)
        }
    }

    private func updateDrag(to point: CGPoint) {
        guard let action = grabbedAction, let capsule = capsules[action] else { return }
        capsule.center = CGPoint(x: point.x - grabOffset.x, y: point.y - grabOffset.y)
        reorder(toward: point, dragged: action)
    }

    private func reorder(toward point: CGPoint, dragged: PlayerAction) {
        guard let neighbor = nearestSlot(to: point) else { return }
        let after = point.x > container.center(of: neighbor).x
        var actions = order.actions
        guard let draggedIndex = actions.firstIndex(of: dragged),
              let neighborIndex = actions.firstIndex(of: neighbor) else { return }
        actions.remove(at: draggedIndex)
        actions.insert(dragged, at: min(neighborIndex + (after ? 1 : 0), actions.count))
        let next = PlayerActionOrder(actions: actions)
        guard next != order else { return }

        order = next
        container.order = order.actions
        selection.selectionChanged()
        UIView.animate(
            withDuration: Timing.reorder,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.container.layoutIfNeeded()
        }
    }

    private func finishDrag() {
        guard let action = grabbedAction, let capsule = capsules[action] else { return }
        grabbedAction = nil
        container.floating = nil
        container.bringSubviewToFront(shield)
        capsule.layer.zPosition = 0
        capsule.layer.shadowOpacity = 0
        UIView.animate(
            withDuration: Timing.drop,
            delay: 0,
            usingSpringWithDamping: 0.82,
            initialSpringVelocity: 0.3,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            capsule.transform = .identity
            self.container.layoutIfNeeded()
        }
        store.order = order
        restartJiggleIfNeeded()
    }

    private func capsule(at point: CGPoint) -> PlayerAction? {
        guard grabbedAction == nil else { return nil }
        return order.actions.first { action in
            capsules[action]?.frame.contains(point) == true
        }
    }

    private func nearestSlot(to point: CGPoint) -> PlayerAction? {
        var best: (action: PlayerAction, distance: CGFloat)?
        for action in order.actions where action != grabbedAction {
            let center = container.center(of: action)
            let distance = hypot(center.x - point.x, center.y - point.y)
            if best == nil || distance < best!.distance {
                best = (action, distance)
            }
        }
        return best?.action
    }

    private func startJiggle() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        for (index, action) in order.actions.enumerated() {
            guard let capsule = capsules[action] else { continue }
            let angle = PlayerActionRowEditor.maxAngle * Float(index.isMultiple(of: 2) ? 1 : -1)
            let jiggle = CABasicAnimation(keyPath: "transform.rotation.z")
            jiggle.fromValue = -angle
            jiggle.toValue = angle
            jiggle.duration = 0.18
            jiggle.autoreverses = true
            jiggle.repeatCount = .infinity
            jiggle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            jiggle.timeOffset = Double.random(in: 0..<0.36)
            capsule.layer.add(jiggle, forKey: Self.jiggleKey)
        }
    }

    private func stopJiggle() {
        for capsule in capsules.values {
            capsule.layer.removeAnimation(forKey: Self.jiggleKey)
        }
    }

    private func restartJiggleIfNeeded() {
        guard isEditing else { return }
        stopJiggle()
        startJiggle()
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === exitTap {
            return isEditing && grabbedAction == nil
        }
        if gestureRecognizer === press {
            return !isEditing
        }
        if gestureRecognizer === pan {
            return isEditing && grabbedAction == nil
        }
        return true
    }
}
