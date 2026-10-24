import SwiftUI

/// A small pill showing the volume while the Digital Crown is turning.
struct VolumeHUD: View {
    let volume: Double

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 16)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white).frame(width: 46 * volume)
            }
            .frame(width: 46, height: 4)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((volume * 100).rounded())) percent")
    }

    private var symbol: String {
        switch volume {
        case ..<0.01: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
}
