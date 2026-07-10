import AppKit

/// Subtle titlebar pill showing remaining trial days; clicking it opens the
/// paywall. Hidden entirely once the lifetime unlock lands.
final class TrialStatusAccessoryController: NSTitlebarAccessoryViewController {

    private let pill = NSView()
    private let label = NSTextField(labelWithString: "")

    override func loadView() {
        layoutAttribute = .trailing

        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
        pill.layer?.cornerRadius = 10
        pill.layer?.cornerCurve = .continuous
        pill.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)

        let container = NSView()
        container.addSubview(pill)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -3),
            pill.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            pill.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            pill.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            container.heightAnchor.constraint(equalToConstant: 26),
        ])
        view = container

        let click = NSClickGestureRecognizer(target: self, action: #selector(openPaywall))
        pill.addGestureRecognizer(click)
        pill.toolTip = "Unlock Flaccy Lifetime"
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self, selector: #selector(stateChanged), name: PurchaseManager.stateDidChange, object: nil
        )
        stateChanged()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func stateChanged() {
        switch PurchaseManager.shared.state {
        case .purchased:
            isHidden = true
        case .trial(let daysRemaining):
            isHidden = false
            label.stringValue = daysRemaining == 1 ? "Trial · 1 day left" : "Trial · \(daysRemaining) days left"
        case .expired:
            isHidden = false
            label.stringValue = "Trial ended"
        }
    }

    @objc private func openPaywall() {
        PurchaseManager.shared.requestPaywall()
    }
}
