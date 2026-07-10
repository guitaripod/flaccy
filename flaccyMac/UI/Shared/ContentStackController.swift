import AppKit

/// Drill-down container for a sidebar section: hosts a root controller and a
/// stack of detail controllers pushed over it, with a floating glass back
/// button and a slide transition (crossfade under Reduce Motion).
final class ContentStackController: NSViewController {

    private(set) var stack: [NSViewController] = []
    private let backButton = GlassCapsuleButton(title: "Back", symbolName: "chevron.left")

    init(root: NSViewController) {
        super.init(nibName: nil, bundle: nil)
        stack = [root]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        guard let root = stack.first else { return }
        addChild(root)
        root.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root.view)
        pin(root.view)

        backButton.onClick = { [weak self] in self?.pop() }
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.isHidden = true
        view.addSubview(backButton)
        NSLayoutConstraint.activate([
            backButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            backButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
        ])
    }

    var topViewController: NSViewController? {
        stack.last
    }

    func push(_ controller: NSViewController) {
        guard let current = stack.last else { return }
        stack.append(controller)
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view, positioned: .below, relativeTo: backButton)
        pin(controller.view)
        transition(from: current, to: controller, forward: true)
        updateBackButton()
    }

    func pop() {
        guard stack.count > 1 else { return }
        let outgoing = stack.removeLast()
        guard let incoming = stack.last else { return }
        transition(from: outgoing, to: incoming, forward: false) { [weak self] in
            outgoing.view.removeFromSuperview()
            outgoing.removeFromParent()
            self?.updateBackButton()
        }
        updateBackButton()
    }

    func popToRoot() {
        while stack.count > 1 {
            let outgoing = stack.removeLast()
            outgoing.view.removeFromSuperview()
            outgoing.removeFromParent()
        }
        stack.first?.view.isHidden = false
        updateBackButton()
    }

    override func cancelOperation(_ sender: Any?) {
        if stack.count > 1 {
            pop()
        } else {
            super.cancelOperation(sender)
        }
    }

    private func updateBackButton() {
        backButton.isHidden = stack.count < 2
    }

    private func transition(
        from outgoing: NSViewController,
        to incoming: NSViewController,
        forward: Bool,
        completion: (() -> Void)? = nil
    ) {
        incoming.view.isHidden = false
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            outgoing.view.isHidden = true
            completion?()
            settleTopViewController()
            return
        }
        let width = view.bounds.width
        let incomingStart = forward ? width * 0.25 : -width * 0.25
        incoming.view.alphaValue = 0
        incoming.view.layer?.transform = CATransform3DMakeTranslation(incomingStart, 0, 0)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            incoming.view.alphaValue = 1
            incoming.view.layer?.transform = CATransform3DIdentity
            outgoing.view.alphaValue = 0
        }, completionHandler: { [weak self, weak outgoing] in
            guard let self else { return }
            if let outgoing, outgoing !== self.stack.last {
                outgoing.view.isHidden = true
                outgoing.view.alphaValue = 1
            }
            completion?()
            self.settleTopViewController()
        })
    }

    /// Overlapping transitions (push immediately followed by pop) fire stale
    /// completions against views that have since become the top again; always
    /// forcing the top view visible makes those completions harmless.
    private func settleTopViewController() {
        guard let top = stack.last else { return }
        top.view.isHidden = false
        top.view.alphaValue = 1
        top.view.layer?.transform = CATransform3DIdentity
    }

    private func pin(_ subview: NSView) {
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: view.topAnchor),
            subview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            subview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
