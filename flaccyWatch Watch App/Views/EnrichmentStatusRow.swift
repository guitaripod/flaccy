import FlaccyCore
import SwiftUI

/// The phone's enrichment job, on the wrist: a thin 22 pt ring, the headline,
/// and the countdown. It is one header row above the albums and never a screen
/// of its own — the watch makes no lookups itself, so this is a report about
/// the phone, not work the reader is waiting on here.
struct EnrichmentStatusRow: View {

    /// The 22 pt ring is deliberately fraction-free. The job counts entities
    /// down rather than measuring a whole, so there is nothing honest for a
    /// determinate ring to fill.
    private static let ringSize: CGFloat = 22

    let content: Content

    var body: some View {
        HStack(spacing: 8) {
            indicator
                .frame(width: Self.ringSize, height: Self.ringSize)

            VStack(alignment: .leading, spacing: 1) {
                Text(content.headline)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(content.detail)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: content.detail)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityValue(content.accessibilityValue)
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder private var indicator: some View {
        if content.isWaiting {
            Image(systemName: "wifi.slash")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        } else {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .tint(WatchTheme.accent)
        }
    }
}

extension EnrichmentStatusRow {

    /// What the wrist is allowed to say about the phone's job. `idle` and
    /// `needsEntitlement` produce nothing at all: an ended trial is told once on
    /// the phone and then only in Settings, and it is never launch chrome — on
    /// any client, least of all the smallest one.
    struct Content: Equatable {

        let headline: String
        let detail: String
        let isWaiting: Bool
        let accessibilityValue: String

        init?(_ progress: EnrichmentJobProgress) {
            switch progress.activity {
            case .idle, .needsEntitlement:
                return nil
            case .running:
                isWaiting = false
                detail = EnrichmentJobCopy.detail(remaining: progress.remaining)
            case .waitingForNetwork:
                isWaiting = true
                detail = EnrichmentJobCopy.waitingForNetwork
            }
            headline = EnrichmentJobCopy.headline(for: progress.scope)
            accessibilityValue = EnrichmentJobCopy.accessibilityValue(for: progress)
        }
    }
}
