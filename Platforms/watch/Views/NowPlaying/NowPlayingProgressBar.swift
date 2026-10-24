import SwiftUI

/// The thin scrubber under the track header. It follows playback, thickens
/// under a finger, shows where a seek will land while dragging, and commits
/// the seek when the finger lifts.
struct NowPlayingProgressBar: View {
    let progress: Double
    let duration: TimeInterval
    let isDimmed: Bool
    let height: CGFloat
    @Binding var scrubFraction: Double?
    let onSeek: (Double) -> Void

    private static let accessibilityStep: TimeInterval = 10

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(isDimmed ? 0.12 : 0.22))
                Capsule()
                    .fill(isDimmed ? AnyShapeStyle(.white.opacity(0.55)) : AnyShapeStyle(WatchTheme.accentGradient))
                    .frame(width: max(4, geometry.size.width * (scrubFraction ?? progress)))
            }
            .frame(height: scrubFraction == nil ? 5 : 9)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(scrubGesture(width: geometry.size.width))
            .animation(.easeOut(duration: 0.15), value: scrubFraction == nil)
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(TimeFormat.string(progress * duration)) of \(TimeFormat.string(duration))")
        .accessibilityAdjustableAction(adjust)
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in scrubFraction = fraction(at: value.location.x, width: width) }
            .onEnded { value in
                scrubFraction = nil
                onSeek(fraction(at: value.location.x, width: width))
            }
    }

    private func fraction(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(1, max(0, Double(x / width)))
    }

    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        guard duration > 0 else { return }
        let step = Self.accessibilityStep / duration
        switch direction {
        case .increment: onSeek(min(1, progress + step))
        case .decrement: onSeek(max(0, progress - step))
        @unknown default: break
        }
    }
}
