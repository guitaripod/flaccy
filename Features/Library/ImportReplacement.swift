import Foundation

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The songs an import would replace with newer versions, named by their current titles.
nonisolated struct ImportReplacementPrompt: Sendable, Equatable {
    let titles: [String]
}

nonisolated enum ImportReplacementChoice: Sendable, Equatable {
    case replace
    case keepBoth
}

/// Asked once per import, before any byte moves, when it holds newer versions of songs already in the library.
typealias ImportReplacementDecider = @MainActor @Sendable (ImportReplacementPrompt) async -> ImportReplacementChoice

/// The question an import asks before it replaces anything: the same words on
/// both platforms, in a `UIAlertController` or an `NSAlert`.
@MainActor
enum ImportReplacementAlert {

    static func title(for prompt: ImportReplacementPrompt) -> String {
        if prompt.titles.count == 1, let title = prompt.titles.first {
            return String(localized: "Replace \u{201C}\(title)\u{201D} with a newer version?")
        }
        return String(localized: "Replace \(prompt.titles.count) songs with newer versions?")
    }

    static var message: String {
        String(localized: "The versions you have now stay in Previous Versions for 30 days.")
    }

    #if canImport(UIKit)
    static func ask(_ prompt: ImportReplacementPrompt, from presenter: UIViewController?) async -> ImportReplacementChoice {
        guard var top = presenter else { return .keepBoth }
        while let presented = top.presentedViewController { top = presented }
        let host = top
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: title(for: prompt), message: message, preferredStyle: .alert)
            let keepBoth = UIAlertAction(title: String(localized: "Keep Both"), style: .cancel) { _ in
                UISelectionFeedbackGenerator().selectionChanged()
                continuation.resume(returning: .keepBoth)
            }
            let replace = UIAlertAction(title: String(localized: "Replace"), style: .default) { _ in
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                continuation.resume(returning: .replace)
            }
            alert.addAction(keepBoth)
            alert.addAction(replace)
            alert.preferredAction = replace
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            host.present(alert, animated: true)
        }
    }
    #else
    static func ask(_ prompt: ImportReplacementPrompt, in window: NSWindow?) async -> ImportReplacementChoice {
        let alert = NSAlert()
        alert.messageText = title(for: prompt)
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "Replace"))
        alert.addButton(withTitle: String(localized: "Keep Both"))
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        let response: NSApplication.ModalResponse
        if let window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        return response == .alertFirstButtonReturn ? .replace : .keepBoth
    }
    #endif
}
