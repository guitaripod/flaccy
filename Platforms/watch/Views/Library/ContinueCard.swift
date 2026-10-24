import SwiftUI

/// The first thing on the library when a session was restored: the song the
/// person left, one tap from playing. The glyph is a play button, so the card
/// reads as an action rather than a banner.
struct ContinueCard: View {

    @Environment(\.isLuminanceReduced) private var isDimmed
    @Environment(\.dynamicTypeSize) private var typeSize

    let title: String
    let artist: String
    let albumTitle: String
    let artworkData: Data?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if !typeSize.isAccessibilitySize {
                    ArtworkView(data: artworkData, seed: albumTitle, cornerRadius: 8)
                        .frame(width: 38, height: 38)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Continue")
                        .font(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(isDimmed ? Color.secondary : WatchTheme.accent)
                    Text(title)
                        .font(.headline)
                        .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                        .minimumScaleFactor(0.85)
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(isDimmed ? Color.white : Color.black)
                    .frame(width: 28, height: 28)
                    .background(playBackground, in: Circle())
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .listRowBackground(cardBackground)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Continue playing"))
        .accessibilityValue(Text(verbatim: "\(title), \(artist)"))
        .accessibilityAddTraits(.isButton)
    }

    private var playBackground: AnyShapeStyle {
        isDimmed ? AnyShapeStyle(Color.white.opacity(0.25)) : AnyShapeStyle(WatchTheme.accentGradient)
    }

    @ViewBuilder private var cardBackground: some View {
        if isDimmed {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.1))
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(WatchTheme.accentGradient.opacity(0.28))
        }
    }
}
