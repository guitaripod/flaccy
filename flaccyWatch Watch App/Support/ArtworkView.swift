import SwiftUI
import UIKit

struct ArtworkView: View {
    let data: Data?
    let seed: String
    var cornerRadius: CGFloat = 12

    var body: some View {
        ZStack {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                WatchTheme.placeholderGradient(seed: seed)
                Image(systemName: "music.note")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
