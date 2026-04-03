import UIKit

protocol SonglinkShareable: UIViewController {}

extension SonglinkShareable {

    func shareTrackViaSonglink(title: String, artist: String, from sourceView: UIView) {
        Task {
            guard let result = await SonglinkService.shared.lookup(title: title, artist: artist) else {
                ToastView.show("Couldn't find this track on streaming platforms", in: sourceView, style: .error)
                return
            }

            UINotificationFeedbackGenerator().notificationOccurred(.success)
            presentStreamingLinks(result: result)
        }
    }

    func shareAlbumViaSonglink(title: String, artist: String, from sourceView: UIView) {
        Task {
            guard let result = await SonglinkService.shared.lookupAlbum(title: title, artist: artist) else {
                ToastView.show("Couldn't find this album on streaming platforms", in: sourceView, style: .error)
                return
            }

            UINotificationFeedbackGenerator().notificationOccurred(.success)
            presentStreamingLinks(result: result)
        }
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
