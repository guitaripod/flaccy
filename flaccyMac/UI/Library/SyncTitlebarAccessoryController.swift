import AppKit
import Combine
import FlaccyCore

/// A `sparkles` chip in the titlebar for exactly as long as the enrichment job
/// is working, and not one moment longer. Clicking it says what the job is
/// doing and offers the two things a reader can actually do about it.
///
/// It deliberately never appears for `needsEntitlement`: a trial-expired user is
/// told once, inside the Debut, and thereafter only in Settings — an unpaid
/// capability is not launch chrome.
final class SyncTitlebarAccessoryController: NSTitlebarAccessoryViewController {

    private static let initialWidth: CGFloat = 76

    private let pill = NSView()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var cancellable: AnyCancellable?
    private var progress: EnrichmentJobProgress = .idle

    override func loadView() {
        layoutAttribute = .trailing

        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
        pill.layer?.cornerRadius = 10
        pill.layer?.cornerCurve = .continuous
        pill.translatesAutoresizingMaskIntoConstraints = false

        icon.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 10.5, weight: .semibold)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        label.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = MacColors.secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(row)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.initialWidth, height: 26))
        container.addSubview(pill)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 9),
            row.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -9),
            row.topAnchor.constraint(equalTo: pill.topAnchor, constant: 3),
            row.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -3),
            pill.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            pill.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            pill.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
        ])
        view = container

        let click = NSClickGestureRecognizer(target: self, action: #selector(showMenu))
        pill.addGestureRecognizer(click)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        cancellable = MacLibrarySurfaceModel.shared.state
            .map(\.job)
            .removeDuplicates()
            .sink { [weak self] job in
                self?.render(job)
            }
        render(MacLibrarySurfaceModel.shared.state.value.job)
    }

    private func render(_ job: EnrichmentJobProgress) {
        progress = job
        switch job.activity {
        case .idle, .needsEntitlement:
            isHidden = true
        case .running:
            isHidden = false
            label.stringValue = EnrichmentJobCopy.detail(remaining: job.remaining)
            pill.toolTip = EnrichmentJobCopy.line(for: job)
        case .waitingForNetwork:
            isHidden = false
            label.stringValue = EnrichmentJobCopy.waitingForNetwork
            pill.toolTip = EnrichmentJobCopy.waitingForNetwork
        }
        view.setAccessibilityLabel(EnrichmentJobCopy.accessibilityValue(for: job))
        sizeToChip()
    }

    /// A titlebar accessory is laid out by its view's *frame*, not by the
    /// constraints inside it: left at the zero width `NSView` starts with, the
    /// chip is in the window and unhidden and still draws nothing. So the
    /// container is resized to the pill every time the copy in it changes.
    private func sizeToChip() {
        view.layoutSubtreeIfNeeded()
        let width = view.fittingSize.width
        guard width > 0, abs(view.frame.width - width) > 0.5 else { return }
        view.setFrameSize(NSSize(width: width, height: view.frame.height))
    }

    @objc private func showMenu() {
        let menu = NSMenu()
        let summary = NSMenuItem(title: EnrichmentJobCopy.line(for: progress), action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        menu.addItem(.separator())

        let artwork = menu.addItem(
            withTitle: EnrichmentJobCopy.findMissingArtwork,
            action: #selector(findMissingArtwork), keyEquivalent: ""
        )
        artwork.target = self

        let settings = menu.addItem(
            withTitle: EnrichmentJobCopy.openLibrarySettings,
            action: #selector(openLibrarySettings), keyEquivalent: ""
        )
        settings.target = self

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: pill.bounds.height + 4), in: pill)
    }

    @objc private func findMissingArtwork() {
        Task {
            await EnrichmentCoordinator.shared.retryExhausted(scope: .album)
            await EnrichmentCoordinator.shared.resume()
        }
        AppLogger.info("Titlebar chip requested a missing-artwork sweep", category: .content)
    }

    @objc private func openLibrarySettings() {
        NSApp.sendAction(#selector(MacAppDelegate.showLibrarySettings(_:)), to: nil, from: nil)
    }
}
