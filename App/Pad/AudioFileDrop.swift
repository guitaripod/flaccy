import MidgarCore
import UIKit
import UniformTypeIdentifiers

/// Audio files dragged onto the window from another app (Files, Mail, a
/// browser) join the library through the same import as the Files picker:
/// copied in, never duplicated, refused before a byte moves when they will
/// not fit. The file the system hands over is gone once its loader returns,
/// so each is kept first as a hard link in a folder of its own, which costs
/// no space; only where linking fails is it copied, and only when it fits.
final class AudioFileDrop: NSObject, UIDropInteractionDelegate {

    private weak var library: LibraryViewController?
    private weak var host: UIView?

    init(library: LibraryViewController, host: UIView) {
        self.library = library
        self.host = host
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.localDragSession == nil && session.hasItemsConforming(toTypeIdentifiers: [UTType.audio.identifier])
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        let providers = session.items.map(\.itemProvider).filter {
            $0.hasItemConformingToTypeIdentifier(UTType.audio.identifier)
        }
        guard !providers.isEmpty else { return }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("DroppedAudio-\(UUID().uuidString)")
        MidgarLog.info("Audio files dropped on the window: \(providers.count)", category: .content)
        Task { @MainActor [weak self] in
            var staged: [URL] = []
            for (index, provider) in providers.enumerated() {
                if let url = await Self.stage(provider, in: staging.appendingPathComponent(String(index))) {
                    staged.append(url)
                }
            }
            let failed = providers.count - staged.count
            guard let self, let library = self.library else {
                try? FileManager.default.removeItem(at: staging)
                return
            }
            library.importFiles(at: staged, reportingIn: self.host) { [weak self] in
                try? FileManager.default.removeItem(at: staging)
                self?.reportUnreadable(failed)
            }
        }
    }

    private func reportUnreadable(_ count: Int) {
        guard count > 0, let host else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        ToastView.show(
            String(localized: "Couldn't add \(count) of the dropped files: the app they came from didn't hand them over, or there isn't enough free space. Free some up, or add them with Add Music."),
            in: host, style: .error
        )
    }

    /// Keeps one dropped file in `folder` under the name it arrived with, or
    /// returns nil when the other app could not hand it over or there is no
    /// room for a copy. The loader calls back on its own queue, so nothing
    /// here belongs to the main actor.
    nonisolated private static func stage(_ provider: NSItemProvider, in folder: URL) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.audio.identifier) { @Sendable url, error in
                guard let url else {
                    MidgarLog.error("A dropped file could not be read: \(error?.localizedDescription ?? "no file")", category: .content)
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: keep(url, in: folder))
            }
        }
    }

    nonisolated private static func keep(_ url: URL, in folder: URL) -> URL? {
        let manager = FileManager.default
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            if (try? manager.linkItem(at: url, to: destination)) != nil { return destination }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? 0
            guard size < free else {
                MidgarLog.error("A dropped file was refused: \(size) bytes, \(free) free", category: .content)
                return nil
            }
            try manager.copyItem(at: url, to: destination)
            return destination
        } catch {
            MidgarLog.error("A dropped file could not be kept: \(error.localizedDescription)", category: .content)
            return nil
        }
    }
}
