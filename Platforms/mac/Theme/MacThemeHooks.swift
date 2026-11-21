import AppKit
import FlaccyCore
import ObjectiveC

/// How a theme reaches every label and button of the Mac app: the setters a
/// control's look goes through are intercepted, so the text color the system
/// calls "label" becomes the theme's and the system font becomes the theme's
/// face, wherever the control was made.
///
/// Nothing is intercepted until a look other than Flaccy's own is first worn,
/// and under Flaccy's own every hook hands its argument straight through, so
/// the look every release shipped with is untouched. A label keeps the
/// system's own text color until a theme paints, because only that color
/// turns white on a selected row.
@MainActor
enum MacThemeHooks {

    private static var installed = false
    private static var dressing = false
    private static var faces = MacThemeTypography.Faces()
    private static var epoch = 0

    private nonisolated(unsafe) static var baseFontKey: UInt8 = 0
    private nonisolated(unsafe) static var baseTextKey: UInt8 = 0
    private nonisolated(unsafe) static var epochKey: UInt8 = 0

    /// Starts dressing controls in `faces`, the theme's text colors and its
    /// shapes, or stops when `dressing` is false. `epoch` marks the look, so
    /// a view that was off screen while it changed is brought up to date when
    /// it comes back.
    static func wear(dressing: Bool, faces: MacThemeTypography.Faces, epoch: Int) {
        self.dressing = dressing
        self.faces = faces
        self.epoch = epoch
        if dressing { install() }
    }

    private static var paints: Bool { dressing && ThemePalettes.isPainting }
    private static var setsFaces: Bool { dressing && !faces.isSystem }

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
        exchange(NSTextField.self, #selector(setter: NSTextField.textColor), #selector(NSTextField.flaccyThemed_setTextColor(_:)))
        exchange(NSTextField.self, #selector(setter: NSTextField.font), #selector(NSTextField.flaccyThemed_setFont(_:)))
        exchange(
            NSTextField.self, #selector(setter: NSTextField.attributedStringValue),
            #selector(NSTextField.flaccyThemed_setAttributedStringValue(_:))
        )
        exchange(NSButton.self, #selector(setter: NSButton.font), #selector(NSButton.flaccyThemedButton_setFont(_:)))
        exchange(
            NSButton.self, #selector(setter: NSButton.attributedTitle),
            #selector(NSButton.flaccyThemedButton_setAttributedTitle(_:))
        )
        exchange(NSView.self, #selector(NSView.viewDidMoveToWindow), #selector(NSView.flaccyThemed_viewDidMoveToWindow))
    }

    /// The color a label is given for `color`: the theme's for one of the
    /// system's text colors while a theme paints, anything else as it is.
    static func textColor(for color: NSColor?) -> NSColor? {
        guard paints, let color else { return color }
        return MacThemedColor.replacingText(color) ?? color
    }

    /// The font a control is given for `font`, remembering `font` itself on
    /// the control so another theme can start from it again.
    static func font(for font: NSFont?, on control: NSControl) -> NSFont? {
        guard let font else { return font }
        guard setsFaces else {
            objc_setAssociatedObject(control, &baseFontKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return font
        }
        objc_setAssociatedObject(control, &baseFontKey, font, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return MacThemeTypography.themed(font, faces: faces)
    }

    /// `text` with every system font in it turned into the theme's face and
    /// every system text color into the theme's.
    private static func themed(_ text: NSAttributedString) -> NSAttributedString {
        let dressed = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: text.length)
        if setsFaces {
            text.enumerateAttribute(.font, in: whole) { value, range, _ in
                guard let font = value as? NSFont else { return }
                dressed.addAttribute(.font, value: MacThemeTypography.themed(font, faces: faces), range: range)
            }
        }
        if paints {
            text.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
                guard let color = value as? NSColor, let themed = MacThemedColor.replacingText(color) else { return }
                dressed.addAttribute(.foregroundColor, value: themed, range: range)
            }
        }
        return dressed
    }

    /// The attributed text a control is given for `text`, remembering `text`
    /// itself on the control so another theme can start from it again.
    static func attributedText(for text: NSAttributedString, on control: NSControl) -> NSAttributedString {
        guard dressing, text.length > 0 else {
            objc_setAssociatedObject(control, &baseTextKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return text
        }
        objc_setAssociatedObject(control, &baseTextKey, text.copy(), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return themed(text)
    }

    private static func setFont(_ font: NSFont, on control: NSControl) {
        if let field = control as? NSTextField {
            field.flaccyThemed_setFont(font)
        } else if let button = control as? NSButton {
            button.flaccyThemedButton_setFont(font)
        }
    }

    private static func setAttributedText(_ text: NSAttributedString, on control: NSControl) {
        if let field = control as? NSTextField {
            field.flaccyThemed_setAttributedStringValue(text)
        } else if let button = control as? NSButton {
            button.flaccyThemedButton_setAttributedTitle(text)
        }
    }

    /// Gives a label the theme's text color, or the system's back once no
    /// theme paints.
    private static func dressColor(of field: NSTextField) {
        guard let color = field.textColor else { return }
        if paints {
            if let themed = MacThemedColor.replacingText(color) { field.flaccyThemed_setTextColor(themed) }
        } else if let system = MacThemedColor.systemText(replacedBy: color) {
            field.flaccyThemed_setTextColor(system)
        }
    }

    /// Gives a symbol or a button the theme's color where it was tinted with
    /// one of the system's text colors, or the system's back once no theme
    /// paints.
    private static func dressTint(of view: NSView) {
        let tint = (view as? NSImageView)?.contentTintColor ?? (view as? NSButton)?.contentTintColor
        guard let tint else { return }
        let dressed = paints ? MacThemedColor.replacingText(tint) : MacThemedColor.systemText(replacedBy: tint)
        guard let dressed else { return }
        (view as? NSImageView)?.contentTintColor = dressed
        (view as? NSButton)?.contentTintColor = dressed
    }

    /// Dresses a control that was handed attributed text again from the text
    /// it was handed, or puts that text back when the look has nothing to add.
    private static func dressRuns(of control: NSControl, from base: NSAttributedString) {
        if dressing {
            setAttributedText(themed(base), on: control)
        } else {
            objc_setAssociatedObject(control, &baseTextKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            setAttributedText(base, on: control)
        }
    }

    /// Brings one view up to the look that is on: a label gets the theme's
    /// text color, a label or a button its face, a cover its shape and
    /// anything with a themed corner its radius. A view already at this epoch
    /// is left alone.
    static func dress(_ view: NSView) {
        guard installed else { return }
        let seen = (objc_getAssociatedObject(view, &epochKey) as? Int) ?? 0
        guard seen != epoch else { return }
        objc_setAssociatedObject(view, &epochKey, epoch, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        view.layer?.reapplyThemedCornerRadius()
        view.macCoverShaper?.shape()
        dressTint(of: view)
        guard let control = view as? NSControl, control is NSTextField || control is NSButton else { return }
        if let base = objc_getAssociatedObject(control, &baseTextKey) as? NSAttributedString {
            dressRuns(of: control, from: base)
            return
        }
        if let field = control as? NSTextField { dressColor(of: field) }
        let base = (objc_getAssociatedObject(control, &baseFontKey) as? NSFont) ?? control.font
        guard let base else { return }
        if setsFaces {
            objc_setAssociatedObject(control, &baseFontKey, base, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            setFont(MacThemeTypography.themed(base, faces: faces), on: control)
        } else if objc_getAssociatedObject(control, &baseFontKey) != nil {
            objc_setAssociatedObject(control, &baseFontKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            setFont(base, on: control)
        }
    }

    /// Dresses everything in `windows` and has every view draw again and
    /// refresh the colors it keeps for itself, the way it does when the
    /// system flips between light and dark.
    static func dressEverything(in windows: [NSWindow]) {
        guard installed else { return }
        func walk(_ view: NSView) {
            dress(view)
            view.effectiveAppearance.performAsCurrentDrawingAppearance { view.viewDidChangeEffectiveAppearance() }
            view.needsDisplay = true
            view.needsLayout = true
            view.subviews.forEach(walk)
        }
        for window in windows {
            if let frame = window.contentView?.superview ?? window.contentView { walk(frame) }
        }
    }

    #if DEBUG
    /// The font a control was given before the theme set its own, for the
    /// exercise that checks every control ends in the font it started with.
    static func baseFont(of control: NSControl) -> NSFont? {
        objc_getAssociatedObject(control, &baseFontKey) as? NSFont
    }
    #endif
}

extension NSTextField {

    @objc dynamic func flaccyThemed_setTextColor(_ color: NSColor?) {
        flaccyThemed_setTextColor(MacThemeHooks.textColor(for: color))
    }

    @objc dynamic func flaccyThemed_setFont(_ font: NSFont?) {
        flaccyThemed_setFont(MacThemeHooks.font(for: font, on: self))
    }

    @objc dynamic func flaccyThemed_setAttributedStringValue(_ text: NSAttributedString) {
        flaccyThemed_setAttributedStringValue(MacThemeHooks.attributedText(for: text, on: self))
    }
}

extension NSButton {

    @objc dynamic func flaccyThemedButton_setFont(_ font: NSFont?) {
        flaccyThemedButton_setFont(MacThemeHooks.font(for: font, on: self))
    }

    @objc dynamic func flaccyThemedButton_setAttributedTitle(_ text: NSAttributedString) {
        flaccyThemedButton_setAttributedTitle(MacThemeHooks.attributedText(for: text, on: self))
    }
}

extension NSView {

    @objc dynamic func flaccyThemed_viewDidMoveToWindow() {
        flaccyThemed_viewDidMoveToWindow()
        if window != nil { MacThemeHooks.dress(self) }
    }
}
