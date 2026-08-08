import FlaccyCore
import SwiftUI

/// The watch face of a library scan: the same phases the phone reports, sized
/// for a wrist — a determinate ring, the stage, and what it has found so far.
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

            Text(headline)
                .font(.footnote.weight(.semibold))
                .multilineTextAlignment(.center)

            if !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        switch progress.phase {
        case .idle, .openingLibrary: return String(localized: "Opening your library")
        case .findingFiles: return String(localized: "Looking for music")
        case .readingTags: return String(localized: "Reading tags")
        case .identifyingMusic: return String(localized: "Identifying albums")
        case .buildingAlbums: return String(localized: "Building your shelves")
        case .enrichingArtwork: return String(localized: "Fetching artwork")
        }
    }

    private var detail: String {
        switch progress.phase {
        case .findingFiles where progress.filesFound > 0:
            return String(localized: "\(progress.filesFound) files found")
        case .readingTags where progress.total > 0:
            return String(localized: "\(min(progress.completed, progress.total)) of \(progress.total)")
        case .buildingAlbums where progress.tracksIndexed > 0:
            return String(localized: "\(progress.tracksIndexed) tracks")
        default:
            return ""
        }
    }
}
