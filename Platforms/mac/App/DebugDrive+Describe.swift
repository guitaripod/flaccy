import MidgarCore
#if DEBUG
import AppKit

extension DebugDrive {

    /// The sentence after `--describe-sound`, which `--shot-equalizer describe` asks through the real flaccy-api.
    static var describeSentence: String? {
        guard let sentence = value(after: "--describe-sound"), !sentence.hasPrefix("--") else { return nil }
        return sentence
    }

    /// Opens Describe the Sound over the equalizer window. With `--describe-sound <sentence>` it shapes that curve
    /// and waits for it; without one it shows the sheet as it opens. Captures the sheet's own window.
    static func driveDescribe(on screen: MacEqualizerViewController) async {
        let sheet = screen.describeSound()
        try? await Task.sleep(for: .seconds(1))
        if let sentence = describeSentence {
            sheet.ask(sentence)
            for _ in 0..<120 where !sheet.hasSettled {
                try? await Task.sleep(for: .milliseconds(500))
            }
            MidgarLog.info("DebugDrive: describe the sound settled \(sheet.hasSettled)", category: .general)
            try? await Task.sleep(for: .seconds(1))
        }
        capture(window: sheet.view.window, name: "flaccy-shot-equalizer-describe-sheet")
    }
}
#endif
