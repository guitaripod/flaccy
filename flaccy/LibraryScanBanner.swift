import FlaccyCore
import UIKit

/// The compact form of a library scan, shown under the segments once there is a
/// library worth browsing: what the scan is doing and how far along it is,
/// without taking the screen away from the music.
final class LibraryScanBanner: UIView {

    static let expandedHeight: CGFloat = 34

    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let label = UILabel()
    private let countLabel = UILabel()

    private(set) var isShowing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.trackTintColor = .tertiarySystemFill
        progressView.progressTintColor = .tintColor

        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel

        countLabel.font = .preferredFont(forTextStyle: .caption1)
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.textColor = .tertiaryLabel
        countLabel.textAlignment = .right
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [label, countLabel])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .firstBaseline
        row.translatesAutoresizingMaskIntoConstraints = false

        addSubview(row)
        addSubview(progressView)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            progressView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            progressView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            progressView.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 6),
            progressView.heightAnchor.constraint(equalToConstant: 2),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
        accessibilityLabel = String(localized: "Updating your library")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(progress: LibraryLoadProgress, fraction: Double) {
        label.text = LibraryLoadPhaseCopy.headline(for: progress.phase)
        countLabel.text = LibraryLoadPhaseCopy.detail(for: progress)
        progressView.setProgress(Float(min(1, max(0, fraction))), animated: isShowing)
        accessibilityValue = LibraryLoadPhaseCopy.accessibilityValue(for: progress, fraction: fraction)
        isShowing = true
    }

    func prepareForShow() {
        progressView.setProgress(0, animated: false)
        isShowing = false
    }
}
