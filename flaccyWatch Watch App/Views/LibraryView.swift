import FlaccyCore
import SwiftUI

struct LibraryView: View {

    @Environment(WatchLibraryStore.self) private var store
    @Environment(WatchAudioPlayer.self) private var player
    @Environment(WatchSyncStatus.self) private var syncStatus

    let onOpenAlbum: (MediaAlbum) -> Void
    let onShowNowPlaying: () -> Void

    var body: some View {
        Group {
            if store.isLoading && store.albums.isEmpty {
                ProgressView().controlSize(.large)
            } else if store.isEmpty {
                if syncStatus.isReceiving {
                    ReceivingLibraryView()
                } else {
                    EmptyLibraryView(errorReason: syncStatus.lastErrorReason)
                }
            } else {
                content
            }
        }
        .navigationTitle("Flaccy")
        .toolbar {
            if player.currentItem != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onShowNowPlaying) {
                        Image(systemName: "waveform")
                    }
                    .accessibilityLabel("Now Playing")
                }
            }
        }
    }

    private var content: some View {
        List {
            Section {
                Button(action: shuffleAll) {
                    Label("Shuffle All", systemImage: "shuffle")
                        .font(.headline)
                }
                .listRowBackground(
                    WatchTheme.accentGradient.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                )
            }

            Section("Albums") {
                ForEach(store.albums) { album in
                    Button { onOpenAlbum(album) } label: {
                        AlbumRow(album: album)
                    }
                    .buttonStyle(.plain)
                }
            }

            if syncStatus.isReceiving {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Receiving from iPhone…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let notice = SyncErrorNotice(reason: syncStatus.lastErrorReason) {
                Section {
                    Label(notice.message, systemImage: notice.symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.carousel)
    }

    private func shuffleAll() {
        guard !store.allTracks.isEmpty else { return }
        if !player.shuffleEnabled { player.toggleShuffle() }
        player.play(store.allTracks, startingAt: Int.random(in: store.allTracks.indices))
        onShowNowPlaying()
    }
}

struct AlbumRow: View {
    let album: MediaAlbum

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(data: album.artworkData, seed: album.id, cornerRadius: 8)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(album.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

struct EmptyLibraryView: View {
    var errorReason: StoreFailureReason?

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 26))
                    .foregroundStyle(WatchTheme.accentGradient)
                Text("No Music Yet")
                    .font(.headline)
                Text("Sync songs from Flaccy on your iPhone.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let notice = SyncErrorNotice(reason: errorReason) {
                    Label(notice.message, systemImage: notice.symbol)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}

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

struct SyncErrorNotice {
    let message: String
    let symbol: String

    init?(reason: StoreFailureReason?) {
        switch reason {
        case .diskFull:
            message = "Storage full — remove music from your iPhone's Watch screen."
            symbol = "exclamationmark.triangle.fill"
        case .writeFailed:
            message = "Couldn't save a track. It will be retried."
            symbol = "exclamationmark.circle.fill"
        case .sourceMissing, nil:
            return nil
        }
    }
}
