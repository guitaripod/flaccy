#if canImport(UIKit)
import UIKit
#endif

/// Transport feedback: real haptic generators on iOS, silent on macOS where
/// hover and pressed states carry the same role.
struct PlaybackFeedback {

    #if os(iOS)
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let selectionFeedback = UISelectionFeedbackGenerator()
    #endif

    func play(_ kind: PlaybackFeedbackKind) {
        switch kind {
        case .light: light()
        case .medium: medium()
        case .selection: selection()
        }
    }

    func light() {
        #if os(iOS)
        impactLight.impactOccurred()
        #endif
    }

    func medium() {
        #if os(iOS)
        impactMedium.impactOccurred()
        #endif
    }

    func selection() {
        #if os(iOS)
        selectionFeedback.selectionChanged()
        #endif
    }
}
