import FlaccyCore
import MidgarCore
import Foundation

/// One audio or lyrics file to write into the library, and whether it takes
/// the place of a file already there.
private nonisolated struct ImportJob: Sendable {
    let item: ImportPlan.Item
    let destination: String
    let replacesExisting: Bool
}

/// Copies picked files and folders into the library root. `ImportPlan` decides
/// every destination up front, so a folder keeps its tree, a file already there
/// is skipped, and an import cut short resumes by simply being run again.
/// A newer version of a song already in the library is only written over it
/// after the person agreed, and the file it replaces is kept.
nonisolated enum LibraryImporter {

    /// Runs off the main actor because a document picked from a network
    /// location (Files app over SMB/SSH) streams the whole file inside
    /// `FileManager.copyItem` — main-thread work here freezes the UI for the
    /// length of every transfer.
    static func run(
        _ urls: [URL],
        into directory: URL,
        progress: @escaping @MainActor @Sendable (LibraryImportProgress) -> Void,
        decideReplacements: @escaping ImportReplacementDecider
    ) async -> LibraryImportOutcome {
        await Task.detached(priority: .userInitiated) {
            let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
            let reporter = ImportProgressReporter(deliver: progress)
            reporter.report(.scanning, force: true)

            let plan = ImportPlan.plan(picked: urls, libraryRoot: directory, audioExtensions: Library.audioExtensions)
            let placed = ImportPlan.placements(for: plan, in: directory, inspector: LibraryImportInspector())
            let jobs = await resolvedJobs(placed, in: directory, decideReplacements: decideReplacements)
            let skipped = plan.alreadyInLibrary
                + placed.filter { $0.item.kind == .audio && $0.placement == .alreadyPresent }.count
            if let shortfall = shortfall(for: jobs.map(\.item), at: directory) {
                MidgarLog.notice(
                    "Import refused: needs \(shortfall.needed) bytes, \(shortfall.available) available",
                    category: .content
                )
                return LibraryImportOutcome(imported: 0, skipped: skipped, failed: 0, shortfall: shortfall)
            }

            let total = jobs.filter { $0.item.kind == .audio }.count
            var imported = 0
            var replaced = 0
            var failed = 0
            for job in jobs {
                let target = directory.appendingPathComponent(job.destination)
                do {
                    try write(job, to: target)
                    guard job.item.kind == .audio else { continue }
                    if job.replacesExisting {
                        replaced += 1
                        MidgarLog.info("Replaced with a newer version: \(job.destination)", category: .content)
                    } else {
                        imported += 1
                        MidgarLog.info("Imported: \(job.destination)", category: .content)
                    }
                } catch {
                    MidgarLog.error(
                        "Import failed for \(job.destination)\(job.replacesExisting ? " (the current version was kept)" : ""): \(error.localizedDescription)",
                        category: .content
                    )
                    guard job.item.kind == .audio else { continue }
                    failed += 1
                }
                let done = imported + replaced + failed
                reporter.report(.copying(done: done, total: total), force: done == total)
            }
            MidgarLog.info(
                "Import finished: \(imported) imported, \(replaced) replaced, \(skipped) skipped, \(failed) failed",
                category: .content
            )
            return LibraryImportOutcome(imported: imported, skipped: skipped, failed: failed, replaced: replaced)
        }.value
    }

    /// The writes the plan calls for. When it holds newer versions of songs
    /// already there, the person is asked once; declining files each of them
    /// beside the original at the first free `name_n`.
    private static func resolvedJobs(
        _ placed: [ImportPlan.Placed],
        in directory: URL,
        decideReplacements: ImportReplacementDecider
    ) async -> [ImportJob] {
        let replacements = placed.compactMap { entry -> String? in
            guard case .replace(at: let destination) = entry.placement else { return nil }
            return destination
        }
        var choice = ImportReplacementChoice.replace
        if !replacements.isEmpty {
            let titles = replacements.map { currentTitle(atRelativePath: $0) }
            choice = await decideReplacements(ImportReplacementPrompt(titles: titles))
            MidgarLog.info("Import holds \(replacements.count) newer versions; chose \(choice)", category: .content)
        }
        var taken = Set(placed.compactMap { entry -> String? in
            switch entry.placement {
            case .copy(let destination), .replace(at: let destination): destination
            case .alreadyPresent: nil
            }
        })
        return placed.compactMap { entry -> ImportJob? in
            switch entry.placement {
            case .alreadyPresent:
                return nil
            case .copy(let destination):
                return ImportJob(item: entry.item, destination: destination, replacesExisting: false)
            case .replace(at: let destination):
                guard choice == .keepBoth else {
                    return ImportJob(item: entry.item, destination: destination, replacesExisting: true)
                }
                let free = firstFreeDestination(beside: destination, taken: taken, in: directory)
                taken.insert(free)
                return ImportJob(item: entry.item, destination: free, replacesExisting: false)
            }
        }
    }

    /// The first `stem_n.ext` beside `destination` that is neither on disk nor claimed by this import.
    private static func firstFreeDestination(beside destination: String, taken: Set<String>, in directory: URL) -> String {
        let parent = (destination as NSString).deletingLastPathComponent
        let name = (destination as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        let pathExtension = (name as NSString).pathExtension
        var counter = 1
        while true {
            let renamed = pathExtension.isEmpty ? "\(stem)_\(counter)" : "\(stem)_\(counter).\(pathExtension)"
            let candidate = parent.isEmpty ? renamed : "\(parent)/\(renamed)"
            let onDisk = FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path)
            if !taken.contains(candidate) && !onDisk { return candidate }
            counter += 1
        }
    }

    /// The title the library shows for the song at `path`, or the file's name when it is not indexed yet.
    private static func currentTitle(atRelativePath path: String) -> String {
        let database = DatabaseManager.shared
        let known = (try? database.fetchTrack(byRelativePath: path))
            ?? (try? database.fetchTrack(byRelativePath: canonicalSyncPath(path)))
        if let title = known?.title, !title.isEmpty { return title }
        return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private static func write(_ job: ImportJob, to target: URL) throws {
        guard job.replacesExisting else {
            try copyWithoutClobbering(job.item.source, to: target)
            return
        }
        let staged = try stage(job.item.source, beside: target)
        do {
            try PreviousVersions.replace(
                current: target, with: staged, relativePath: job.destination, now: Date()
            )
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    /// Copies through a hidden `.part` beside the destination and only then
    /// takes the real name, which `moveItem` refuses to overwrite: an import
    /// interrupted mid-song leaves no truncated file under the song's name for
    /// the next run to mistake for a different recording.
    private static func copyWithoutClobbering(_ source: URL, to target: URL) throws {
        let staging = try stage(source, beside: target)
        do {
            try FileManager.default.moveItem(at: staging, to: target)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Writes the `.part` copy of `source` next to `target`. The read is
    /// coordinated so a file provider (iCloud Drive, a network share) can fetch
    /// the bytes first.
    private static func stage(_ source: URL, beside target: URL) throws -> URL {
        let fileManager = FileManager.default
        let parent = target.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".\(target.lastPathComponent).flaccy-part")
        try? fileManager.removeItem(at: staging)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            do {
                try fileManager.copyItem(at: readable, to: staging)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        return staging
    }

    /// Nil when the writes fit or the volume will not say; a cloud placeholder
    /// of unknown size counts as nothing, and its copy fails on its own if the
    /// space runs out after all. A replacement counts in full, because its new
    /// bytes land before the old file moves out of the way.
    private static func shortfall(for items: [ImportPlan.Item], at directory: URL) -> StorageShortfall? {
        let needed = items.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        guard needed > 0,
              let available = try? directory.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
              ).volumeAvailableCapacityForImportantUsage,
              needed > available
        else { return nil }
        return StorageShortfall(needed: needed, available: available)
    }
}
