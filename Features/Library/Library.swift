import FlaccyCore
import MidgarCore
import Foundation

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

nonisolated struct LibraryImportOutcome: Sendable, Equatable {
    let imported: Int
    let skipped: Int
    let failed: Int
    var shortfall: StorageShortfall? = nil
    var replaced: Int = 0

    static let empty = LibraryImportOutcome(imported: 0, skipped: 0, failed: 0)
}

/// An import refused before a byte moved, because what it would copy does not
/// fit in the space the device is willing to give it.
nonisolated struct StorageShortfall: Sendable, Equatable {
    let needed: Int64
    let available: Int64
}

/// What one pass over the library folder found: whether the index changed, and
/// the paths that are both on disk and already indexed, which the revision pass
/// checks for a newer version of a song.
nonisolated struct LibrarySyncResult: Sendable {
    let changed: Bool
    let indexedOnDisk: Set<String>

    static let unchanged = LibrarySyncResult(changed: false, indexedOnDisk: [])
}

/// Where a running import is, counted in songs: the walk over the picked
/// folders first, then each file copied. Lyrics sidecars ride along uncounted.
nonisolated enum LibraryImportProgress: Sendable, Equatable {
    case scanning
    case copying(done: Int, total: Int)
}

/// One album cover the scan has just moved out of a file and into the database,
/// announced while the tags are still being read.
///
/// It carries both spellings on purpose. `albumTitle`/`artist` are the raw tag
/// values the `albumInfo` row was written under, so an artwork lookup hits its
/// exact-match arm; `tileKey` is the identity the album model will eventually
/// have, so the mosaic dedupes this tile against the post-build pass.
nonisolated struct HoistedAlbumCover: Sendable, Hashable {
    let albumTitle: String
    let artist: String
    let tileKey: String
}

protocol LibraryProviding: AnyObject {
    var albums: [Album] { get }
    var allTracks: [Track] { get }
    var isLoading: Bool { get }
    var isRestoringIndexedLibrary: Bool { get }
    var isListingPartial: Bool { get }
    var loadProgress: LibraryLoadProgress { get }
    var loadFraction: Double { get }
    func reload() async
    func resetAndReload() async
    func reloadFromDatabase() async
    func rescanIfFolderChanged(checkingVersions: Bool) async
    func debutSummary() async -> LibraryDebutSummary
    @discardableResult
    func importFiles(
        from urls: [URL],
        progress: @escaping @MainActor @Sendable (LibraryImportProgress) -> Void,
        decideReplacements: @escaping ImportReplacementDecider
    ) async -> LibraryImportOutcome
    func deleteTracks(_ tracks: [Track]) async
    func settleRevisions() async
    func version(of track: Track) -> TrackVersion?
}

extension LibraryProviding {

    func rescanIfFolderChanged(checkingVersions: Bool) async {}

    /// An import with nobody to ask: a newer version of a song already in the
    /// library is kept beside it rather than replacing it.
    @discardableResult
    func importFiles(
        from urls: [URL],
        progress: @escaping @MainActor @Sendable (LibraryImportProgress) -> Void
    ) async -> LibraryImportOutcome {
        await importFiles(from: urls, progress: progress, decideReplacements: { _ in .keepBoth })
    }
}

final class Library: LibraryProviding {

    static let shared: LibraryProviding = Library()

    /// Every format the Apple clients index and import; the Mac's drop target
    /// filters on the same set.
    nonisolated static let audioExtensions: Set<String> = [
        "flac", "m4a", "aac", "alac", "mp3", "wav", "aiff", "aif", "caf",
    ]
    nonisolated static let didUpdateNotification = Notification.Name("LibraryDidUpdate")
    nonisolated static let loadingStateChanged = Notification.Name("LibraryLoadingStateChanged")
    nonisolated static let progressDidChange = Notification.Name("LibraryLoadProgressChanged")
    nonisolated static let albumCoversHoisted = Notification.Name("LibraryAlbumCoversHoisted")
    nonisolated static let tracksRevised = Notification.Name("LibraryTracksRevised")

    nonisolated enum ProgressKey {
        static let progress = "progress"
        static let fraction = "fraction"
    }

    nonisolated enum CoverKey {
        static let covers = "covers"
    }

    nonisolated enum RevisionKey {
        static let paths = "paths"
    }

    private(set) var albums: [Album] = []
    private(set) var allTracks: [Track] = []

    /// Whether `albums` can be believed yet: the library a previous launch
    /// indexed is back, or the first load has finished with whatever there is.
    private(set) var hasSettledFirstLoad = false

    /// True while a library some earlier launch indexed is not back yet, the
    /// window in which `albums` is empty only because nothing has been read.
    /// Home holds its first frame through it, so a full library never opens on
    /// the card that brings music in.
    var isRestoringIndexedLibrary: Bool {
        LibraryStartupProbe.hadIndexedLibrary && !hasSettledFirstLoad
    }

    /// True while `albums` holds the songs a first scan has read so far rather
    /// than the whole library. Anything that would forget a song because it is
    /// missing (a watch request, a wantlist entry) waits until this is false;
    /// the final `didUpdateNotification` of the scan always comes after it.
    private(set) var isListingPartial = false

    /// Set while a scan that started from an empty library is reading tags, the
    /// window in which `publishListingIfDue()` shows the songs found so far.
    private var listingScan: LiveListingPace?
    private var isListingInFlight = false
    private var listingGeneration = 0

    private var revisedVersions: [URL: TrackVersion] = [:]
    private(set) var isLoading: Bool = false {
        didSet { NotificationCenter.default.post(name: Library.loadingStateChanged, object: nil) }
    }

    nonisolated private let progressTracker = LibraryLoadProgressTracker()

    nonisolated var loadProgress: LibraryLoadProgress { progressTracker.progress }
    nonisolated var loadFraction: Double { progressTracker.displayFraction }

    /// Publishes a coalesced progress snapshot; updates too small to see are
    /// dropped by the tracker rather than waking the main thread per file.
    nonisolated private func emitProgress(
        force: Bool = false, _ mutate: (inout LibraryLoadProgress) -> Void
    ) {
        guard let updated = progressTracker.update(force: force, mutate) else { return }
        NotificationCenter.default.post(
            name: Library.progressDidChange,
            object: nil,
            userInfo: [
                ProgressKey.progress: updated,
                ProgressKey.fraction: progressTracker.displayFraction,
            ]
        )
    }

    /// Ends the load on the fraction the tracker actually reached. Every phase
    /// left in the bar is bounded disk work, so a completed scan reports a real
    /// 1.0 and a scan that stopped short reports where it stopped, instead of
    /// the flat 1.0 the old network phases could never honestly claim.
    nonisolated private func finishProgress() {
        let reached = progressTracker.displayFraction
        let idle = progressTracker.finish()
        NotificationCenter.default.post(
            name: Library.progressDidChange,
            object: nil,
            userInfo: [ProgressKey.progress: idle, ProgressKey.fraction: reached]
        )
    }

    let db = DatabaseManager.shared

    nonisolated var documentsDirectory: URL {
        LibraryPaths.root
    }

    private var isReloading = false
    private var reloadPending = false
    private var unsettledFolderChange: Set<String> = []

    /// How long a new file must have been left alone before the index reads it.
    nonisolated private static let settleInterval: TimeInterval = 10

    nonisolated private enum FolderComparison: Sendable {
        case inSync(indexedOnDisk: Set<String>)
        case changed(Set<String>)
        case settling
    }

    var revisionTask: Task<Void, Never>?
    var pendingRevisionPaths: Set<String>?

    func reload() async {
        if isReloading {
            reloadPending = true
            return
        }
        isReloading = true
        defer {
            isReloading = false
            finishProgress()
        }
        repeat {
            reloadPending = false
            await doReload()
        } while reloadPending
    }

    /// Brings the index level with the folder after the app has been running:
    /// songs copied in over a cable, from the Files app or from a computer, and
    /// songs removed the same way. It looks first and says nothing when the
    /// folder and the index agree, so a screen is never told about a scan that
    /// found nothing; only a difference starts a full `reload()`. A difference
    /// that a reload could not settle is not reloaded again until it changes,
    /// and a file written a moment ago is left for the next look, since a copy
    /// still arriving would be indexed half read. `checkingVersions` also runs
    /// the revision pass, for a song replaced in place.
    func rescanIfFolderChanged(checkingVersions: Bool) async {
        guard hasSettledFirstLoad, !isReloading else { return }
        switch await compareFolderWithIndex() {
        case .settling:
            return
        case .inSync(let indexedOnDisk):
            unsettledFolderChange = []
            if checkingVersions { scheduleRevisionPass(for: indexedOnDisk) }
        case .changed(let paths):
            guard paths != unsettledFolderChange else { return }
            unsettledFolderChange = paths
            MidgarLog.info("Library folder changed while running: \(paths.count) songs added or removed, rescanning", category: .content)
            await reload()
        }
    }

    @concurrent
    nonisolated private func compareFolderWithIndex() async -> FolderComparison {
        guard let diskPaths = audioPathsOnDisk() else { return .settling }
        let knownPaths: Set<String>
        do {
            knownPaths = try db.fetchAllTrackRelativePaths()
        } catch {
            MidgarLog.error("DB fetch paths error: \(error.localizedDescription)", category: .database)
            return .settling
        }
        let added = diskPaths.subtracting(knownPaths)
        let removed = knownPaths.subtracting(diskPaths)
        guard !added.isEmpty || !removed.isEmpty else {
            return .inSync(indexedOnDisk: diskPaths.subtracting(ScanJournal.quarantinedPaths()))
        }
        guard !added.contains(where: wasWrittenJustNow) else { return .settling }
        return .changed(added.union(removed))
    }

    /// Whether the file changed within `settleInterval` of now, which a copy
    /// still in flight keeps doing and a finished one stops doing. A modified
    /// date far in the future, from a computer with its clock or zone wrong, is
    /// not a copy in flight and must not keep the song out of the library.
    nonisolated private func wasWrittenJustNow(_ relativePath: String) -> Bool {
        let url = documentsDirectory.appendingPathComponent(relativePath, isDirectory: false)
        guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return false }
        return abs(Date().timeIntervalSince(modified)) < Self.settleInterval
    }

    private func doReload() async {
        let firstLoad = albums.isEmpty
        if firstLoad {
            isLoading = true
            emitProgress(force: true) { $0 = LibraryLoadProgress(phase: .openingLibrary) }
            await restoreLastIndexedLibrary()
        }

        emitProgress(force: true) { $0.phase = .findingFiles }
        if albums.isEmpty { listingScan = LiveListingPace(began: .now) }
        let sync = await syncFilesWithDatabase()
        endListingScan()
        let syncChanged = sync.changed

        let rereads = syncChanged || (firstLoad && albums.isEmpty)
        if rereads || firstLoad {
            emitProgress(force: true) { $0.phase = .buildingAlbums; $0.completed = 0; $0.total = 0 }
            if rereads {
                await loadFromDatabase()
            } else {
                await settleRestoredCredits()
            }
            publishLibraryTallies()
            MidgarLog.info("Library: \(albums.count) albums, \(allTracks.count) tracks", category: .content)
            Task { await ServerSyncService.engine.resolveGhosts() }
        }

        hasSettledFirstLoad = true
        isListingPartial = false
        NotificationCenter.default.post(name: Library.didUpdateNotification, object: nil)
        isLoading = false

        Task { await EnrichmentCoordinator.shared.resume() }
        LyricsPrecache.shared.refresh()
        if firstLoad {
            Task.detached(priority: .utility) { PreviousVersions.purgeExpired(now: Date()) }
        }
        scheduleRevisionPass(for: sync.indexedOnDisk)
    }

    /// Shows a first scan's songs while it is still reading tags, so a large
    /// library is browsable and playable seconds into its first scan instead
    /// of after its last file. `LiveListingPace` keeps the rebuilds rare
    /// enough that the screens redrawing never add up to a stall, and a
    /// listing that finishes after the scan has moved on is dropped.
    private func publishListingIfDue() async {
        guard let pace = listingScan, !isListingInFlight, pace.isDue(at: .now) else { return }
        isListingInFlight = true
        let generation = listingGeneration
        let loaded = try? await fetchAlbumsFromDatabase(resolvingCredits: false)
        isListingInFlight = false
        guard let loaded, !loaded.isEmpty, generation == listingGeneration, listingScan != nil else { return }
        listingScan?.noteListed(at: .now)
        adopt(loaded)
        isListingPartial = true
        hasSettledFirstLoad = true
        MidgarLog.info("Listing while scanning: \(albums.count) albums, \(allTracks.count) tracks", category: .content)
        NotificationCenter.default.post(name: Library.didUpdateNotification, object: nil)
    }

    private func endListingScan() {
        listingScan = nil
        listingGeneration += 1
    }

    /// Shows whatever was indexed on a previous run before any disk work
    /// starts, so a relaunch lands on a usable library in milliseconds and the
    /// scan that follows is progress a person can watch rather than a wall.
    /// Album credits are read as the last run settled them: resolving them is
    /// a write over every row, and the load after the scan does it anyway.
    private func restoreLastIndexedLibrary() async {
        let began = DispatchTime.now().uptimeNanoseconds
        await loadFromDatabase(resolvingCredits: false)
        guard !albums.isEmpty else { return }
        hasSettledFirstLoad = true
        publishLibraryTallies()
        let milliseconds = (DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
        MidgarLog.info("Library restored: \(albums.count) albums in \(milliseconds) ms", category: .performance)
        NotificationCenter.default.post(name: Library.didUpdateNotification, object: nil)
    }

    /// The restore read album credits as the last run left them. With nothing
    /// on disk changed they are almost always still right, so they are settled
    /// on their own and the library is read again only when one moved, instead
    /// of a second full read while Home is building its first frame.
    private func settleRestoredCredits() async {
        guard await settleAlbumCredits() > 0 else { return }
        await loadFromDatabase(resolvingCredits: false)
    }

    @concurrent
    nonisolated private func settleAlbumCredits() async -> Int {
        do {
            return try db.resolveAlbumCredits()
        } catch {
            MidgarLog.error("Failed to settle album credits: \(error.localizedDescription)", category: .database)
            return 0
        }
    }

    /// Publishes the tallies, and closes `.buildingAlbums` out on a real total so
    /// a finished load reports 1.0 instead of the half credit an indeterminate
    /// phase is given — the bar used to stall at 92.5% and then vanish.
    ///
    /// The phase guard is load-bearing: `restoreLastIndexedLibrary()` calls this
    /// during `.openingLibrary`, and a completed count left behind there would
    /// make the file sweep that follows look determinate and already done.
    /// `max(albumCount, 1)` keeps an empty folder from staying indeterminate.
    private func publishLibraryTallies() {
        let albumCount = albums.count
        let trackCount = allTracks.count
        emitProgress(force: true) {
            $0.albumsBuilt = albumCount
            $0.tracksIndexed = max($0.tracksIndexed, trackCount)
            guard $0.phase == .buildingAlbums else { return }
            $0.total = max(albumCount, 1)
            $0.completed = $0.total
        }
    }

    /// Re-reads the album/track model from the database and republishes,
    /// unconditionally. Needed after a metadata-only mutation (album retitle,
    /// play-count transfer) that leaves files untouched, so `reload()`'s
    /// file-sync short-circuit would otherwise skip the refresh.
    func reloadFromDatabase() async {
        await loadFromDatabase()
        NotificationCenter.default.post(name: Library.didUpdateNotification, object: nil)
    }

    func resetAndReload() async {
        isLoading = true
        defer { finishProgress() }
        emitProgress(force: true) { $0 = LibraryLoadProgress(phase: .openingLibrary) }
        MidgarLog.info("=== RESETTING LIBRARY ENRICHMENT STATE ===", category: .database)
        discardEnrichmentState()

        emitProgress(force: true) { $0.phase = .findingFiles }
        let sync = await syncFilesWithDatabase()
        emitProgress(force: true) { $0.phase = .buildingAlbums; $0.completed = 0; $0.total = 0 }
        await loadFromDatabase()
        publishLibraryTallies()
        logLibraryState()
        NotificationCenter.default.post(name: Library.didUpdateNotification, object: nil)
        isLoading = false
        forgetIndexedLibrary()

        Task { await EnrichmentCoordinator.shared.resume() }
        LyricsPrecache.shared.refresh()
        scheduleRevisionPass(for: sync.indexedOnDisk)
    }

    /// Puts every durable enrichment verdict back to "never attempted": the AI
    /// flags, every `enrichmentState` row, and the once-per-library Debut. A
    /// reset that kept the negative cache would find nothing due and quietly do
    /// nothing at all.
    private func discardEnrichmentState() {
        do {
            try db.resetAllAIAnalyzed()
            try db.deleteAllEnrichmentState()
            try db.clearLibraryDebut()
        } catch {
            MidgarLog.error("Failed to reset enrichment state: \(error.localizedDescription)", category: .database)
        }
    }

    /// Forgets that any earlier launch indexed this library, so the next launch
    /// earns the Debut again. Cleared last, because the rebuild this reset just
    /// ran marks the library indexed on its way through `loadFromDatabase()`.
    private func forgetIndexedLibrary() {
        LibraryStartupProbe.clear()
    }

    @discardableResult
    func importFiles(
        from urls: [URL],
        progress: @escaping @MainActor @Sendable (LibraryImportProgress) -> Void,
        decideReplacements: @escaping ImportReplacementDecider
    ) async -> LibraryImportOutcome {
        let outcome = await LibraryImporter.run(
            urls, into: documentsDirectory, progress: progress, decideReplacements: decideReplacements
        )
        FunnelSignals.shared.noteImport(outcome)
        await reload()
        return outcome
    }

    /// Deleting the files is the single source of truth — the reload's file
    /// sync then drops the database rows, playlist entries, and UI state.
    func deleteTracks(_ tracks: [Track]) async {
        guard !tracks.isEmpty else { return }
        for track in tracks {
            guard track.fileURL.isFileURL else {
                MidgarLog.notice("Not deleting a song that lives on a server: \(track.title)", category: .content)
                continue
            }
            do {
                try FileManager.default.removeItem(at: track.fileURL)
                MidgarLog.info("Deleted: \(track.fileURL.lastPathComponent)", category: .content)
            } catch {
                MidgarLog.error("Delete failed for \(track.fileURL.lastPathComponent): \(error.localizedDescription)", category: .content)
            }
        }
        AudioPlayer.shared.handleDeletedTracks(Set(tracks.map(\.fileURL).filter(\.isFileURL)))
        await reload()
    }

    /// Every audio file under the library root by relative path, or nil when
    /// the folder cannot be walked. `found` hears the running count.
    nonisolated private func audioPathsOnDisk(found: (Int) -> Void = { _ in }) -> Set<String>? {
        guard let enumerator = FileManager.default.enumerator(
            at: documentsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        var paths = Set<String>()
        while let fileURL = enumerator.nextObject() as? URL {
            guard Self.audioExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            paths.insert(relativePath(for: fileURL))
            found(paths.count)
        }
        return paths
    }

    @discardableResult
    @concurrent
    nonisolated private func syncFilesWithDatabase() async -> LibrarySyncResult {
        #if os(macOS)
        guard !LibraryRoot.shared.isFallbackActive else {
            MidgarLog.notice(
                "Sync skipped: bookmarked library folder is unavailable; database left untouched",
                category: .content
            )
            return .unchanged
        }
        #endif
        guard let diskPaths = audioPathsOnDisk(found: { count in emitProgress { $0.filesFound = count } }) else {
            return .unchanged
        }
        let filesOnDisk = diskPaths.count
        emitProgress(force: true) { $0.filesFound = filesOnDisk }

        let knownPaths: Set<String>
        do {
            knownPaths = try db.fetchAllTrackRelativePaths()
        } catch {
            MidgarLog.error("DB fetch paths error: \(error.localizedDescription)", category: .database)
            return .unchanged
        }

        let newPaths = diskPaths.subtracting(knownPaths)
        let removedPaths = knownPaths.subtracting(diskPaths)
        let indexedOnDisk = diskPaths.intersection(knownPaths)

        #if os(macOS)
        let rootChanged = recordCurrentRootIdentity()
        #endif

        if newPaths.isEmpty && removedPaths.isEmpty {
            MidgarLog.info("Sync: \(diskPaths.count) files, no changes", category: .content)
            emitProgress(force: true) {
                $0.phase = .readingTags
                $0.completed = knownPaths.count
                $0.total = knownPaths.count
                $0.tracksIndexed = knownPaths.count
            }
            return LibrarySyncResult(changed: false, indexedOnDisk: indexedOnDisk.subtracting(ScanJournal.quarantinedPaths()))
        }

        if !removedPaths.isEmpty {
            #if os(macOS)
            guard !diskPaths.isEmpty || rootChanged else {
                MidgarLog.notice(
                    "Sync: library root scanned empty while database holds \(knownPaths.count) tracks; skipping destructive cleanup",
                    category: .content
                )
                return .unchanged
            }
            if rootChanged {
                MidgarLog.notice(
                    "Sync: library root changed; pruning \(removedPaths.count) rows indexed from the previous root",
                    category: .content
                )
            }
            #endif
            do {
                try db.deleteTracksNotIn(relativePaths: diskPaths)
            } catch {
                MidgarLog.error("DB cleanup error: \(error.localizedDescription)", category: .database)
            }
        }

        let newCount = newPaths.count
        let alreadyIndexed = knownPaths.count - removedPaths.count
        let covers = ScanCoverLedger()
        emitProgress(force: true) {
            $0.phase = .readingTags
            $0.completed = 0
            $0.total = newCount
            $0.tracksIndexed = alreadyIndexed
        }

        let journal = ScanJournal(onDisk: diskPaths)
        let filedByName = newPaths.intersection(journal.quarantined)
        let alone = newPaths.intersection(journal.replay.suspects).subtracting(filedByName)
        let together = newPaths.subtracting(filedByName).subtracting(alone)
        var buffer: [TrackRecord] = []
        var read = 0
        func collect(_ record: TrackRecord) {
            read += 1
            let done = read
            emitProgress {
                $0.completed = done
                $0.tracksIndexed = alreadyIndexed + done
            }
            buffer.append(record)
            guard buffer.count >= Self.insertBatchSize else { return }
            insertBatch(buffer)
            buffer.removeAll(keepingCapacity: true)
        }

        for relPath in filedByName.sorted() {
            let fileURL = documentsDirectory.appendingPathComponent(relPath, isDirectory: false)
            collect(Self.trackRecord(relPath, metadata: MetadataService.metadataFromPath(of: fileURL)))
        }
        for relPath in alone.sorted() {
            journal.note(ScanJournalReplay.aloneMark, relPath)
            let record = await readTrackRecord(relPath, covers: covers)
            journal.note(ScanJournalReplay.doneMark, relPath)
            collect(record)
        }
        await withTaskGroup(of: TrackRecord.self) { group in
            var pending = together.makeIterator()
            func addNext() -> Bool {
                guard let relPath = pending.next() else { return false }
                group.addTask {
                    journal.note(ScanJournalReplay.readingMark, relPath)
                    let record = await self.readTrackRecord(relPath, covers: covers)
                    journal.note(ScanJournalReplay.doneMark, relPath)
                    return record
                }
                return true
            }
            var inflight = 0
            while inflight < Self.readersInFlight && addNext() { inflight += 1 }
            for await record in group {
                collect(record)
                _ = addNext()
            }
        }
        insertBatch(buffer)
        journal.close()

        MidgarLog.info("Sync: \(diskPaths.count) files on disk, \(newPaths.count) new, \(removedPaths.count) removed", category: .content)
        return LibrarySyncResult(changed: true, indexedOnDisk: diskPaths.subtracting(journal.quarantined))
    }

    /// Reads one new file into a row: its tags within `tagReadLimit`, its
    /// cover only while the album still lacks one, and the cheap fingerprint.
    nonisolated private func readTrackRecord(_ relPath: String, covers: ScanCoverLedger) async -> TrackRecord {
        let fileURL = documentsDirectory.appendingPathComponent(relPath, isDirectory: false)
        let metadata = await MetadataService.extractMetadata(
            from: fileURL,
            within: Self.tagReadLimit,
            wantsArtwork: { covers.needsCover(albumTitle: $0, artist: $1) }
        )
        let artworkData = metadata.artwork?.jpegData(compressionQuality: 0.8)
        if artworkData != nil {
            covers.noteCovered(albumTitle: metadata.albumTitle, artist: metadata.artist)
        }
        let fingerprint = AudioFingerprinter.quickFingerprint(of: fileURL)
        let signature = fingerprint == nil ? nil : AudioFingerprinter.signature(of: fileURL)
        return Self.trackRecord(
            relPath, metadata: metadata, artworkData: artworkData, signature: signature, fingerprint: fingerprint
        )
    }

    nonisolated private static func trackRecord(
        _ relPath: String,
        metadata: Track,
        artworkData: Data? = nil,
        signature: FileSignature? = nil,
        fingerprint: String? = nil
    ) -> TrackRecord {
        TrackRecord(
            fileURL: relPath,
            title: metadata.title,
            artist: metadata.artist,
            albumTitle: metadata.albumTitle,
            albumArtist: metadata.albumArtist,
            trackNumber: metadata.trackNumber,
            duration: metadata.duration,
            artworkData: artworkData,
            lastFMArtworkURL: nil,
            musicBrainzID: nil,
            albumMusicBrainzID: nil,
            dateAdded: Date(),
            lastPlayed: nil,
            playCount: 0,
            aiAnalyzed: false,
            analysisAttemptedAt: nil,
            codec: metadata.codec,
            bitDepth: metadata.bitDepth,
            sampleRate: metadata.sampleRate,
            channels: metadata.channels,
            fileSize: signature?.size,
            fileModifiedMs: signature?.modifiedMilliseconds,
            audioFingerprint: fingerprint
        )
    }

    private nonisolated static let insertBatchSize = 50
    private nonisolated static let readersInFlight = 8

    /// How long one file's tags may take before it is filed by its name: far
    /// beyond any healthy read, even of a large file on a slow device.
    private nonisolated static let tagReadLimit: Duration = .seconds(20)

    #if os(macOS)
    private nonisolated static let rootIdentityKey = "flaccy.mac.libraryRootIdentity"

    /// Records which root the database rows were indexed from, returning true
    /// when the current root differs from the recorded one — the only case in
    /// which pruning rows against an empty scan is an intentional fresh start
    /// rather than a transient failure.
    nonisolated private func recordCurrentRootIdentity() -> Bool {
        let identity = documentsDirectory.standardizedFileURL.path
        let recorded = UserDefaults.standard.string(forKey: Self.rootIdentityKey)
        UserDefaults.standard.set(identity, forKey: Self.rootIdentityKey)
        return recorded != nil && recorded != identity
    }
    #endif

    nonisolated private func insertBatch(_ records: [TrackRecord]) {
        guard !records.isEmpty else { return }
        do {
            try db.insertTracks(records)
            announceHoistedCovers(in: records)
        } catch {
            MidgarLog.error("Insert tracks error: \(error.localizedDescription)", category: .database)
        }
        Task { @MainActor [weak self] in await self?.publishListingIfDue() }
    }

    /// Announces the covers this batch just hoisted into `albumInfo`, so the
    /// Debut's mosaic can fill during `readingTags` rather than after it.
    ///
    /// The album model does not exist until the phase that follows the whole
    /// scan, so a reader watching Act I has nothing to look at unless the art is
    /// pushed from the insert that wrote it. Only sent once the write has
    /// committed, so every announced cover is already readable.
    nonisolated private func announceHoistedCovers(in records: [TrackRecord]) {
        var seen = Set<String>()
        var covers: [HoistedAlbumCover] = []
        for record in records where record.artworkData != nil && !record.albumTitle.isEmpty {
            let tileKey = "\(record.albumTitle)|\(LibraryHygiene.primaryArtist(record.credit))"
            guard seen.insert(tileKey).inserted else { continue }
            covers.append(HoistedAlbumCover(
                albumTitle: record.albumTitle, artist: record.artist, tileKey: tileKey
            ))
        }
        guard !covers.isEmpty else { return }
        NotificationCenter.default.post(
            name: Library.albumCoversHoisted, object: nil, userInfo: [CoverKey.covers: covers]
        )
    }

    private func loadFromDatabase(resolvingCredits: Bool = true) async {
        do {
            adopt(try await fetchAlbumsFromDatabase(resolvingCredits: resolvingCredits))
            recordIndexedLibrary()
        } catch {
            MidgarLog.error("Load from DB failed: \(error.localizedDescription)", category: .database)
        }
    }

    private func adopt(_ loadedAlbums: [Album]) {
        albums = loadedAlbums
        allTracks = loadedAlbums.flatMap(\.tracks)
        revisedVersions = Dictionary(
            allTracks.compactMap { track in TrackVersion(track: track).map { (track.fileURL, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// What the library knows of a song's versions right now, or nil for a song
    /// that was never re-exported. Rows and queues hold songs read earlier, so
    /// they ask here rather than trusting the revision they were built with.
    func version(of track: Track) -> TrackVersion? {
        revisedVersions[track.fileURL]
    }

    /// Records that this library has been built at least once, the moment the
    /// first read actually yields albums. The Debut has to decide whether to
    /// take the screen over before any `SELECT` could answer that, so the answer
    /// is written where the next launch can read it without opening anything.
    private func recordIndexedLibrary() {
        guard !albums.isEmpty, !LibraryStartupProbe.hadIndexedLibrary else { return }
        LibraryStartupProbe.markIndexed()
    }

    /// The figures the Debut's summary card reports, read from the database and
    /// the model the person just watched being built rather than from counters
    /// the scan kept — a scan that restarted must not make the card lie.
    func debutSummary() async -> LibraryDebutSummary {
        await Self.buildDebutSummary(albums: albums, tracks: allTracks)
    }

    @concurrent
    nonisolated private static func buildDebutSummary(
        albums: [Album], tracks: [Track]
    ) async -> LibraryDebutSummary {
        let db = DatabaseManager.shared
        var coversResolved = 0
        var albumsDated = 0
        for album in albums {
            guard let status = try? db.fetchAlbumInfoStatus(title: album.title, artist: album.artist) else { continue }
            if status.hasCover { coversResolved += 1 }
            if status.year != nil { albumsDated += 1 }
        }

        let aiCleanedTracks = ((try? db.fetchAllTracks()) ?? []).count { $0.aiAnalyzed }
        let bitrates = tracks.compactMap(bitrate(of:))

        return LibraryDebutSummary(
            trackCount: tracks.count,
            albumCount: albums.count,
            artistCount: Set(albums.map(\.artist)).count,
            coversResolved: coversResolved,
            albumsDated: albumsDated,
            aiCleanedTracks: aiCleanedTracks,
            losslessTrackCount: tracks.count(where: \.isLossless),
            averageBitrate: bitrates.isEmpty ? 0 : bitrates.reduce(0, +) / bitrates.count,
            totalDurationSeconds: tracks.reduce(0) { $0 + $1.duration },
            completedAt: Date()
        )
    }

    /// A track's uncompressed stream rate in kbps, which is what a lossless
    /// library's average is actually made of. Nil when the tags did not carry
    /// enough to say, so an unknown file lowers no average.
    nonisolated private static func bitrate(of track: Track) -> Int? {
        guard let sampleRate = track.sampleRate, let bitDepth = track.bitDepth else { return nil }
        let channels = track.channels ?? 2
        return sampleRate * bitDepth * channels / 1000
    }

    /// Builds the album list without decoded artwork: pinning full-tier
    /// bitmaps inside long-lived model structs would defeat
    /// `AlbumArtworkCache` eviction, and every reader already handles nil.
    @concurrent
    nonisolated private func fetchAlbumsFromDatabase(resolvingCredits: Bool) async throws -> [Album] {
        if resolvingCredits { try db.resolveAlbumCredits() }
        let albumsWithTracks = try db.fetchAlbumsWithTracksLightweight()

        var loadedAlbums: [Album] = []
        loadedAlbums.reserveCapacity(albumsWithTracks.count)
        var leads: [String: String] = [:]
        func lead(_ artist: String) -> String {
            if let known = leads[artist] { return known }
            let primary = LibraryHygiene.primaryArtist(artist)
            leads[artist] = primary
            return primary
        }

        for (albumInfo, trackRecords) in albumsWithTracks {
            let tracks = trackRecords.map { record in
                Track.from(light: record, artwork: nil)
            }
            guard !tracks.isEmpty else { continue }
            let title = Self.majorityValue(tracks.map(\.albumTitle))
            let artist = Self.majorityValue(tracks.map { lead($0.artist) })
            loadedAlbums.append(Album(
                title: title,
                artist: artist,
                artwork: nil,
                tracks: tracks,
                year: albumInfo?.year,
                genre: albumInfo?.genre
            ))
        }

        if GroupAlbumEditionsSetting.isEnabled {
            loadedAlbums = LibraryHygiene.consolidateAlbums(loadedAlbums)
        }
        return loadedAlbums
    }

    private func logLibraryState() {
        MidgarLog.info("Library: \(albums.count) albums, \(allTracks.count) tracks", category: .content)
    }

    nonisolated private static func majorityValue(_ values: [String]) -> String {
        var counts: [String: Int] = [:]
        for value in values {
            counts[value, default: 0] += 1
        }
        return counts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key.count > rhs.key.count
        }?.key ?? values[0]
    }

    nonisolated private func relativePath(for url: URL) -> String {
        LibraryPaths.relativePath(of: url)
    }
}

/// Hands import progress to the main actor at most every 150 ms, plus the
/// moments that must never be dropped, so a folder of small files copied from
/// a fast disk cannot flood the main queue with label updates.
nonisolated final class ImportProgressReporter: @unchecked Sendable {
    private let deliver: @MainActor @Sendable (LibraryImportProgress) -> Void
    private var lastDelivery: ContinuousClock.Instant?

    init(deliver: @escaping @MainActor @Sendable (LibraryImportProgress) -> Void) {
        self.deliver = deliver
    }

    func report(_ progress: LibraryImportProgress, force: Bool) {
        let now = ContinuousClock.now
        if !force, let lastDelivery, now - lastDelivery < .milliseconds(150) { return }
        lastDelivery = now
        let deliver = deliver
        DispatchQueue.main.async {
            MainActor.assumeIsolated { deliver(progress) }
        }
    }
}
