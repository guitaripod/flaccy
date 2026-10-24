import FlaccyCore
import SwiftUI

/// The watch face of a library scan: the same phases the phone reports, sized
/// for a wrist — a determinate ring, the stage, and what it has found so far.
/// Every word comes from `LibraryLoadPhaseCopy`, so the wrist can never fall
/// out of step with the phone the way a hand-copied switch does.
struct ScanProgressView: View {

    let progress: LibraryLoadProgress
    let fraction: Double

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                if progress.isDeterminate {
                    ProgressView(value: min(1, max(0, fraction)))
                        .progressViewStyle(.circular)
                } else {
                    ProgressView().progressViewStyle(.circular)
                }
                if progress.isDeterminate {
                    Text(verbatim: "\(Int((fraction * 100).rounded()))%")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 54, height: 54)

            Text(LibraryLoadPhaseCopy.headline(for: progress.phase))
                .font(.footnote.weight(.semibold))
                .multilineTextAlignment(.center)

            if !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: detail)
            }
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
        .accessibilityValue(LibraryLoadPhaseCopy.accessibilityValue(for: progress, fraction: fraction))
    }

    private var detail: String { LibraryLoadPhaseCopy.detail(for: progress) }
}
