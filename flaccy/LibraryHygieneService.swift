import Foundation

nonisolated struct AlbumRetitle: Sendable {
    let from: String
    let to: String
    let artist: String
}

nonisolated struct KeeperUpdate: Sendable {
    let relativePath: String
    let loved: Bool
    let playCount: Int
}

nonisolated struct AlbumInfoMerge: Sendable {
    let canonicalTitle: String
    let variantTitles: [String]
    let artist: String
}

nonisolated struct HygienePlan: Sendable {
    let duplicateGroups: [LibraryHygiene.DuplicateGroup]
    let consolidationGroups: [LibraryHygiene.ConsolidationGroup]

    var duplicateFileCount: Int { duplicateGroups.reduce(0) { $0 + $1.losers.count } }
    var albumMergeCount: Int { consolidationGroups.reduce(0) { $0 + $1.variants.count } }
    var reclaimedBytes: Int64 {
        duplicateGroups.reduce(0) { total, group in
            total + group.losers.reduce(Int64(0)) { $1.fileSizeOnDisk + $0 }
        }
    }
    var isEmpty: Bool { duplicateFileCount == 0 && albumMergeCount == 0 }
}

/// Computes and applies a library-hygiene plan (duplicate removal + album-edition
/// consolidation). The destructive apply is surfaced only from the desktop
/// targets; the compute step is pure and side-effect-free.
nonisolated enum LibraryHygieneService {

    static func computePlan(albums: [Album], tracks: [Track]) -> HygienePlan {
        HygienePlan(
            duplicateGroups: LibraryHygiene.duplicateGroups(tracks),
            consolidationGroups: LibraryHygiene.consolidationGroups(albums)
        )
    }

    /// Rewrites the database in a single transaction, moves the duplicate losers
    /// to the Trash (recoverable), then republishes from the fresh database.
    @MainActor
    static func apply(_ plan: HygienePlan) async {
        let retitles = plan.consolidationGroups.flatMap { group in
            group.variants.map { AlbumRetitle(from: $0.title, to: group.canonicalTitle, artist: $0.artist) }
        }
        let merges = plan.consolidationGroups.map { group in
            AlbumInfoMerge(
                canonicalTitle: group.canonicalTitle,
                variantTitles: group.variants.map(\.title),
                artist: group.canonicalArtist
            )
        }
        let keeperUpdates = plan.duplicateGroups.map { group in
            KeeperUpdate(
                relativePath: relativePath(for: group.keeper.fileURL),
                loved: group.keeper.loved || group.losers.contains(where: \.loved),
                playCount: max(group.keeper.playCount, group.losers.map(\.playCount).max() ?? 0)
            )
        }
        let loserPaths = plan.duplicateGroups.flatMap { $0.losers.map { relativePath(for: $0.fileURL) } }
        let loserURLs = plan.duplicateGroups.flatMap { $0.losers.map(\.fileURL) }

        await Task.detached(priority: .userInitiated) {
            do {
                try DatabaseManager.shared.applyHygiene(
                    retitles: retitles,
                    keeperUpdates: keeperUpdates,
                    albumInfoMerges: merges,
                    loserRelativePaths: loserPaths
                )
            } catch {
                AppLogger.error("Library cleanup DB write failed: \(error.localizedDescription)", category: .database)
                return
            }
            for url in loserURLs {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    AppLogger.error("Trash failed for \(url.lastPathComponent): \(error.localizedDescription)", category: .content)
                }
            }
        }.value

        if !loserURLs.isEmpty {
            AudioPlayer.shared.handleDeletedTracks(Set(loserURLs))
        }
        await Library.shared.reloadFromDatabase()
        AppLogger.info(
            "Library cleanup: removed \(plan.duplicateFileCount) duplicates, merged \(plan.albumMergeCount) album editions",
            category: .content
        )
    }

    private static func relativePath(for url: URL) -> String {
        let root = LibraryPaths.root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root) else { return url.lastPathComponent }
        let relative = String(path.dropFirst(root.count))
        return relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
    }
}

extension Track {
    var fileSizeOnDisk: Int64 {
        (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }
}
