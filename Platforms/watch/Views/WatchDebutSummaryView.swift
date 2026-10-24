import FlaccyCore
import SwiftUI
import WatchKit

/// The wrist's third act: the once-ever card that closes the first build of a
/// library. It is the same moment the phone and the Mac stage, cut down to what
/// a watch can hold — three covers, the title, one line of counts.
struct WatchDebutSummaryView: View {

    /// Once-per-install, not once-per-launch. The phone's Debut is gated on a
    /// database row; the watch has no database, so its own flag is the closest
    /// honest equivalent — a re-pair or a reinstall earns the card again,
    /// exactly as a rebuilt library does on every other client.
    static let storageKey = "watch.debutShown"

    /// How long the covers take to settle before the card's words arrive, so the
    /// haptic, the artwork and the sentence land as one event rather than three.
    private static let settleDelay: Duration = .milliseconds(180)

    let trackCount: Int
    let albums: [MediaAlbum]
    let onDismiss: () -> Void

    @AppStorage(WatchDebutSummaryView.storageKey) private var hasShown = false
    @State private var hasSettled = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                covers
                Text(LibraryDebutCopy.watchCardTitle)
                    .font(.title3.weight(.semibold))
                Text(LibraryDebutCopy.watchCardDetail(trackCount: trackCount, albumCount: albums.count))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(LibraryDebutCopy.primaryAction, action: dismiss)
                    .buttonStyle(.borderedProminent)
                    .tint(WatchTheme.accent)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .accessibilityElement(children: .contain)
        .task { await celebrate() }
    }

    private var covers: some View {
        HStack(spacing: 4) {
            ForEach(albums.prefix(3)) { album in
                ArtworkView(data: album.artworkData, seed: album.id, cornerRadius: 7)
                    .frame(width: 42, height: 42)
                    .scaleEffect(hasSettled ? 1 : 0.86)
                    .opacity(hasSettled ? 1 : 0)
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: hasSettled)
    }

    /// One `.success` notification and one settle, on the one launch that earns
    /// them. HIG: background work never repeats a haptic, so nothing before this
    /// moment taps the wrist.
    private func celebrate() async {
        WKInterfaceDevice.current().play(.success)
        try? await Task.sleep(for: Self.settleDelay)
        hasSettled = true
    }

    private func dismiss() {
        hasShown = true
        onDismiss()
    }
}
