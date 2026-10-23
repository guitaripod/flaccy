import FlaccyCore
import UIKit

final class LyricCell: UITableViewCell {

    static let reuseID = "LyricCell"

    let lyricLabel = UILabel()
    let wipeView = LyricWipeView()
    var isCurrentLine = false
    var isBacking = false
    static let dimmedScale: CGFloat = 0.86
    static let dimmedAlpha: CGFloat = 0.35

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none

        lyricLabel.numberOfLines = 0
        lyricLabel.font = .scaled(.title2, size: 24, weight: .bold)
        lyricLabel.adjustsFontForContentSizeCategory = true
        lyricLabel.textColor = .white
        lyricLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(lyricLabel)

        wipeView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(wipeView)

        NSLayoutConstraint.activate([
            lyricLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            lyricLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            lyricLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            lyricLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            wipeView.topAnchor.constraint(equalTo: lyricLabel.topAnchor),
            wipeView.bottomAnchor.constraint(equalTo: lyricLabel.bottomAnchor),
            wipeView.leadingAnchor.constraint(equalTo: lyricLabel.leadingAnchor),
            wipeView.trailingAnchor.constraint(equalTo: lyricLabel.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func configure(line: LyricsLine, isCurrent: Bool) {
        isBacking = line.background
        lyricLabel.font = isBacking
            ? .scaled(.title3, size: 20, weight: .semibold)
            : .scaled(.title2, size: 24, weight: .bold)
        lyricLabel.text = line.text
        wipeView.configure(text: line.text, words: line.words, font: lyricLabel.font)
        showProgress(nil)
        isAccessibilityElement = true
        accessibilityLabel = line.text
        accessibilityValue = isCurrent ? String(localized: "Current line") : nil
        accessibilityHint = String(localized: "Plays from this line")
        accessibilityTraits = .button
        setCurrent(isCurrent, animated: false)
    }

    /// Shows the fill at a clock position, swapping the plain label for the
    /// drawn one, or goes back to the plain label for `nil`.
    func showProgress(_ progress: LyricsLineProgress?) {
        wipeView.show(progress)
        lyricLabel.isHidden = !wipeView.isHidden
    }

    func setCurrent(_ isCurrent: Bool, animated: Bool) {
        guard isCurrent != isCurrentLine || !animated else { return }
        isCurrentLine = isCurrent
        accessibilityValue = isCurrent ? String(localized: "Current line") : nil
        let apply = { [self] in
            lyricLabel.alpha = isCurrent ? 1 : Self.dimmedAlpha
            lyricLabel.transform = isCurrent ? .identity : Self.dimmedTransform(width: lyricLabel.bounds.width)
        }
        if animated, !UIAccessibility.isReduceMotionEnabled {
            let animator = UIViewPropertyAnimator(duration: 0.28, dampingRatio: 0.86, animations: apply)
            animator.startAnimation()
        } else {
            apply()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !isCurrentLine, lyricLabel.transform != .identity {
            lyricLabel.transform = Self.dimmedTransform(width: lyricLabel.bounds.width)
        }
    }

    /// Scales the label down around its leading edge so dimmed lines shrink
    /// toward the margin the way Apple Music's lyrics do.
    static func dimmedTransform(width: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: -width * (1 - dimmedScale) / 2, y: 0)
            .scaledBy(x: dimmedScale, y: dimmedScale)
    }
}

/// An instrumental stretch: three beats that light one after another across
/// the gap, so a pause in the singing reads as part of the song.
final class InterludeCell: UITableViewCell {

    static let reuseID = "InterludeCell"

    let beats: [UIView] = (0..<LyricsDocument.interludeBeats).map { _ in
        let beat = UIView()
        beat.layer.cornerRadius = 5
        beat.backgroundColor = .white
        beat.alpha = InterludeCell.unlitAlpha
        return beat
    }
    var isCurrentLine = false
    static let unlitAlpha: CGFloat = 0.25
    static let dimmedAlpha: CGFloat = 0.35

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        isAccessibilityElement = false

        let stack = UIStackView(arrangedSubviews: beats)
        stack.axis = .horizontal
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
        ])
        for beat in beats {
            beat.widthAnchor.constraint(equalToConstant: 10).isActive = true
            beat.heightAnchor.constraint(equalToConstant: 10).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func configure(isCurrent: Bool) {
        setLitBeats(0)
        setCurrent(isCurrent, animated: false)
    }

    func setCurrent(_ isCurrent: Bool, animated: Bool) {
        isCurrentLine = isCurrent
        let apply = { [self] in
            contentView.alpha = isCurrent ? 1 : Self.dimmedAlpha
        }
        if animated, !UIAccessibility.isReduceMotionEnabled {
            UIViewPropertyAnimator(duration: 0.28, dampingRatio: 0.86, animations: apply).startAnimation()
        } else {
            apply()
        }
    }

    func setLitBeats(_ lit: Int) {
        for (index, beat) in beats.enumerated() {
            let target = index < lit ? 1 : Self.unlitAlpha
            guard beat.alpha != target else { continue }
            if UIAccessibility.isReduceMotionEnabled {
                beat.alpha = target
            } else {
                UIView.animate(withDuration: 0.26) { beat.alpha = target }
            }
        }
    }
}
