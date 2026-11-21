import FlaccyCore
import ObjectiveC
import UIKit

/// How a theme reaches every label in the app, the system's own included: the
/// two setters a label's look goes through are intercepted, so the text color
/// the system calls "label" becomes the theme's and the system font becomes
/// the theme's face, wherever the label was made.
///
/// Nothing is intercepted until a theme other than Flaccy's own is first worn,
/// and under Flaccy's own every hook hands its argument straight through, so
/// the look every release shipped with is untouched.
@MainActor
enum ThemeHooks {

    private static var installed = false
    private static var dressing = false
    private static var faces = ThemeTypography.Faces()
    private static var epoch = 0

    private nonisolated(unsafe) static var baseFontKey: UInt8 = 0
    private nonisolated(unsafe) static var baseTextKey: UInt8 = 0
    private nonisolated(unsafe) static var epochKey: UInt8 = 0

    /// Starts dressing labels in `faces` and the theme's text colors, or stops
    /// when `dressing` is false. `epoch` marks the look, so a label that was
    /// off screen while it changed is brought up to date when it comes back.
    static func wear(dressing: Bool, faces: ThemeTypography.Faces, epoch: Int) {
        self.dressing = dressing
        self.faces = faces
        self.epoch = epoch
        if dressing { install() }
    }

    private static func exchange(_ type: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let from = class_getInstanceMethod(type, original),
              let to = class_getInstanceMethod(type, replacement) else { return }
        if class_addMethod(type, original, method_getImplementation(to), method_getTypeEncoding(to)) {
            class_replaceMethod(type, replacement, method_getImplementation(from), method_getTypeEncoding(from))
        } else {
            method_exchangeImplementations(from, to)
        }
    }

    private static func install() {
        guard !installed else { return }
        installed = true
        exchange(UILabel.self, #selector(setter: UILabel.textColor), #selector(UILabel.flaccyThemed_setTextColor(_:)))
        exchange(UILabel.self, #selector(setter: UILabel.font), #selector(UILabel.flaccyThemed_setFont(_:)))
        exchange(
            UILabel.self, #selector(setter: UILabel.attributedText),
            #selector(UILabel.flaccyThemed_setAttributedText(_:))
        )
        exchange(UIView.self, #selector(UIView.didMoveToWindow), #selector(UIView.flaccyThemed_didMoveToWindow))
    }

    /// The color a label is given for `color`: the theme's for one of the
    /// system's four text colors, anything else as it is.
    static func textColor(for color: UIColor?) -> UIColor? {
        guard dressing, let color else { return color }
        return ThemedColor.replacing(color) ?? color
    }

    /// The font a label is given for `font`, remembering `font` itself on the
    /// label so another theme can start from it again.
    static func font(for font: UIFont?, on label: UILabel) -> UIFont? {
        guard let font else { return font }
        guard dressing, !faces.isSystem else {
            objc_setAssociatedObject(label, &baseFontKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return font
        }
        objc_setAssociatedObject(label, &baseFontKey, font, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return ThemeTypography.themed(font, faces: faces)
    }

    /// `text` with every system font in it turned into the theme's face.
    private static func themed(_ text: NSAttributedString) -> NSAttributedString {
        let dressed = NSMutableAttributedString(attributedString: text)
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let font = value as? UIFont else { return }
            dressed.addAttribute(.font, value: ThemeTypography.themed(font, faces: faces), range: range)
        }
        return dressed
    }

    /// Whether a label's text carries fonts of its own, as a button's title
    /// or a line set in two weights does. Such a label is dressed run by run;
    /// giving it one font would flatten it.
    private static func hasOwnFonts(_ label: UILabel) -> Bool {
        guard let text = label.attributedText, text.length > 0 else { return false }
        var range = NSRange()
        let font = text.attribute(.font, at: 0, effectiveRange: &range) as? UIFont
        return range.length < text.length || (font != nil && font != label.font)
    }

    /// The attributed text a label is given for `text`, remembering `text`
    /// itself on the label so another theme can start from it again.
    static func attributedText(for text: NSAttributedString?, on label: UILabel) -> NSAttributedString? {
        guard dressing, !faces.isSystem, let text, text.length > 0 else {
            objc_setAssociatedObject(label, &baseTextKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return text
        }
        objc_setAssociatedObject(label, &baseTextKey, text.copy(), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return themed(text)
    }

    /// Dresses a label whose text carries its own fonts, or puts back the
    /// text it was given when the theme has no face of its own.
    private static func dressRuns(of label: UILabel) {
        let base = (objc_getAssociatedObject(label, &baseTextKey) as? NSAttributedString) ?? label.attributedText
        guard let base else { return }
        if dressing, !faces.isSystem {
            objc_setAssociatedObject(label, &baseTextKey, base.copy(), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            label.flaccyThemed_setAttributedText(themed(base))
        } else if objc_getAssociatedObject(label, &baseTextKey) != nil {
            objc_setAssociatedObject(label, &baseTextKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            label.flaccyThemed_setAttributedText(base)
        }
    }

    /// Brings one view up to the look that is on: a label gets the theme's
    /// text color and face, a cover its shape, and anything with a themed
    /// corner its radius. A view already at this epoch is left alone.
    static func dress(_ view: UIView) {
        guard installed else { return }
        let seen = (objc_getAssociatedObject(view, &epochKey) as? Int) ?? 0
        guard seen != epoch else { return }
        objc_setAssociatedObject(view, &epochKey, epoch, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        view.layer.reapplyThemedCornerRadius()
        view.coverShaper?.shape()
        if let cell = view as? UITableViewCell { dressGroupedCell(cell, mayWait: true) }
        guard let label = view as? UILabel else { return }
        if dressing, let themed = ThemedColor.replacing(label.textColor) {
            label.flaccyThemed_setTextColor(themed)
        }
        if objc_getAssociatedObject(label, &baseTextKey) != nil || hasOwnFonts(label) {
            dressRuns(of: label)
            return
        }
        let base = (objc_getAssociatedObject(label, &baseFontKey) as? UIFont) ?? label.font
        guard let base else { return }
        if dressing, !faces.isSystem {
            objc_setAssociatedObject(label, &baseFontKey, base, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            label.flaccyThemed_setFont(ThemeTypography.themed(base, faces: faces))
        } else if objc_getAssociatedObject(label, &baseFontKey) != nil {
            objc_setAssociatedObject(label, &baseFontKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            label.flaccyThemed_setFont(base)
        }
    }

    /// Gives a row of a grouped table the theme's card color. The system
    /// paints such a row with a color of its own that nothing else can
    /// reach, so the row is matched by that color and anything the app
    /// colored itself is left alone. A row that enters the window before the
    /// table has painted it is looked at once more on the next turn.
    private static func dressGroupedCell(_ cell: UITableViewCell, mayWait: Bool) {
        guard dressing else { return }
        guard let table = cell.superview as? UITableView, let painted = cell.backgroundColor else {
            guard mayWait else { return }
            DispatchQueue.main.async { [weak cell] in
                if let cell { dressGroupedCell(cell, mayWait: false) }
            }
            return
        }
        guard table.style != .plain else { return }
        let traits = cell.traitCollection
        let system = UIColor.secondarySystemGroupedBackground.resolvedColor(with: traits)
        if painted.resolvedColor(with: traits) == system {
            cell.backgroundColor = .flaccySecondaryGroupedBackground
        }
    }

    /// Dresses everything on screen.
    static func dressEverything(in windows: [UIWindow]) {
        guard installed else { return }
        func walk(_ view: UIView) {
            dress(view)
            view.subviews.forEach(walk)
        }
        windows.forEach(walk)
    }
}

extension UILabel {

    @objc dynamic func flaccyThemed_setTextColor(_ color: UIColor?) {
        flaccyThemed_setTextColor(ThemeHooks.textColor(for: color))
    }

    @objc dynamic func flaccyThemed_setFont(_ font: UIFont?) {
        flaccyThemed_setFont(ThemeHooks.font(for: font, on: self))
    }

    @objc dynamic func flaccyThemed_setAttributedText(_ text: NSAttributedString?) {
        flaccyThemed_setAttributedText(ThemeHooks.attributedText(for: text, on: self))
    }
}

extension UIView {

    @objc dynamic func flaccyThemed_didMoveToWindow() {
        flaccyThemed_didMoveToWindow()
        if window != nil { ThemeHooks.dress(self) }
    }
}
