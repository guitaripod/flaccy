import FlaccyCore
import FlaccyEngine
import MidgarCore
import Foundation

/// What a song's file turned out to be on this pass, ready to be written.
nonisolated struct LibraryRevision: Sendable {
    let relativePath: String
    let outcome: TrackRevision.Outcome
    let version: StoredVersion
    let refresh: TrackMetadataRefresh?
}

/// How many files the revision pass looked at and what it decided about them.
nonisolated struct LibraryRevisionTally: Sendable {
    var baselined = 0
    var retagged = 0
    var newVersions: [String] = []

    var changedLibrary: Bool { retagged > 0 || !newVersions.isEmpty }
}

extension Library {

    private nonisolated static let maxInspectionsInFlight = 8
    private nonisolated static let baselineBatchSize = 100

    /// Waits for the revision pass the last reload started, so a caller that
    /// needs the library to have noticed a re-export can wait for it.
    func settleRevisions() async {
        await revisionTask?.value
    }

    /// Checks the indexed files for a newer version of their song after the
    /// reload has already announced itself, so a large library never holds the
    /// screen back; a pass asked for while one runs is run again when it ends.
    func scheduleRevisionPass(for paths: Set<String>) {
        guard !paths.isEmpty else { return }
        guard revisionTask == nil else {
            pendingRevisionPaths = paths
            return
        }
        revisionTask = Task {
            var next: Set<String>? = paths
            while let current = next {
                pendingRevisionPaths = nil
                await reviseKnownFiles(current)
                next = pendingRevisionPaths
            }
            revisionTask = nil
        }
    }

    @concurrent
    nonisolated func reviseKnownFiles(_ paths: Set<String>) async {
        let stored: [String: StoredVersion]
        do {
            stored = try db.fetchStoredVersions()
        } catch {
            MidgarLog.error("Revision pass could not read stored versions: \(error.localizedDescription)", category: .database)
            return
        }
        let root = documentsDirectory
        let tally = await inspect(paths.sorted(), stored: stored, root: root)
        guard tally.baselined > 0 || tally.changedLibrary else { return }
        MidgarLog.info(
            "Revision pass: \(tally.baselined) baselined, \(tally.retagged) retagged, \(tally.newVersions.count) new versions",
            category: .content
        )
        guard tally.changedLibrary else { return }
        await publishRevisions(tally)
    }

    private nonisolated func inspect(
        _ paths: [String], stored: [String: StoredVersion], root: URL
    ) async -> LibraryRevisionTally {
        var tally = LibraryRevisionTally()
        var baselines: [(relativePath: String, version: StoredVersion)] = []
        await withTaskGroup(of: LibraryRevision?.self) { group in
            var pending = paths.makeIterator()
            var inflight = 0
            func addNext(_ group: inout TaskGroup<LibraryRevision?>) -> Bool {
                while let path = pending.next() {
                    guard let known = stored[path] else { continue }
                    group.addTask { await Self.revision(of: path, stored: known, root: root) }
                    return true
                }
                return false
            }
            while inflight < Self.maxInspectionsInFlight && addNext(&group) { inflight += 1 }
            for await revision in group {
                inflight -= 1
                if addNext(&group) { inflight += 1 }
                guard let revision else { continue }
                switch revision.outcome {
                case .baseline:
                    baselines.append((revision.relativePath, revision.version))
                    if baselines.count >= Self.baselineBatchSize {
                        tally.baselined += persistBaselines(baselines)
                        baselines.removeAll(keepingCapacity: true)
                    }
                case .retagged, .newVersion:
                    guard persist(revision) else { continue }
                    if revision.outcome == .newVersion {
                        tally.newVersions.append(revision.relativePath)
                    } else {
                        tally.retagged += 1
                    }
                case .unchanged:
                    break
                }
            }
        }
        tally.baselined += persistBaselines(baselines)
        return tally
    }

    /// The decision for one indexed file: the signature first, the fingerprint
    /// only when the signature moved, and nothing when the file changed again
    /// while it was being read, since a copy still being written is not yet a version.
    private nonisolated static func revision(of relativePath: String, stored: StoredVersion, root: URL) async -> LibraryRevision? {
        let url = root.appendingPathComponent(relativePath)
        guard let signature = AudioFingerprinter.signature(of: url), signature.size > 0,
              TrackRevision.needsInspection(stored: stored, current: signature)
        else { return nil }
        let fingerprint = AudioFingerprinter.fingerprint(of: url)
        guard AudioFingerprinter.signature(of: url) == signature else { return nil }
        let outcome = TrackRevision.classify(stored: stored, currentFingerprint: fingerprint)
        let version = TrackRevision.applying(
            outcome, to: stored, signature: signature, fingerprint: fingerprint, now: Date()
        )
        let refresh = outcome == .baseline ? nil : await MetadataService.refresh(from: url)
        return LibraryRevision(relativePath: relativePath, outcome: outcome, version: version, refresh: refresh)
    }

    private nonisolated func persistBaselines(_ baselines: [(relativePath: String, version: StoredVersion)]) -> Int {
        guard !baselines.isEmpty else { return 0 }
        do {
            try db.updateVersions(baselines)
            return baselines.count
        } catch {
            MidgarLog.error("Baselining versions failed: \(error.localizedDescription)", category: .database)
            return 0
        }
    }

    private nonisolated func persist(_ revision: LibraryRevision) -> Bool {
        do {
            guard let refresh = revision.refresh else {
                try db.updateVersion(relativePath: revision.relativePath, revision.version)
                return true
            }
            return try db.refreshMetadata(
                relativePath: revision.relativePath, with: refresh, storing: revision.version
            )
        } catch {
            MidgarLog.error(
                "Storing the \(revision.outcome) of \(revision.relativePath) failed: \(error.localizedDescription)",
                category: .database
            )
            return false
        }
    }

    /// Reads the revised rows back into the model first, so everything that
    /// hears `tracksRevised` finds `Track.revisedAt` already current.
    private func publishRevisions(_ tally: LibraryRevisionTally) async {
        await reloadFromDatabase()
        if !tally.newVersions.isEmpty {
            NotificationCenter.default.post(
                name: Library.tracksRevised,
                object: nil,
                userInfo: [Library.RevisionKey.paths: tally.newVersions]
            )
        }
        Task { await EnrichmentCoordinator.shared.resume() }
    }
}
