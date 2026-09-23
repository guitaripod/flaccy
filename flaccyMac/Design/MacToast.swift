import AppKit

/// Transient glass pill dropped in from the top of the window, mirroring the
/// iOS ToastView language: SF Symbol + message, auto-dismissed, one at a time.
@MainActor
enum MacToast {

    enum Style {
        case info
        case success
        case error

        var symbolName: String {
            switch self {
            case .info: "info.circle.fill"
            case .success: "checkmark.circle.fill"
            case .error: "exclamationmark.triangle.fill"
            }
        }

        var tint: NSColor {
            switch self {
            case .info: .secondaryLabelColor
            case .success: .systemGreen
            case .error: .systemRed
            }
        }
    }

    private static var currentToast: NSView?

    /// The import's running count, retitled in place until the shared
    /// sentence reports how it ended.
    static func showImport(in window: NSWindow?) -> Live {
        showLive(ImportOutcomeCopy.scanning, in: window)
    }

    static func show(_ message: String, style: Style = .info, in window: NSWindow?) {
        guard let toast = makeToast(message, style: style, in: window)?.toast else { return }
        present(toast)

        Task { [weak toast] in
            try? await Task.sleep(for: .seconds(2.4))
            guard let toast, toast === currentToast else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                toast.animator().alphaValue = 0
            }, completionHandler: {
                toast.removeFromSuperview()
                if currentToast === toast { currentToast = nil }
            })
        }
    }

    /// A toast that stays up while work runs and is retitled in place — its
    /// digits monospaced so a running count does not jitter the pill — until
    /// `finish` hands over to the ordinary toast that reports the result. Any
    /// other toast shown meanwhile simply replaces it.
    static func showLive(_ message: String, in window: NSWindow?) -> Live {
        let made = makeToast(message, style: .info, in: window)
        if let made {
            made.label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            present(made.toast)
        }
        return Live(toast: made?.toast, label: made?.label, window: window)
    }

    final class Live {
        private weak var toast: NSView?
        private weak var label: NSTextField?
        private weak var window: NSWindow?
        private var isFinished = false

        fileprivate init(toast: NSView?, label: NSTextField?, window: NSWindow?) {
            self.toast = toast
            self.label = label
            self.window = window
        }

        func update(_ message: String) {
            guard !isFinished else { return }
            label?.stringValue = message
        }

        func update(_ progress: LibraryImportProgress) {
            update(ImportOutcomeCopy.progress(progress))
        }

        func finish(reporting outcome: LibraryImportOutcome) {
            let report = ImportOutcomeCopy.report(outcome)
            finish(report.message, style: report.isFailure ? .error : (report.isNoOp ? .info : .success))
        }

        func finish(_ message: String, style: Style) {
            guard !isFinished else { return }
            isFinished = true
            if let toast, toast === MacToast.currentToast {
                toast.removeFromSuperview()
                MacToast.currentToast = nil
            }
            MacToast.show(message, style: style, in: window)
        }
    }

    private static func present(_ toast: NSView) {
        currentToast = toast
        toast.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            toast.animator().alphaValue = 1
        }
    }

    private static func makeToast(
        _ message: String, style: Style, in window: NSWindow?
    ) -> (toast: NSView, label: NSTextField)? {
        guard let contentView = window?.contentView else { return nil }
        currentToast?.removeFromSuperview()

        let icon = NSImageView(image: NSImage(
            systemSymbolName: style.symbolName, accessibilityDescription: nil
        ) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        icon.contentTintColor = style.tint

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

        let toast = MacLiquidGlass.surface(hosting: stack, cornerRadius: 17)
        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.wantsLayer = true
        toast.layer?.shadowColor = NSColor.black.withAlphaComponent(0.3).cgColor
        toast.layer?.shadowOffset = CGSize(width: 0, height: -4)
        toast.layer?.shadowRadius = 14
        toast.layer?.shadowOpacity = 1

        contentView.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            toast.topAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor, constant: 12),
            toast.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, constant: -48),
        ])
        return (toast, label)
    }
}
