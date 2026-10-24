import UIKit

/// A segmented control whose segments carry stable, non-localized accessibility
/// identifiers.
///
/// Segment titles are translated, so UI tests can only address a segment
/// reliably by identity. UIKit has no per-segment identifier API, but it does
/// carry the identifier of the `UIAction` backing a segment into the
/// accessibility tree — segments keep reporting `valueChanged`, so call sites
/// keep their existing single handler.
final class IdentifiedSegmentedControl: UISegmentedControl {

    init(items: [String], identifiers: [String]) {
        super.init(frame: .zero)
        for (index, pair) in zip(items, identifiers).enumerated() {
            let action = UIAction(title: pair.0) { _ in }
            action.accessibilityIdentifier = pair.1
            insertSegment(action: action, at: index, animated: false)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
