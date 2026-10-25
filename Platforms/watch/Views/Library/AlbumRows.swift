import FlaccyCore
import SwiftUI

/// One album as the wrist lists it. VoiceOver hears the title, then the artist,
/// the song count and the runtime as a single value; large type drops the
/// artwork and lets the words wrap instead of clipping.
struct AlbumRow: View {

    @Environment(\.dynamicTypeSize) private var typeSize

    let album: MediaAlbum

    var body: some View {
        HStack(spacing: 10) {
            if !typeSize.isAccessibilitySize {
                ArtworkView(data: album.artworkData, seed: album.id, cornerRadius: 8)
                    .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.headline)
                    .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                Text(album.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: album.title))
        .accessibilityValue(Text(verbatim: spokenSummary))
    }

    private var spokenSummary: String {
        [album.artist, WatchFormat.songs(album.items.count), WatchFormat.runtime(album.totalDuration)]
            .joined(separator: ", ")
    }
}

/// An album row that opens on tap and offers removal from the wrist three ways:
/// a swipe, a long press, and a VoiceOver action — a carousel list hides the
/// swipe from anyone who cannot make the gesture.
struct AlbumListRow: View {

    @Environment(\.requestAlbumRemoval) private var requestRemoval

    let album: MediaAlbum
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AlbumRow(album: album)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                requestRemoval(album)
            } label: {
                Label("Remove from Watch", systemImage: "trash")
            }
        }
        .accessibilityAction(named: Text("Remove from Watch")) { requestRemoval(album) }
        .task {
            guard LibraryShots.removalTarget == album.title else { return }
            try? await Task.sleep(for: .seconds(3))
            requestRemoval(album)
        }
    }
}

/// The most recently received album, marked New and kept above the full list.
struct NewAlbumRow: View {

    @Environment(\.isLuminanceReduced) private var isDimmed

    let album: MediaAlbum
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New")
                    .font(.caption2.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(isDimmed ? Color.secondary : WatchTheme.accent)
                AlbumRow(album: album)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
