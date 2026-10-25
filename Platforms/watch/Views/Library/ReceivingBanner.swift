import FlaccyCore
import SwiftUI

/// The phone's run, on the wrist: "Receiving 3 of 12" over a thin determinate
/// bar, or the honest "preparing" sentence while the phone has not sent a first
/// file yet. `compact` rides above the albums; `prominent` is the whole screen
/// of an empty library that is filling.
struct ReceivingBanner: View {

    enum Style { case compact, prominent }

    @Environment(\.isLuminanceReduced) private var isDimmed
    @Environment(\.dynamicTypeSize) private var typeSize

    let batch: SyncBatch
    var style: Style = .compact

    var body: some View {
        Group {
            switch style {
            case .compact: compact
            case .prominent: prominent
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Receiving songs"))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var compact: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                glyph.font(.system(size: 13, weight: .semibold))
                Text(compactHeadline)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: batch.completed)
            }
            if !batch.preparing {
                ReceivingBar(fraction: batch.fraction, height: 4, isDimmed: isDimmed)
            }
        }
        .padding(.vertical, 2)
    }

    private var prominent: some View {
        VStack(spacing: 8) {
            if batch.preparing {
                ProgressView()
                    .controlSize(.large)
                    .tint(WatchTheme.accent)
                Text("Your iPhone is preparing songs…")
                    .font(.headline)
                    .multilineTextAlignment(.center)
            } else {
                glyph.font(.system(size: 22, weight: .semibold))
                Text(headline)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: batch.completed)
                ReceivingBar(fraction: batch.fraction, height: 6, isDimmed: isDimmed)
                    .padding(.horizontal, 6)
            }
            Text("Your music is transferring in the background.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var glyph: some View {
        if batch.preparing {
            ProgressView().controlSize(.mini).tint(WatchTheme.accent)
        } else {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(isDimmed ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(WatchTheme.accentGradient))
        }
    }

    private var headline: String {
        batch.preparing
            ? String(localized: "Your iPhone is preparing songs…")
            : String(localized: "Receiving \(batch.completed) of \(batch.total)")
    }

    /// "Receiving 3 of 12 · From iPhone": the run and where it comes from.
    private var compactHeadline: String {
        batch.preparing ? headline : "\(headline) · \(String(localized: "From iPhone"))"
    }

    private var accessibilityValue: String {
        batch.preparing
            ? String(localized: "Your iPhone is preparing songs…")
            : String(localized: "\(batch.completed) of \(batch.total) songs, \(Int((batch.fraction * 100).rounded())) percent")
    }
}

/// A hairline determinate bar. The system linear style ignores height and
/// grows a thumb on the wrist; a capsule on a capsule stays exactly as thin as
/// asked and takes the Always-On treatment without a special case.
struct ReceivingBar: View {

    let fraction: Double
    let height: CGFloat
    var isDimmed = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(isDimmed ? 0.12 : 0.2))
                Capsule()
                    .fill(isDimmed ? AnyShapeStyle(Color.white.opacity(0.6)) : AnyShapeStyle(WatchTheme.accentGradient))
                    .frame(width: max(height, proxy.size.width * clamped))
            }
        }
        .frame(height: height)
        .animation(.smooth, value: fraction)
        .accessibilityHidden(true)
    }

    private var clamped: Double { min(1, max(0, fraction)) }
}
