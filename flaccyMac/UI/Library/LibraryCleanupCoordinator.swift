import AppKit

enum GroupAlbumEditionsSetting {
    static let key = "groupAlbumEditions"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    static func set(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key)
        Task { await Library.shared.reloadFromDatabase() }
    }
}

/// Drives the desktop "Clean Up Library" flow: compute a dry-run plan off the
/// main actor, show a preview the user must confirm, then apply it. Destructive
/// only in the sense that duplicate files are moved to the Trash (recoverable);
/// album-edition merges are metadata-only.
enum LibraryCleanup {

    @MainActor
    static func run(in window: NSWindow?) {
        let albums = Library.shared.albums
        let tracks = Library.shared.allTracks
        Task {
            let plan = await Task.detached(priority: .userInitiated) {
                LibraryHygieneService.computePlan(albums: albums, tracks: tracks)
            }.value
            presentPreview(plan, in: window)
        }
    }

    @MainActor
    private static func presentPreview(_ plan: HygienePlan, in window: NSWindow?) {
        let alert = NSAlert()
        guard !plan.isEmpty else {
            alert.messageText = "Your Library Is Already Tidy"
            alert.informativeText = "No duplicate tracks or album editions to merge were found."
            alert.icon = NSImage(systemSymbolName: "checkmark.seal", accessibilityDescription: nil)
            alert.addButton(withTitle: "OK")
            present(alert, in: window, onConfirm: nil)
            return
        }

        alert.messageText = "Clean Up Library"
        alert.icon = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        var summary: [String] = []
        if plan.duplicateFileCount > 0 {
            let size = ByteCountFormatter.string(fromByteCount: plan.reclaimedBytes, countStyle: .file)
            summary.append("Remove \(plan.duplicateFileCount) duplicate \(plan.duplicateFileCount == 1 ? "file" : "files"), keeping the highest-quality copy and reclaiming \(size).")
        }
        if plan.albumMergeCount > 0 {
            summary.append("Merge \(plan.albumMergeCount) album \(plan.albumMergeCount == 1 ? "edition" : "editions") into their main album.")
        }
        alert.informativeText = summary.joined(separator: "\n") + "\n\nDuplicate files are moved to the Trash, so nothing is permanently deleted."
        alert.accessoryView = detailView(plan)
        alert.addButton(withTitle: "Clean Up")
        alert.addButton(withTitle: "Cancel")

        present(alert, in: window) {
            Task {
                await LibraryHygieneService.apply(plan)
                MacToast.show(
                    "Cleaned up \(plan.duplicateFileCount) duplicates and \(plan.albumMergeCount) editions.",
                    style: .success,
                    in: window
                )
            }
        }
    }

    @MainActor
    private static func detailView(_ plan: HygienePlan) -> NSView {
        let text = NSTextView()
        text.isEditable = false
        text.drawsBackground = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 4, height: 4)

        var lines: [String] = []
        let mergeLimit = 20
        for group in plan.consolidationGroups.prefix(mergeLimit) {
            let variants = group.variants.map(\.title).joined(separator: ", ")
            lines.append("Merge → \(group.canonicalTitle)\n    from: \(variants)")
        }
        if plan.consolidationGroups.count > mergeLimit {
            lines.append("…and \(plan.consolidationGroups.count - mergeLimit) more album merges")
        }
        let dupLimit = 20
        let dupGroups = plan.duplicateGroups.prefix(dupLimit)
        for group in dupGroups {
            lines.append("Keep → \(group.keeper.title) — \(group.keeper.albumTitle) (\(qualityLabel(group.keeper)))")
        }
        if plan.duplicateGroups.count > dupLimit {
            lines.append("…and \(plan.duplicateGroups.count - dupLimit) more duplicate sets")
        }
        text.string = lines.joined(separator: "\n")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 220))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = text
        text.frame = NSRect(x: 0, y: 0, width: 440, height: 220)
        text.isVerticallyResizable = true
        text.textContainer?.containerSize = NSSize(width: 440, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        return scroll
    }

    private static func qualityLabel(_ track: Track) -> String {
        track.qualityBadge ?? "unknown"
    }

    @MainActor
    private static func present(_ alert: NSAlert, in window: NSWindow?, onConfirm: (() -> Void)?) {
        if let window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { onConfirm?() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            onConfirm?()
        }
    }
}
