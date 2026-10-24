import FlaccyCore
import SwiftUI

/// Sizes that change between the roomy and the squeezed Now Playing layouts.
struct NowPlayingMetrics: Equatable {
    let artwork: CGFloat
    let playButton: CGFloat
    let skipButton: CGFloat
    let secondaryHeight: CGFloat
    let progressHeight: CGFloat
    let spacing: CGFloat

    /// Fullness runs from 1.5 (every control at its roomiest) down to 0 (the
    /// smallest size that still keeps every target tappable); the view takes
    /// the roomiest one that fits the case it is on.
    static func scaled(_ fullness: CGFloat, screenWidth: CGFloat) -> NowPlayingMetrics {
        NowPlayingMetrics(
            artwork: (screenWidth * (0.2 + 0.14 * fullness)).rounded(),
            playButton: 34 + 12 * fullness,
            skipButton: 30 + 10 * fullness,
            secondaryHeight: 22 + 8 * fullness,
            progressHeight: 14 + 8 * fullness,
            spacing: 1 + 5 * fullness
        )
    }
}

struct TransportRow: View {
    @Environment(WatchAudioPlayer.self) private var player
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let metrics: NowPlayingMetrics

    var body: some View {
        HStack(spacing: 0) {
            skipButton("backward.fill", label: "Previous", action: player.previous)
            Spacer(minLength: 0)
            playPauseButton
            Spacer(minLength: 0)
            skipButton("forward.fill", label: "Next", action: player.next)
        }
        .padding(.horizontal, 6)
    }

    private var playPauseButton: some View {
        Button(action: player.togglePlayPause) {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: metrics.playButton * 0.42, weight: .bold))
                .foregroundStyle(isLuminanceReduced ? Color.white.opacity(0.85) : Color.black.opacity(0.85))
                .frame(width: metrics.playButton + 14, height: metrics.playButton)
                .background(
                    Capsule().fill(isLuminanceReduced ? Color.white.opacity(0.18) : WatchTheme.accent)
                )
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressScaleButtonStyle())
        .handGestureShortcut(.primaryAction)
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
    }

    private func skipButton(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: metrics.skipButton * 0.42, weight: .semibold))
                .foregroundStyle(.white.opacity(isLuminanceReduced ? 0.7 : 1))
                .frame(width: metrics.skipButton + 12, height: metrics.skipButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel(label)
    }
}

struct SecondaryControlsRow: View {
    @Environment(WatchAudioPlayer.self) private var player
    let metrics: NowPlayingMetrics
    let onShowQueue: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            toggleButton(
                "shuffle",
                isActive: player.shuffleEnabled,
                label: "Shuffle",
                value: player.shuffleEnabled ? "On" : "Off",
                action: player.toggleShuffle
            )
            Spacer(minLength: 0)
            toggleButton("list.bullet", isActive: false, label: "Up Next", value: nil, action: onShowQueue)
            Spacer(minLength: 0)
            toggleButton(
                player.repeatMode == .one ? "repeat.1" : "repeat",
                isActive: player.repeatMode != .off,
                label: "Repeat",
                value: repeatValue,
                action: player.cycleRepeatMode
            )
        }
        .padding(.horizontal, 6)
    }

    private var repeatValue: LocalizedStringKey {
        switch player.repeatMode {
        case .off: "Off"
        case .all: "All"
        case .one: "One"
        }
    }

    private func toggleButton(
        _ symbol: String,
        isActive: Bool,
        label: LocalizedStringKey,
        value: LocalizedStringKey?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: metrics.secondaryHeight * 0.46, weight: .semibold))
                .foregroundStyle(isActive ? WatchTheme.accent : Color.white.opacity(0.75))
                .frame(width: metrics.secondaryHeight + 18, height: metrics.secondaryHeight)
                .background(Capsule().fill(isActive ? WatchTheme.accent.opacity(0.22) : Color.white.opacity(0.1)))
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel(label)
        .accessibilityValue(value ?? "")
    }
}

struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
