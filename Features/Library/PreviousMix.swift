import FlaccyCore
import FlaccyEngine
import MidgarCore
import Foundation

/// Putting a song's previous version back, from any track menu.
@MainActor
enum PreviousMix {

    /// Whether a replaced version of this track is still kept.
    static func isAvailable(for track: Track) -> Bool {
        DatabaseManager.shared.hasPreviousVersion(trackFileURL: LibraryPaths.relativePath(of: track.fileURL))
    }

    /// Swaps the track's file with its previous version, stores the restored
    /// audio's signature and fingerprint without counting a new revision, and
    /// refreshes the library so every list shows the restored tags.
    static func restore(_ track: Track) async -> Result<Void, PreviousVersionError> {
        let relativePath = LibraryPaths.relativePath(of: track.fileURL)
        let result = await swapFiles(relativePath: relativePath, libraryRoot: LibraryPaths.root)
        switch result {
        case .success:
            MidgarLog.info("Restored the previous mix of \(relativePath)", category: .content)
            await Library.shared.reloadFromDatabase()
        case .failure(let error):
            MidgarLog.error("Restoring the previous mix of \(relativePath) failed: \(error.localizedDescription)", category: .content)
        }
        return result
    }

    @concurrent
    private nonisolated static func swapFiles(
        relativePath: String, libraryRoot: URL
    ) async -> Result<Void, PreviousVersionError> {
        do {
            try PreviousVersions.swapWithPrevious(relativePath: relativePath, libraryRoot: libraryRoot, now: Date())
        } catch let error as PreviousVersionError {
            return .failure(error)
        } catch {
            return .failure(.swapFailed(underlying: error))
        }
        await storeRestoredVersion(relativePath: relativePath, libraryRoot: libraryRoot)
        return .success(())
    }

    /// The restored file keeps the revision the track already had and is not a
    /// fresh mix, so it carries no `revisedAt`.
    private nonisolated static func storeRestoredVersion(relativePath: String, libraryRoot: URL) async {
        let url = libraryRoot.appendingPathComponent(relativePath)
        let database = DatabaseManager.shared
        let revision = (try? database.fetchStoredVersion(relativePath: relativePath))?.revision ?? 1
        let version = StoredVersion(
            signature: AudioFingerprinter.signature(of: url),
            fingerprint: AudioFingerprinter.fingerprint(of: url),
            revision: revision,
            revisedAt: nil
        )
        let refresh = await MetadataService.refresh(from: url)
        do {
            try database.refreshMetadata(relativePath: relativePath, with: refresh, storing: version)
        } catch {
            MidgarLog.error("Storing the restored version of \(relativePath) failed: \(error.localizedDescription)", category: .database)
        }
    }
}
