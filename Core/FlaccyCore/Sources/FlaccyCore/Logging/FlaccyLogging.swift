import Foundation
import MidgarCore

/// Opens the Flaccy log on every Apple client. MidgarLog writes it to `Library/Logs/flaccy.log`, the name the retired
/// per-app logger used, so the `ios-device-logs` workflow and the Mac's `--dump-log` still find it.
public enum FlaccyLogging {
    public static let fileName = "flaccy.log"

    /// Names the log file and removes the archive the retired logger left behind. Call first thing at launch so nothing
    /// before the rest of the setup is lost.
    public static func configure() {
        MidgarLog.configure(fileName: fileName)
        removeRetiredArchive()
    }

    /// Deletes `flaccy.prev.log`. MidgarLog rotates into numbered archives, so nothing writes or reads the old name.
    private static func removeRetiredArchive() {
        guard let library = try? FileManager.default.url(
            for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        else { return }
        try? FileManager.default.removeItem(at: library.appendingPathComponent("Logs/flaccy.prev.log"))
    }
}
