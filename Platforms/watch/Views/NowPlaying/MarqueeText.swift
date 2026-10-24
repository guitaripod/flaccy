import SwiftUI

/// One line of text that sits still when it fits and drifts to its end and
/// back, slowly, when it does not, so a long title is never cut to nothing.
struct MarqueeText: View {
    let text: String
    var font: Font = .body
    var alignment: Alignment = .leading
    var isAnimated: Bool = true

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private static let pointsPerSecond: Double = 16
    private static let edgePause: Duration = .seconds(1.6)

    private var overflow: CGFloat { max(0, textWidth - containerWidth) }

    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity)
            .overlay(alignment: overflow > 0 ? .leading : alignment) {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize()
                    .offset(x: offset)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            }
            .clipped()
            .mask(edgeFade)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
            .task(id: DriftKey(text: text, overflow: overflow, isAnimated: isAnimated)) { await drift() }
            .accessibilityElement()
            .accessibilityLabel(text)
    }

    private var edgeFade: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: overflow > 0 ? 0.92 : 1),
                .init(color: .black.opacity(overflow > 0 ? 0.1 : 1), location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private struct DriftKey: Equatable {
        let text: String
        let overflow: CGFloat
        let isAnimated: Bool
    }

    /// Waits at each end, then slides to the other, until cancelled by a new
    /// title, a new width, or the screen going dim.
    private func drift() async {
        offset = 0
        guard isAnimated, overflow > 1 else { return }
        let travel = Double(overflow) / Self.pointsPerSecond
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.edgePause)
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: travel)) { offset = -overflow }
            try? await Task.sleep(for: .seconds(travel) + Self.edgePause)
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: travel)) { offset = 0 }
            try? await Task.sleep(for: .seconds(travel))
        }
    }
}
