#if DEBUG && targetEnvironment(simulator)
import UIKit

/// A DEBUG-only stand-in for a window of another size, because the Simulator
/// can neither rotate an iPad nor resize its window from the command line.
/// `FLACCY_WINDOW_SIZE=WxH` hosts the app at exactly that size, scaled down to
/// fit the screen when it is bigger, with the horizontal size class an iPad
/// window that wide gets.
final class DebugWindowFrame: UIViewController {

    private let content: UIViewController
    private let size: CGSize

    static func wrapIfRequested(_ content: UIViewController) -> UIViewController {
        guard let size = requestedSize else { return content }
        return DebugWindowFrame(content: content, size: size)
    }

    static var requestedSize: CGSize? {
        let parts = (ProcessInfo.processInfo.environment["FLACCY_WINDOW_SIZE"] ?? "")
            .split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }

    private init(content: UIViewController, size: CGSize) {
        self.content = content
        self.size = size
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var childForStatusBarStyle: UIViewController? { content }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .darkGray
        content.traitOverrides.horizontalSizeClass = size.width >= 520 ? .regular : .compact
        addChild(content)
        view.addSubview(content.view)
        content.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let room = view.bounds.inset(by: UIEdgeInsets(top: view.safeAreaInsets.top, left: 0, bottom: 0, right: 0))
        let scale = min(1, room.width / size.width, room.height / size.height)
        content.view.transform = .identity
        content.view.bounds = CGRect(origin: .zero, size: size)
        content.view.center = CGPoint(x: room.midX, y: room.midY)
        content.view.transform = CGAffineTransform(scaleX: scale, y: scale)
    }
}
#endif
