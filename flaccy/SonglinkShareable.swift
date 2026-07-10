import UIKit
import ObjectiveC

protocol SonglinkShareable: UIViewController {}

private final class SonglinkLookupHandle {
    let task: Task<Void, Never>

    init(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }

    deinit {
        task.cancel()
    }
}

private final class SonglinkLoadingOverlay: UIView {
    var onCancelTap: (() -> Void)?

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        onCancelTap?()
    }

    func dismiss() {
        onCancelTap = nil
        UIView.animate(withDuration: 0.2) {
            self.alpha = 0
        } completion: { _ in
            self.removeFromSuperview()
        }
    }
}

private var songlinkLookupHandleKey: UInt8 = 0

extension SonglinkShareable {

    func shareTrackViaSonglink(title: String, artist: String, from sourceView: UIView) {
        startSonglinkLookup(
            failureMessage: "Couldn't find this track on streaming platforms",
            sourceView: sourceView
        ) {
            await SonglinkService.shared.lookup(title: title, artist: artist)
        }
    }

    func shareAlbumViaSonglink(title: String, artist: String, from sourceView: UIView) {
        startSonglinkLookup(
            failureMessage: "Couldn't find this album on streaming platforms",
            sourceView: sourceView
        ) {
            await SonglinkService.shared.lookupAlbum(title: title, artist: artist)
        }
    }

    private var songlinkLookupHandle: SonglinkLookupHandle? {
        get { objc_getAssociatedObject(self, &songlinkLookupHandleKey) as? SonglinkLookupHandle }
        set { objc_setAssociatedObject(self, &songlinkLookupHandleKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Cancels any in-flight lookup, then runs a new one behind a tap-to-cancel
    /// loading overlay without retaining the presenting view controller.
    private func startSonglinkLookup(
        failureMessage: String,
        sourceView: UIView,
        lookup: @escaping () async -> SonglinkResult?
    ) {
        songlinkLookupHandle?.cancel()
        let overlay = showSonglinkLoading()
        let task = Task { [weak self, weak sourceView] in
            let result = await lookup()
            overlay.dismiss()
            guard !Task.isCancelled, let self else { return }
            guard let result else {
                if let sourceView {
                    ToastView.show(failureMessage, in: sourceView, style: .error)
                }
                return
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            self.presentStreamingLinks(result: result)
        }
        let handle = SonglinkLookupHandle(task: task)
        overlay.onCancelTap = { [weak overlay] in
            handle.cancel()
            overlay?.dismiss()
        }
        songlinkLookupHandle = handle
    }

    private func showSonglinkLoading() -> SonglinkLoadingOverlay {
        let overlay = SonglinkLoadingOverlay()
        overlay.translatesAutoresizingMaskIntoConstraints = false

        let blur = LiquidGlass.view(cornerRadius: 14)
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.isUserInteractionEnabled = false

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()

        let label = UILabel()
        label.text = "Finding links\u{2026}"
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabel

        let hint = UILabel()
        hint.text = "Tap to cancel"
        hint.font = .systemFont(ofSize: 11, weight: .regular)
        hint.textColor = .tertiaryLabel

        let textStack = UIStackView(arrangedSubviews: [label, hint])
        textStack.axis = .vertical
        textStack.spacing = 2

        let stack = UIStackView(arrangedSubviews: [spinner, textStack])
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        blur.contentView.addSubview(stack)
        overlay.addSubview(blur)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -20),
            blur.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            blur.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        ])

        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        overlay.alpha = 0
        UIView.animate(withDuration: 0.2) { overlay.alpha = 1 }

        return overlay
    }

    private func presentStreamingLinks(result: SonglinkResult) {
        let vc = StreamingLinksViewController(result: result)
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
        }

        var presenter: UIViewController = self
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        presenter.present(nav, animated: true)
    }
}
