import ActivityKit
import SwiftUI
import WidgetKit

struct FlaccyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FlaccyActivityAttributes.self) { context in
            lockScreenView(context: context)
                .activityBackgroundTint(.black.opacity(0.7))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if let data = context.attributes.artworkData,
                       let uiImage = UIImage(data: data) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Text(context.state.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.isPlaying {
                        soundWaveView()
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        ProgressView(value: context.state.duration > 0 ? context.state.elapsed / context.state.duration : 0)
                            .tint(.white)
                        HStack {
                            Text(formatTime(context.state.elapsed))
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("-\(formatTime(max(0, context.state.duration - context.state.elapsed)))")
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                if let data = context.attributes.artworkData,
                   let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            } compactTrailing: {
                if context.state.isPlaying {
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundStyle(.cyan)
                } else {
                    Image(systemName: "pause.fill")
                        .font(.caption)
                }
            } minimal: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<FlaccyActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            if let data = context.attributes.artworkData,
               let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.ultraThinMaterial)
                    .frame(width: 56, height: 56)
                    .overlay {
                        Image(systemName: "music.note")
                            .foregroundStyle(.secondary)
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(context.state.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text("\(context.state.artist) — \(context.state.albumTitle)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)

                VStack(spacing: 2) {
                    ProgressView(value: context.state.duration > 0 ? context.state.elapsed / context.state.duration : 0)
                        .tint(.white)
                    HStack {
                        Text(formatTime(context.state.elapsed))
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        Text("-\(formatTime(max(0, context.state.duration - context.state.elapsed)))")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }

            Spacer()

            if context.state.isPlaying {
                soundWaveView()
                    .frame(width: 20)
            } else {
                Image(systemName: "pause.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(16)
    }

    private func formatTime(_ time: Double) -> String {
        let total = Int(time)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    @ViewBuilder
    private func soundWaveView() -> some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(.cyan)
                    .frame(width: 3, height: [12, 18, 10][i])
            }
        }
    }
}
