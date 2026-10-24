import SwiftUI

/// A row that pushes a screen: glyph, title, one line of detail and a chevron.
/// Artists and Storage share it so the two read as siblings in the list.
struct BrowseRow: View {

    @Environment(\.isLuminanceReduced) private var isDimmed
    @Environment(\.dynamicTypeSize) private var typeSize

    let symbol: String
    let title: LocalizedStringKey
    let detail: String
    var tint: Color?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(glyphStyle)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? 6 : 3)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: detail))
    }

    private var glyphStyle: AnyShapeStyle {
        if let tint { return AnyShapeStyle(tint) }
        return isDimmed ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(WatchTheme.accentGradient)
    }
}
