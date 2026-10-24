import FlaccyCore
import SwiftUI
import WatchKit

struct NowPlayingView: View {

    var body: some View {
        NowPlayingScreen().screenshotEnvironment()
    }
}

private struct NowPlayingScreen: View {

    @Environment(WatchAudioPlayer.self) private var player
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    @State private var tint: ArtworkTint?
    @State private var scrubFraction: Double?
    @State private var isShowingQueue = NowPlayingScreen.opensQueueForScreenshots
    @State private var isVolumeVisible = false
    @State private var volumeChangeCount = 0

    /// Simulator-only screenshot hook: `--shot-queue` opens the Up Next sheet
    /// at once, since the simulator cannot be tapped from the command line.
    private static var opensQueueForScreenshots: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--shot-queue")
        #else
        false
        #endif
    }

    private static let volumeHUDDuration: Duration = .milliseconds(1500)

    var body: some View {
        @Bindable var player = player

        Group {
            if let item = player.currentItem {
                nowPlaying(item)
                    .focusable()
                    .digitalCrownRotation(
                        $player.volume,
                        from: 0, through: 1, by: 0.02,
                        sensitivity: .low,
                        isContinuous: false,
                        isHapticFeedbackEnabled: true
                    )
                    .overlay(alignment: .top) { volumeOverlay }
                    .onChange(of: player.volume) { volumeDidChange() }
                    .task(id: isVolumeVisible ? volumeChangeCount : -1) { await hideVolumeAfterPause() }
                    .sheet(isPresented: $isShowingQueue) { QueueView() }
            } else {
                notPlaying
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .containerBackground(for: .navigation) { background }
        .task(id: player.currentItem?.id) { await refreshTint() }
    }

    private func nowPlaying(_ item: MediaItem) -> some View {
        let width = WKInterfaceDevice.current().screenBounds.width
        return ViewThatFits(in: .vertical) {
            layout(item, metrics: .scaled(1.5, screenWidth: width))
            layout(item, metrics: .scaled(1.25, screenWidth: width))
            layout(item, metrics: .scaled(1, screenWidth: width))
            layout(item, metrics: .scaled(0.75, screenWidth: width))
            layout(item, metrics: .scaled(0.5, screenWidth: width))
            layout(item, metrics: .scaled(0.25, screenWidth: width))
            layout(item, metrics: .scaled(0, screenWidth: width))
            ScrollView { layout(item, metrics: .scaled(0, screenWidth: width)) }
        }
        .padding(.horizontal, 2)
    }

    private func layout(_ item: MediaItem, metrics: NowPlayingMetrics) -> some View {
        VStack(spacing: metrics.spacing) {
            header(item, metrics: metrics)
            scrubber(metrics)
            TransportRow(metrics: metrics)
            if !isLuminanceReduced {
                SecondaryControlsRow(metrics: metrics) { isShowingQueue = true }
            }
        }
    }

    private func header(_ item: MediaItem, metrics: NowPlayingMetrics) -> some View {
        HStack(spacing: 9) {
            ArtworkView(data: item.artworkData, seed: item.albumTitle + item.artist, cornerRadius: 10)
                .frame(width: metrics.artwork, height: metrics.artwork)
                .opacity(isLuminanceReduced ? 0.7 : 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                MarqueeText(text: item.title, font: .headline, isAnimated: !isLuminanceReduced)
                MarqueeText(text: item.artist, font: .caption, isAnimated: !isLuminanceReduced)
                    .foregroundStyle(.white.opacity(isLuminanceReduced ? 0.6 : 0.72))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func scrubber(_ metrics: NowPlayingMetrics) -> some View {
        VStack(spacing: 0) {
            NowPlayingProgressBar(
                progress: player.progress,
                duration: player.duration,
                isDimmed: isLuminanceReduced,
                height: metrics.progressHeight,
                scrubFraction: $scrubFraction,
                onSeek: seek
            )
            timeRow
        }
    }

    private var timeRow: some View {
        let shownTime = scrubFraction.map { $0 * player.duration } ?? player.currentTime
        return HStack {
            Text(TimeFormat.string(shownTime))
            Spacer()
            Text("-" + TimeFormat.string(max(0, player.duration - shownTime)))
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.white.opacity(0.6))
        .opacity(isLuminanceReduced ? 0 : 1)
        .accessibilityHidden(true)
    }

    private func seek(to fraction: Double) {
        player.seek(to: fraction * player.duration)
        WKInterfaceDevice.current().play(.click)
    }

    private var volumeOverlay: some View {
        VolumeHUD(volume: player.volume)
            .opacity(isVolumeVisible && !isLuminanceReduced ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: isVolumeVisible)
            .allowsHitTesting(false)
    }

    private func volumeDidChange() {
        isVolumeVisible = true
        volumeChangeCount &+= 1
    }

    /// The pill stays only while the crown keeps moving: each turn restarts
    /// this wait, and the fade begins once the crown has been still.
    private func hideVolumeAfterPause() async {
        guard isVolumeVisible else { return }
        try? await Task.sleep(for: Self.volumeHUDDuration)
        guard !Task.isCancelled else { return }
        isVolumeVisible = false
    }

    private func refreshTint() async {
        guard let item = player.currentItem else {
            tint = nil
            return
        }
        let found = await ArtworkTintCache.shared.tint(for: item)
        withAnimation(.easeInOut(duration: 0.6)) { tint = found }
    }

    @ViewBuilder
    private var background: some View {
        if isLuminanceReduced {
            Color.black
        } else if let tint {
            tint.gradient
        } else if let item = player.currentItem {
            WatchTheme.placeholderGradient(seed: item.albumTitle + item.artist)
        } else {
            Color.black
        }
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
