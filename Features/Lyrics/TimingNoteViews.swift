import FlaccyCore
import UIKit

/// A button whose tap area is at least 44 pt tall however compact it is drawn.
final class TimingNoteChipButton: UIButton {

    static let minimumTapHeight: CGFloat = 44

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let missing = max(0, Self.minimumTapHeight - bounds.height)
        return bounds.insetBy(dx: 0, dy: -missing / 2).contains(point)
    }
}

/// The popover behind the timing note chip: what is missing from the lyrics'
/// timing and where better timing comes from.
final class TimingNoteViewController: UIViewController, UIPopoverPresentationControllerDelegate {

    static let contentWidth: CGFloat = 280
    static let padding: CGFloat = 16

    let kind: LyricsTimingNoteKind

    init(kind: LyricsTimingNoteKind) {
        self.kind = kind
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let title = UILabel()
        title.text = LyricsTimingNoteCopy.title(for: kind)
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = .label
        title.numberOfLines = 0
        title.accessibilityTraits = .header

        let body = UILabel()
        body.text = LyricsTimingNoteCopy.body(for: kind)
        body.font = .preferredFont(forTextStyle: .subheadline)
        body.adjustsFontForContentSizeCategory = true
        body.textColor = .secondaryLabel
        body.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [title, body])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.padding),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Self.padding),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Self.padding),
            stack.widthAnchor.constraint(equalToConstant: Self.contentWidth - 2 * Self.padding),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        preferredContentSize = view.systemLayoutSizeFitting(
            CGSize(width: Self.contentWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
    }

    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
        .none
    }
}
