import AppKit
import FlaccyCore

/// The desktop face of a library scan: a floating status strip that names the
/// stage, counts what it has found, and fills a determinate bar. Same phases
/// and wording as iPhone, in the shape a window can carry while the user keeps
/// browsing.
final class MacScanStatusView: NSView {

    private let headline = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let background = NSVisualEffectView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        alphaValue = 0
        isHidden = true

        background.translatesAutoresizingMaskIntoConstraints = false
        background.material = .hudWindow
        background.blendingMode = .withinWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.cornerCurve = .continuous
        addSubview(background)

        headline.font = .systemFont(ofSize: 12, weight: .semibold)
        headline.textColor = .labelColor
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .right

        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
        bar.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [headline, detail])
        row.orientation = .horizontal
        row.distribution = .fill
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        headline.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [row, bar])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(String(localized: "Updating your library"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(progress: LibraryLoadProgress, fraction: Double) {
        headline.stringValue = LibraryLoadPhaseCopy.headline(for: progress.phase)
        detail.stringValue = LibraryLoadPhaseCopy.detail(for: progress)
        bar.isIndeterminate = !progress.isDeterminate
        if progress.isDeterminate {
            bar.stopAnimation(nil)
            bar.doubleValue = min(1, max(0, fraction))
        } else {
            bar.startAnimation(nil)
        }
        setAccessibilityValueDescription(
            LibraryLoadPhaseCopy.accessibilityValue(for: progress, fraction: fraction)
        )
    }

    func setVisible(_ visible: Bool) {
        guard visible != (alphaValue > 0) || isHidden == visible else { return }
        if visible { isHidden = false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.isHidden = self.alphaValue == 0
            if self.isHidden { self.bar.stopAnimation(nil) }
        }
    }
}
