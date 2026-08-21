import FlaccyCore
import UIKit

/// Hosts the Debut once the library underneath it has become browsable.
///
/// Act I earns the whole screen because there is genuinely nothing else to look
/// at. Everything after it is unbounded network work over a library the reader
/// can already use — and a showpiece that stands in front of a working app for
/// as long as the network feels like taking is an obstacle, however good it
/// looks. From that point the same view lives here, opened from the status
/// banner or raised once when the summary is ready, and dismissed like any
/// other sheet.
final class LibraryDebutSheetController: UIViewController {

    let debutView: LibraryDebutView

    init(debutView: LibraryDebutView) {
        self.debutView = debutView
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 28
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        debutView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(debutView)
        NSLayoutConstraint.activate([
            debutView.topAnchor.constraint(equalTo: view.topAnchor),
            debutView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            debutView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            debutView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
