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

    static func showImportOutcome(_ outcome: LibraryImportOutcome, in window: NSWindow?) {
        if outcome.failed == 0 {
            show("Imported \(outcome.imported) item\(outcome.imported == 1 ? "" : "s")", style: .success, in: window)
        } else if outcome.imported == 0 {
            show("Import failed — couldn't copy into the library folder.", style: .error, in: window)
        } else {
            show("Imported \(outcome.imported), \(outcome.failed) failed — check the library folder's permissions.", style: .error, in: window)
        }
    }

    static func show(_ message: String, style: Style = .info, in window: NSWindow?) {
        guard let contentView = window?.contentView else { return }
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
        currentToast = toast

        toast.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            toast.animator().alphaValue = 1
        }

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
}
