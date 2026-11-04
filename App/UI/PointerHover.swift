import UIKit

extension UIView {

    /// Lifts this cover or card toward an iPad pointer resting on it, in the
    /// shape it is drawn with. Touch never sees it.
    func liftsUnderPointer(cornerRadius: CGFloat) {
        hoverStyle = UIHoverStyle(effect: .lift, shape: .rect(cornerRadius: cornerRadius))
    }

    /// Washes this row or tile with the system highlight while an iPad pointer
    /// rests on it. Touch never sees it.
    func highlightsUnderPointer(cornerRadius: CGFloat) {
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: cornerRadius))
    }
}
