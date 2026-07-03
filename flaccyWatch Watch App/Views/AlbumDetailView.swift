import FlaccyCore
import SwiftUI

struct AlbumDetailView: View {

    @Environment(WatchAudioPlayer.self) private var player
    let album: MediaAlbum
    let onShowNowPlaying: () -> Void

    var body: some View {
        List {
            Section {
                header
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
            Section {
                ForEach(Array(album.items.enumerated()), id: \.element.id) { index, item in
                    Button { play(at: index) } label: {
                        TrackRow(item: item, index: index, isCurrent: player.currentItem == item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(album.title)
    }

    private var header: some View {
        VStack(spacing: 8) {
            ArtworkView(data: album.artworkData, seed: album.id, cornerRadius: 16)
                .frame(width: 96, height: 96)
            Text(album.title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(album.artist)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(action: { play(at: 0) }) {
                    Label("Play", systemImage: "play.fill")
                }
                Button(action: playShuffled) {
                    Image(systemName: "shuffle")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(WatchTheme.accent)
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    private func play(at index: Int) {
        player.play(album.items, startingAt: index)
        onShowNowPlaying()
    }

    private func playShuffled() {
        guard !album.items.isEmpty else { return }
        if !player.shuffleEnabled { player.toggleShuffle() }
        player.play(album.items, startingAt: Int.random(in: album.items.indices))
        onShowNowPlaying()
    }
}

struct TrackRow: View {
    let item: MediaItem
    let index: Int
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(WatchTheme.accent)
                    .frame(width: 18)
            } else {
                Text("\(item.trackNumber > 0 ? item.trackNumber : index + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }
            Text(item.title)
                .font(.body)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }
}
