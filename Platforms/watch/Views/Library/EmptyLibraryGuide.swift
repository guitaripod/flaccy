import FlaccyCore
import SwiftUI

/// What a library with nothing in it says: the three steps that put music on
/// the wrist, in the app's accent. Scrolls rather than shrinks, so the steps
/// stay readable on 40 mm and at accessibility sizes alike.
struct EmptyLibraryView: View {

    @Environment(\.isLuminanceReduced) private var isDimmed

    var errorReason: StoreFailureReason?

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 26))
                    .foregroundStyle(isDimmed ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(WatchTheme.accentGradient))
                    .accessibilityHidden(true)
                Text("No Music Yet")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                VStack(spacing: 6) {
                    GuideStep(number: 1, symbol: "iphone", text: "Open Flaccy on your iPhone")
                    GuideStep(number: 2, symbol: "applewatch", text: "Go to Settings › Apple Watch")
                    GuideStep(number: 3, symbol: "checkmark.circle", text: "Pick albums to send")
                }
                .accessibilityElement(children: .contain)

                if let notice = SyncErrorNotice(reason: errorReason) {
                    Label(notice.message, systemImage: notice.symbol)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}

private struct GuideStep: View {

    @Environment(\.isLuminanceReduced) private var isDimmed
    @ScaledMetric(relativeTo: .footnote) private var badge: CGFloat = 24

    let number: Int
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(isDimmed ? Color.white : Color.black)
                .frame(width: badge, height: badge)
                .background(badgeFill, in: Circle())
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white.opacity(isDimmed ? 0.06 : 0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Step \(number)"))
        .accessibilityValue(Text(text))
    }

    private var badgeFill: AnyShapeStyle {
        isDimmed ? AnyShapeStyle(Color.white.opacity(0.2)) : AnyShapeStyle(WatchTheme.accentGradient)
    }
}

/// Shown when something is arriving but the phone has not described a run:
/// the spinner is the only honest thing to draw.
struct ReceivingLibraryView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.large)
                Text("Receiving from iPhone…")
                    .font(.headline)
                Text("Your music is transferring in the background.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}
