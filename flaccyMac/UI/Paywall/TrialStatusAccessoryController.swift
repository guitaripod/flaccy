import AppKit

/// Subtle titlebar pill showing where the trial stands; clicking it opens the
/// paywall. It turns orange for the last two days, names the welcome-back price
/// while that window is open, and hides entirely once a purchase lands.
final class TrialStatusAccessoryController: NSTitlebarAccessoryViewController {

    private static let initialWidth: CGFloat = 110
    private static let urgentAtDaysRemaining = 2

    private let pill = NSView()
    private let label = NSTextField(labelWithString: "")

    override func loadView() {
        layoutAttribute = .trailing

        pill.wantsLayer = true
        pill.layer?.cornerRadius = 10
        pill.layer?.cornerCurve = .continuous
        pill.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.initialWidth, height: 26))
        container.addSubview(pill)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -3),
            pill.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            pill.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            pill.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
        ])
        view = container

        let click = NSClickGestureRecognizer(target: self, action: #selector(openPaywall))
        pill.addGestureRecognizer(click)
        pill.toolTip = String(localized: "Get Flaccy Lifetime")
        applyTint(urgent: false)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self, selector: #selector(stateChanged), name: PurchaseManager.stateDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(stateChanged), name: PurchaseManager.customerInfoDidLoad, object: nil
        )
        stateChanged()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func stateChanged() {
        let manager = PurchaseManager.shared
        guard let line = PaywallCopy.pillLine(state: manager.state, lifetime: manager.lifetimeOfferToPresent) else {
            isHidden = true
            return
        }
        isHidden = false
        label.stringValue = line
        applyTint(urgent: Self.isUrgent(manager.state))
        sizeToPill()
    }

    private static func isUrgent(_ state: EntitlementState) -> Bool {
        guard case .trial(let daysRemaining) = state else { return false }
        return daysRemaining <= urgentAtDaysRemaining
    }

    private func applyTint(urgent: Bool) {
        let tint: NSColor = urgent ? .systemOrange : .controlAccentColor
        pill.layer?.backgroundColor = tint.withAlphaComponent(urgent ? 0.22 : 0.14).cgColor
        label.textColor = urgent ? .systemOrange : .secondaryLabelColor
    }

    /// A titlebar accessory is laid out by its view's *frame*, not by the
    /// constraints inside it: left at the zero width `NSView` starts with, the
    /// pill is in the window and unhidden and still draws nothing — and cannot
    /// be clicked. So the container is resized to the pill whenever its copy
    /// changes.
    private func sizeToPill() {
        view.layoutSubtreeIfNeeded()
        let width = view.fittingSize.width
        guard width > 0, abs(view.frame.width - width) > 0.5 else { return }
        view.setFrameSize(NSSize(width: width, height: view.frame.height))
    }

    @objc private func openPaywall() {
        PurchaseManager.shared.requestPaywall()
    }
}
