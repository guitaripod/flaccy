import UIKit

extension UIFont {

    /// Returns a Dynamic Type–scaled font anchored to the given text style, so fixed design sizes track the user's content size category.
    static func scaled(_ style: UIFont.TextStyle, size: CGFloat, weight: UIFont.Weight) -> UIFont {
        UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight))
    }

    /// Same as `scaled(_:size:weight:)` but capped at a maximum point size for space-constrained UI.
    static func scaled(_ style: UIFont.TextStyle, size: CGFloat, weight: UIFont.Weight, maxSize: CGFloat) -> UIFont {
        UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight), maximumPointSize: maxSize)
    }
}

final class ToastView {

    static func show(_ message: String, in view: UIView, style: Style = .info) {
        let toast = UIView()
        toast.layer.cornerRadius = 14
        toast.layer.cornerCurve = .continuous
        toast.layer.shadowColor = UIColor.black.cgColor
        toast.layer.shadowOpacity = 0.16
        toast.layer.shadowOffset = CGSize(width: 0, height: 6)
        toast.layer.shadowRadius = 16
        toast.alpha = 0
        toast.translatesAutoresizingMaskIntoConstraints = false

        let contentHost = makeBackground(for: toast, style: style)

        let icon = UIImageView(image: UIImage(systemName: style.icon))
        icon.tintColor = style.accentColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = message
        label.font = .scaled(.footnote, size: 14, weight: .medium)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.numberOfLines = 2

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(stack)
        view.addSubview(toast)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            stack.leadingAnchor.constraint(equalTo: toast.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: toast.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: toast.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: toast.bottomAnchor, constant: -12),
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            toast.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
        ])

        animateIn(toast)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            animateOut(toast)
        }
    }

    /// Installs a Liquid Glass backing inside the toast (solid fill under
    /// Reduce Transparency) and returns the view that should host content.
    private static func makeBackground(for toast: UIView, style: Style) -> UIView {
        guard !UIAccessibility.isReduceTransparencyEnabled else {
            toast.backgroundColor = .secondarySystemBackground
            return toast
        }
        let glass = LiquidGlass.view(cornerRadius: 14, tint: style.accentColor.withAlphaComponent(0.25))
        glass.translatesAutoresizingMaskIntoConstraints = false
        toast.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: toast.topAnchor),
            glass.leadingAnchor.constraint(equalTo: toast.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: toast.trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: toast.bottomAnchor),
        ])
        return glass.contentView
    }

    private static func animateIn(_ toast: UIView) {
        guard !UIAccessibility.isReduceMotionEnabled else {
            UIView.animate(withDuration: 0.2) { toast.alpha = 1 }
            return
        }
        toast.transform = CGAffineTransform(translationX: 0, y: -16).scaledBy(x: 0.92, y: 0.92)
        let animator = UIViewPropertyAnimator(duration: 0.42, dampingRatio: 0.72) {
            toast.alpha = 1
            toast.transform = .identity
        }
        animator.startAnimation()
    }

    private static func animateOut(_ toast: UIView) {
        let animations = {
            toast.alpha = 0
            if !UIAccessibility.isReduceMotionEnabled {
                toast.transform = CGAffineTransform(translationX: 0, y: -12).scaledBy(x: 0.94, y: 0.94)
            }
        }
        let animator = UIViewPropertyAnimator(duration: 0.24, dampingRatio: 1, animations: animations)
        animator.addCompletion { _ in toast.removeFromSuperview() }
        animator.startAnimation()
    }

    enum Style {
        case success
        case error
        case info

        var accentColor: UIColor {
            switch self {
            case .success: .systemGreen
            case .error: .systemRed
            case .info: .secondaryLabel
            }
        }

        var icon: String {
            switch self {
            case .success: "checkmark.circle.fill"
            case .error: "exclamationmark.triangle.fill"
            case .info: "info.circle.fill"
            }
        }
    }
}
