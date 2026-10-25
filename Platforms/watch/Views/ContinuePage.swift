import FlaccyCore
import SwiftUI

/// The first page of the wrist's vertical pager: the song to pick back up,
/// or, with nothing to continue, a big Shuffle All.
struct ContinuePage: View {

    @Environment(WatchAudioPlayer.self) private var player
    @Environment(WatchLibraryStore.self) private var store
    @Environment(WatchSyncStatus.self) private var syncStatus
    @Environment(\.isLuminanceReduced) private var isDimmed
    @Environment(\.dynamicTypeSize) private var typeSize

    let onShowNowPlaying: () -> Void

    var body: some View {
        Group {
            if let summary = player.resumeSummary {
                continueContent(summary)
            } else {
                shuffleContent
            }
        }
        .navigationTitle(player.resumeSummary == nil ? Text("Flaccy") : Text("Continue"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func continueContent(
        _ summary: (title: String, artist: String, albumTitle: String, artworkData: Data?)
    ) -> some View {
        ScrollView {
            VStack(spacing: 4) {
                if !typeSize.isAccessibilitySize {
                    ArtworkView(data: summary.artworkData, seed: summary.albumTitle, cornerRadius: 14)
                        .frame(width: 80, height: 80)
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                        .accessibilityHidden(true)
                }
                Text(summary.title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(typeSize.isAccessibilitySize ? 4 : 1)
                    .minimumScaleFactor(0.8)
                Text(summary.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                if let point = player.resumePoint {
                    WatchSegmentedProgress(segments: point.segments(), isDimmed: isDimmed)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 6) {
                    Button(action: resume) {
                        Label("Resume", systemImage: "play.fill")
                            .font(.headline)
                            .foregroundStyle(isDimmed ? Color.white : Color.black)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(resumeBackground, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Button(action: shuffle) {
                        Image(systemName: "shuffle")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.18), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Shuffle All"))
                    .disabled(store.allTracks.isEmpty)
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
        }
        .background { backdrop(summary) }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func backdrop(_ summary: (title: String, artist: String, albumTitle: String, artworkData: Data?)) -> some View {
        if !isDimmed {
            ArtworkView(data: summary.artworkData, seed: summary.albumTitle, cornerRadius: 0)
                .blur(radius: 28)
                .opacity(0.5)
                .scaleEffect(1.3)
                .ignoresSafeArea()
                .accessibilityHidden(true)
        }
    }

    private var shuffleContent: some View {
        VStack(spacing: 8) {
            if syncStatus.incoming.isActive || syncStatus.incoming.preparing {
                ReceivingBanner(batch: syncStatus.incoming)
            }
            Button(action: shuffle) {
                VStack(spacing: 4) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 28, weight: .bold))
                    Text("Shuffle All")
                        .font(.title3.weight(.bold))
                    if !store.allTracks.isEmpty {
                        Text(WatchFormat.songs(store.allTracks.count))
                            .font(.caption2.weight(.medium))
                            .opacity(0.75)
                    }
                }
                .foregroundStyle(isDimmed ? Color.white : Color.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(resumeBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(store.allTracks.isEmpty)
            .opacity(store.allTracks.isEmpty ? 0.45 : 1)
            .accessibilityHint(Text("Plays everything on this watch in random order"))
        }
        .padding(.horizontal, 4)
    }

    private var resumeBackground: AnyShapeStyle {
        isDimmed ? AnyShapeStyle(Color.white.opacity(0.22)) : AnyShapeStyle(WatchTheme.accentGradient)
    }

    private func resume() {
        player.resumePlayback()
        onShowNowPlaying()
    }

    private func shuffle() {
        guard !store.allTracks.isEmpty else { return }
        player.shuffleAll(store.allTracks)
        onShowNowPlaying()
    }
}

/// One capsule per track, filled up to where the listener stopped; a single
/// continuous bar when the queue is too long to count.
struct WatchSegmentedProgress: View {

    let segments: [Double]
    var isDimmed = false

    var body: some View {
        GeometryReader { proxy in
            let gap: CGFloat = 2
            let count = CGFloat(max(segments.count, 1))
            let width = (proxy.size.width - gap * (count - 1)) / count
            HStack(spacing: gap) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, fraction in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(isDimmed ? 0.12 : 0.22))
                        Capsule()
                            .fill(isDimmed ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(Color.white))
                            .frame(width: fraction > 0 ? max(width * min(fraction, 1), 3) : 0)
                    }
                    .frame(width: width)
                }
            }
        }
        .frame(height: 4)
    }
}
