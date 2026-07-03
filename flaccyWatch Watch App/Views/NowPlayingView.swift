import FlaccyCore
import SwiftUI

struct NowPlayingView: View {

    @Environment(WatchAudioPlayer.self) private var player

    var body: some View {
        @Bindable var player = player

        Group {
            if let item = player.currentItem {
                VStack(spacing: 7) {
                    trackHeader(item)
                    ProgressBar(progress: player.progress) { fraction in
                        player.seek(to: fraction * player.duration)
                    }
                    timeRow
                    transport
                }
                .padding(.horizontal, 3)
                .focusable()
                .digitalCrownRotation(
                    $player.volume,
                    from: 0, through: 1, by: 0.02,
                    sensitivity: .low,
                    isContinuous: false,
                    isHapticFeedbackEnabled: true
                )
                .overlay(alignment: .topTrailing) {
                    volumeBadge(player.volume).padding([.top, .trailing], 2)
                }
            } else {
                notPlaying
            }
        }
        .navigationTitle("Now Playing")
    }

    private func trackHeader(_ item: MediaItem) -> some View {
        HStack(spacing: 10) {
            ArtworkView(data: item.artworkData, seed: item.albumTitle + item.artist, cornerRadius: 9)
                .frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(item.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var timeRow: some View {
        HStack {
            Text(TimeFormat.string(player.currentTime))
            Spacer()
            Text(TimeFormat.string(player.duration))
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var transport: some View {
        HStack(spacing: 0) {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(player.shuffleEnabled ? WatchTheme.accent : .secondary)
            }
            Spacer(minLength: 0)
            Button { player.previous() } label: {
                Image(systemName: "backward.fill")
            }
            Spacer(minLength: 0)
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(WatchTheme.accent)
            }
            Spacer(minLength: 0)
            Button { player.next() } label: {
                Image(systemName: "forward.fill")
            }
            Spacer(minLength: 0)
            Button { player.cycleRepeatMode() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(player.repeatMode == .off ? .secondary : WatchTheme.accent)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 15, weight: .medium))
        .padding(.horizontal, 2)
    }

    private func volumeBadge(_ volume: Double) -> some View {
        HStack(spacing: 3) {
            Image(systemName: volume <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 8, weight: .semibold))
            Text("\(Int(volume * 100))")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var notPlaying: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "music.note")
                    .font(.system(size: 26))
                    .foregroundStyle(WatchTheme.accentGradient)
                Text("Nothing Playing")
                    .font(.headline)
                Text("Pick an album to start.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}

struct ProgressBar: View {
    let progress: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule()
                    .fill(WatchTheme.accentGradient)
                    .frame(width: max(3, geometry.size.width * progress))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onEnded { value in
                    let fraction = min(1, max(0, value.location.x / geometry.size.width))
                    onSeek(fraction)
                }
            )
        }
        .frame(height: 5)
    }
}
