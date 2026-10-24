import FlaccyCore
import SwiftUI

/// The Up Next sheet: the playing track on top, then everything queued after
/// it. Tap a row to jump there, swipe to remove it.
struct QueueView: View {

    @Environment(WatchAudioPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let item = player.currentItem {
                    Section("Now Playing") {
                        NowPlayingRow(item: item, isPlaying: player.isPlaying)
                    }
                }
                Section("Up Next") {
                    if player.upNext.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(player.upNext.enumerated()), id: \.offset) { offset, item in
                            upNextRow(item, absoluteIndex: player.currentIndex + 1 + offset)
                                .id(rowIdentity(at: offset))
                        }
                        clearButton
                    }
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .screenshotScroll()
        }
    }

    /// The first queued song answers to the `upnext` landmark of
    /// `--shot-scroll`; every other row is identified by its position.
    private func rowIdentity(at offset: Int) -> String {
        offset == 0 ? "upnext" : "next-\(offset)"
    }

    private func upNextRow(_ item: MediaItem, absoluteIndex: Int) -> some View {
        Button {
            player.jumpTo(index: absoluteIndex)
            dismiss()
        } label: {
            QueueRowLabel(item: item)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                player.removeFromQueue(at: absoluteIndex)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .accessibilityHint("Plays this track now")
    }

    private var clearButton: some View {
        Button(role: .destructive) {
            player.clearUpNext()
        } label: {
            Label("Clear Up Next", systemImage: "xmark.circle")
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .id("end")
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "text.line.last.and.arrowtriangle.forward")
                .font(.title3)
                .foregroundStyle(WatchTheme.accentGradient)
            Text("Nothing Up Next")
                .font(.footnote.weight(.semibold))
            Text("Touch and hold a song or album to add it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .listRowBackground(Color.clear)
    }
}

private struct NowPlayingRow: View {
    let item: MediaItem
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 8) {
            QueueRowLabel(item: item)
            Image(systemName: "speaker.wave.3.fill")
                .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                .font(.caption)
                .foregroundStyle(WatchTheme.accent)
                .accessibilityLabel(isPlaying ? "Playing" : "Paused")
        }
    }
}

private struct QueueRowLabel: View {
    let item: MediaItem

    var body: some View {
        HStack(spacing: 8) {
            ArtworkView(data: item.artworkData, seed: item.albumTitle + item.artist, cornerRadius: 6)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Text(item.artist)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
