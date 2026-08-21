import FlaccyCore
import UIKit

/// The ambient line under the segments: what the library is doing right now,
/// without taking the screen away from the music.
///
/// It renders two different kinds of work and refuses to conflate them. A load
/// is bounded disk work, so it earns a real 2 pt bar that reaches a real 100%.
/// The enrichment job is unbounded network work, so it gets a spinner and a
/// countdown and never a bar — a fraction there would be a number nobody could
/// honestly compute.
final class LibraryStatusBanner: UIView {

    enum Content {
        case load(LibraryLoadProgress, Double)
        case job(EnrichmentJobProgress)
    }

    static let expandedHeight: CGFloat = 34

    /// Set to make the banner push the enrichment report. A nil handler hides
    /// the chevron and drops the button trait, so the banner never advertises a
    /// destination it does not have.
    var onTap: (() -> Void)? {
        didSet { updateTapAffordance() }
    }

    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()
    private let countLabel = UILabel()
    private let chevronView = UIImageView()
    private let selectionFeedback = UISelectionFeedbackGenerator()

    private(set) var isShowing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        configureSubviews()
        let row = makeRow()
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

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
        accessibilityLabel = String(localized: "Updating your library")
        updateTapAffordance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureSubviews() {
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.trackTintColor = .tertiarySystemFill
        progressView.progressTintColor = .tintColor

        spinner.hidesWhenStopped = true
        spinner.transform = CGAffineTransform(scaleX: 0.62, y: 0.62)
        spinner.setContentHuggingPriority(.required, for: .horizontal)

        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel

        countLabel.font = .preferredFont(forTextStyle: .caption1)
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.textColor = .tertiaryLabel
        countLabel.textAlignment = .right
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        chevronView.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        )
        chevronView.tintColor = .tertiaryLabel
        chevronView.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func makeRow() -> UIStackView {
        let row = UIStackView(arrangedSubviews: [spinner, label, countLabel, chevronView])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        row.setCustomSpacing(6, after: spinner)
        row.setCustomSpacing(6, after: countLabel)
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    func update(_ content: Content) {
        switch content {
        case .load(let progress, let fraction):
            renderLoad(progress, fraction: fraction)
        case .job(let progress):
            renderJob(progress)
        }
        isShowing = true
    }

    private func renderLoad(_ progress: LibraryLoadProgress, fraction: Double) {
        spinner.stopAnimating()
        progressView.isHidden = false
        label.text = LibraryLoadPhaseCopy.headline(for: progress.phase)
        countLabel.text = LibraryLoadPhaseCopy.detail(for: progress)
        progressView.setProgress(Float(min(1, max(0, fraction))), animated: isShowing)
        accessibilityValue = LibraryLoadPhaseCopy.accessibilityValue(for: progress, fraction: fraction)
    }

    /// The job has no bar by design. Waiting for a connection is the one state
    /// that also stops the spinner: a spinner that keeps turning while nothing
    /// is being fetched claims progress that is not happening.
    private func renderJob(_ progress: EnrichmentJobProgress) {
        progressView.isHidden = true
        progressView.setProgress(0, animated: false)

        switch progress.activity {
        case .running:
            spinner.startAnimating()
            label.text = EnrichmentJobCopy.headline(for: progress.scope)
            countLabel.text = EnrichmentJobCopy.detail(remaining: progress.remaining)
        case .waitingForNetwork:
            spinner.stopAnimating()
            label.text = EnrichmentJobCopy.waitingForNetwork
            countLabel.text = nil
        case .needsEntitlement:
            spinner.stopAnimating()
            label.text = EnrichmentJobCopy.needsEntitlement
            countLabel.text = nil
        case .idle:
            spinner.stopAnimating()
            label.text = nil
            countLabel.text = nil
        }
        accessibilityValue = EnrichmentJobCopy.accessibilityValue(for: progress)
    }

    func prepareForShow() {
        progressView.setProgress(0, animated: false)
        isShowing = false
    }

    private func updateTapAffordance() {
        let isTappable = onTap != nil
        chevronView.isHidden = !isTappable
        accessibilityTraits = isTappable ? [.updatesFrequently, .button] : .updatesFrequently
        accessibilityHint = isTappable ? String(localized: "Shows what Flaccy is still looking for") : nil
    }

    @objc private func handleTap() {
        guard let onTap else { return }
        selectionFeedback.selectionChanged()
        onTap()
    }
}
