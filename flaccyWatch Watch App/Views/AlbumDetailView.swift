import FlaccyCore
import SwiftUI

struct AlbumDetailView: View {

    @Environment(WatchAudioPlayer.self) private var player
    let album: MediaAlbum
    let onShowNowPlaying: () -> Void
    var onRemoved: () -> Void = {}

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
                    .swipeActions(edge: .leading, allowsFullSwipe: false) { queueActions(for: [item]) }
                    .id(rowIdentity(at: index, of: item))
                }
            }
            Section {
                RemoveAlbumButton(album: album)
            } footer: {
                removeFootnote
            }
        }
        .navigationTitle(album.title)
        .albumRemovalFlow(onRemoved: onRemoved)
        .screenshotScroll(anchor: .bottom)
    }

    /// The first song answers to the `tracks` landmark of `--shot-scroll`;
    /// every other row keeps its own identity.
    private func rowIdentity(at index: Int, of item: MediaItem) -> String {
        index == 0 ? "tracks" : item.id
    }

    private var removeFootnote: some View {
        Text("Frees \(WatchFormat.bytes(AlbumRemoval.footprint(of: [album]))). It stays on your iPhone.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .textCase(nil)
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
        .swipeActions(edge: .leading, allowsFullSwipe: false) { queueActions(for: album.items) }
    }

    @ViewBuilder
    private func queueActions(for items: [MediaItem]) -> some View {
        Button {
            player.playNext(items)
        } label: {
            Label("Play Next", systemImage: "text.insert")
        }
        Button {
            player.enqueue(items)
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }
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
