import UIKit

extension UIViewController {

    /// Points the popover an action sheet or share sheet becomes on an iPad at
    /// `source`, or centres it in `fallback` without an arrow when the source
    /// is gone. An iPad refuses to present either kind without an anchor; on
    /// an iPhone the sheet ignores it.
    func anchorPopover(at source: UIView?, fallback: UIView) {
        guard let popover = popoverPresentationController else { return }
        if let source, source.window != nil {
            popover.sourceView = source
            popover.sourceRect = source.bounds
        } else {
            popover.sourceView = fallback
            popover.sourceRect = CGRect(x: fallback.bounds.midX, y: fallback.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
    }
}
