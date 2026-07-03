import UIKit

protocol SonglinkShareable: UIViewController {}

extension SonglinkShareable {

    func shareTrackViaSonglink(title: String, artist: String, from sourceView: UIView) {
        let overlay = showSonglinkLoading()
        Task {
            let result = await SonglinkService.shared.lookup(title: title, artist: artist)
            overlay.removeFromSuperview()
            guard let result else {
                ToastView.show("Couldn't find this track on streaming platforms", in: sourceView, style: .error)
                return
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            presentStreamingLinks(result: result)
        }
    }

    func shareAlbumViaSonglink(title: String, artist: String, from sourceView: UIView) {
        let overlay = showSonglinkLoading()
        Task {
            let result = await SonglinkService.shared.lookupAlbum(title: title, artist: artist)
            overlay.removeFromSuperview()
            guard let result else {
                ToastView.show("Couldn't find this album on streaming platforms", in: sourceView, style: .error)
                return
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            presentStreamingLinks(result: result)
        }
    }

    private func showSonglinkLoading() -> UIView {
        let overlay = UIView()
        overlay.translatesAutoresizingMaskIntoConstraints = false

        let blur = LiquidGlass.view(cornerRadius: 14)
        blur.translatesAutoresizingMaskIntoConstraints = false

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()

        let label = UILabel()
        label.text = "Finding links\u{2026}"
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [spinner, label])
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
