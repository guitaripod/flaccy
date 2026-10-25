import UIKit

/// The small mark after a remote song's title that says the whole song is on this device.
final class DownloadedMarkView: UIImageView {

    init() {
        super.init(image: UIImage(
            systemName: "arrow.down.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        ))
        translatesAutoresizingMaskIntoConstraints = false
        tintColor = QualityBadgeView.losslessDynamicTint
        contentMode = .center
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
