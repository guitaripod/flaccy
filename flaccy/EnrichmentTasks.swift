import Foundation

/// One unit of enrichment work, named the way `enrichmentState` keys it.
///
/// An AI batch carries its tracks because the batch *is* the tracks: re-reading
/// the whole table once per folder would make a first launch quadratic in the
/// size of the library.
nonisolated enum EnrichmentEntity: Sendable {
    case album(title: String, artist: String)
    case artist(name: String)
    case aiBatch(directory: String, tracks: [TrackRecord])

    var scope: EnrichmentScope {
        switch self {
        case .album: .album
        case .artist: .artist
        case .aiBatch: .aiBatch
        }
    }

    var key: String {
        switch self {
        case .album(let title, let artist): EnrichmentKey.album(title: title, artist: artist)
        case .artist(let name): EnrichmentKey.artist(name)
        case .aiBatch(let directory, _): EnrichmentKey.aiBatch(directory: directory)
        }
    }

    /// What the job reports as `currentTitle` while this entity is in flight.
    var displayTitle: String? {
        switch self {
        case .album(let title, _): title.isEmpty ? nil : title
        case .artist(let name): name.isEmpty ? nil : name
        case .aiBatch(let directory, _): directory.split(separator: "/").last.map(String.init)
        }
    }
}

nonisolated struct EnrichmentTaskOutcome: Sendable {
    let scope: EnrichmentScope
    let key: String
    let title: String?

    /// What this attempt resolved, as handed to `EnrichmentPolicy.apply`.
    let resolved: EnrichmentFields

    /// The part of `resolved` the entity did not already have — the only thing
    /// that means the library on screen is now out of date.
    let gained: EnrichmentFields

    let failure: EnrichmentFailure?
    let status: EnrichmentStatus

    /// False when the entity was already settled and no source was consulted,
    /// so a run that touches nothing cannot inflate the completion count.
    let attempted: Bool

    var changedLibrary: Bool { !gained.isEmpty }

    /// Whether the entity is done with this run: either the sources answered,
    /// or they answered that they have nothing. A transport or rate-limit
    /// outcome is the job getting nowhere and must not read as progress.
    var settled: Bool { failure == nil || failure == .notFound }
}

/// Runs one entity end to end and routes it to the right task.
nonisolated enum EnrichmentTasks {

    static func run(_ entity: EnrichmentEntity, force: Bool = false) async -> EnrichmentTaskOutcome {
        switch entity {
        case .album: await AlbumEnrichmentTask.run(entity, force: force)
        case .artist: await ArtistEnrichmentTask.run(entity, force: force)
        case .aiBatch: await AIIdentificationTask.run(entity, force: force)
        }
    }

    /// Loads the entity's durable state and folds in what the library already
    /// holds, because an `albumInfo` row written by an import can be ahead of
    /// the record. Satisfaction is always re-derived from fields.
    static func loadRecord(scope: EnrichmentScope, key: String, present: EnrichmentFields) -> EnrichmentRecord {
        var record = (try? DatabaseManager.shared.fetchEnrichmentRecord(scope: scope, key: key))
            ?? EnrichmentRecord(scope: scope, key: key)
        record.fields.formUnion(present)
        return record
    }

    /// Marks an entity that needed no work as settled at the current producer
    /// version. Without this an album whose cover arrived by some other route
    /// would have no row at all, and `dueAlbumKeys` reports a missing row as due
    /// forever.
    static func settle(_ record: inout EnrichmentRecord, scope: EnrichmentScope) {
        record.version = scope.currentVersion
        if record.fields.isSuperset(of: EnrichmentFields.required(for: scope)) {
            record.status = .satisfied
        }
        record.nextEligibleAt = nil
        record.lastFailure = nil
        try? DatabaseManager.shared.upsertEnrichmentRecord(record)
    }

    static func outcome(
        _ entity: EnrichmentEntity,
        record: EnrichmentRecord,
        resolved: EnrichmentFields = [],
        gained: EnrichmentFields = [],
        failure: EnrichmentFailure? = nil,
        attempted: Bool
    ) -> EnrichmentTaskOutcome {
        EnrichmentTaskOutcome(
            scope: entity.scope,
            key: entity.key,
            title: entity.displayTitle,
            resolved: resolved,
            gained: gained,
            failure: failure,
            status: record.status,
            attempted: attempted
        )
    }
}

nonisolated enum AlbumEnrichmentTask {

    static func run(_ entity: EnrichmentEntity, force: Bool) async -> EnrichmentTaskOutcome {
        guard case .album(let title, let artist) = entity else {
            return EnrichmentTasks.outcome(entity, record: EnrichmentRecord(scope: .album, key: entity.key), attempted: false)
        }

        let db = DatabaseManager.shared
        let now = Date()
        var record = EnrichmentTasks.loadRecord(
            scope: .album, key: entity.key, present: present(title: title, artist: artist)
        )
        let previous = record.fields

        if previous.isSuperset(of: EnrichmentFields.required(for: .album)) {
            EnrichmentTasks.settle(&record, scope: .album)
            return EnrichmentTasks.outcome(entity, record: record, attempted: false)
        }
        guard force || EnrichmentPolicy.isDue(record, scope: .album, now: now) else {
            return EnrichmentTasks.outcome(entity, record: record, attempted: false)
        }

        let (fields, failure, values) = await MetadataEnrichmentService.shared.enrichAlbum(
            title: title, artist: artist, resolved: previous
        )
        EnrichmentPolicy.apply(to: &record, scope: .album, resolved: fields, failure: failure, now: now)

        do {
            try db.applyAlbumEnrichment(
                title: title,
                artist: artist,
                coverArtURL: values.coverArtURL,
                coverArtData: values.coverArtData,
                musicBrainzID: values.musicBrainzID,
                year: values.year,
                genre: values.genre,
                record: record
            )
        } catch {
            await AppLogger.error(
                "Album enrichment write failed for \(title): \(error.localizedDescription)", category: .database
            )
        }

        return EnrichmentTasks.outcome(
            entity, record: record,
            resolved: fields, gained: fields.subtracting(previous),
            failure: failure, attempted: true
        )
    }

    private static func present(title: String, artist: String) -> EnrichmentFields {
        guard let status = try? DatabaseManager.shared.fetchAlbumInfoStatus(title: title, artist: artist) else {
            return []
        }
        var fields: EnrichmentFields = []
        if status.hasCover { fields.insert(.cover) }
        if status.year != nil { fields.insert(.year) }
        if status.genre != nil { fields.insert(.genre) }
        if status.mbid != nil { fields.insert(.mbid) }
        return fields
    }
}

nonisolated enum ArtistEnrichmentTask {

    static func run(_ entity: EnrichmentEntity, force: Bool) async -> EnrichmentTaskOutcome {
        guard case .artist(let name) = entity else {
            return EnrichmentTasks.outcome(entity, record: EnrichmentRecord(scope: .artist, key: entity.key), attempted: false)
        }

        let db = DatabaseManager.shared
        let now = Date()
        var record = EnrichmentTasks.loadRecord(scope: .artist, key: entity.key, present: present(name: name))
        let previous = record.fields

        if previous.isSuperset(of: EnrichmentFields.required(for: .artist)) {
            EnrichmentTasks.settle(&record, scope: .artist)
            return EnrichmentTasks.outcome(entity, record: record, attempted: false)
        }
        guard force || EnrichmentPolicy.isDue(record, scope: .artist, now: now) else {
            return EnrichmentTasks.outcome(entity, record: record, attempted: false)
        }

        let (fields, failure, values) = await MetadataEnrichmentService.shared.enrichArtist(
            name: name, resolved: previous
        )
        EnrichmentPolicy.apply(to: &record, scope: .artist, resolved: fields, failure: failure, now: now)

        do {
            try db.applyArtistEnrichment(
                name: name,
                bio: values.bio,
                imageURL: values.imageURL,
                musicBrainzID: values.musicBrainzID,
                record: record
            )
        } catch {
            await AppLogger.error(
                "Artist enrichment write failed for \(name): \(error.localizedDescription)", category: .database
            )
        }

        return EnrichmentTasks.outcome(
            entity, record: record,
            resolved: fields, gained: fields.subtracting(previous),
            failure: failure, attempted: true
        )
    }

    private static func present(name: String) -> EnrichmentFields {
        guard let artist = try? DatabaseManager.shared.fetchArtist(name: name) else { return [] }
        var fields: EnrichmentFields = []
        if artist.bio != nil { fields.insert(.artistBio) }
        if artist.imageURL != nil { fields.insert(.artistImage) }
        return fields
    }
}

/// The AI identification pass, one directory batch per entity.
///
/// Lifted from `Library.analyzeLibrary`, which walked the whole library on every
/// launch with only an in-memory retry interval to stop it. The batch is now a
/// durable entity: a folder Groq has been through is never sent again, and a
/// folder it could not read backs off on the shared ladder.
nonisolated enum AIIdentificationTask {

    /// A batch that matched anything has retitled albums, and a retitle is a new
    /// album key — so the orphan sweep runs once here, before the record is
    /// settled, or the pre-retitle key keeps its verdict and keeps inflating
    /// what the report says the job gave up on.
    static func run(_ entity: EnrichmentEntity, force: Bool) async -> EnrichmentTaskOutcome {
        guard case .aiBatch(let directory, let tracks) = entity else {
            return EnrichmentTasks.outcome(entity, record: EnrichmentRecord(scope: .aiBatch, key: entity.key), attempted: false)
        }

        let db = DatabaseManager.shared
        let now = Date()
        var record = EnrichmentTasks.loadRecord(scope: .aiBatch, key: entity.key, present: [])

        guard !tracks.isEmpty else {
            record.fields.insert(.identified)
            EnrichmentTasks.settle(&record, scope: .aiBatch)
            return EnrichmentTasks.outcome(entity, record: record, attempted: false)
        }
        guard force || EnrichmentPolicy.isDue(record, scope: .aiBatch, now: now) else {
            return EnrichmentTasks.outcome(entity, record: record, attempted: false)
        }

        guard await hasActiveEntitlement() else {
            EnrichmentPolicy.apply(to: &record, scope: .aiBatch, resolved: [], failure: .unauthorized, now: now)
            try? db.upsertEnrichmentRecord(record)
            return EnrichmentTasks.outcome(entity, record: record, failure: .unauthorized, attempted: true)
        }

        let contexts = tracks.map { track in
            TrackContext(
                relativePath: track.fileURL,
                currentTitle: track.title,
                currentArtist: track.artist,
                currentAlbum: track.albumTitle,
                trackNumber: track.trackNumber
            )
        }

        await AppLogger.info("AI batch: \(directory) (\(tracks.count) tracks)", category: .content)

        guard let identified = await GroqService.shared.analyzeLibrary(tracks: contexts) else {
            EnrichmentPolicy.apply(to: &record, scope: .aiBatch, resolved: [], failure: .transport, now: now)
            try? db.upsertEnrichmentRecord(record)
            return EnrichmentTasks.outcome(entity, record: record, failure: .transport, attempted: true)
        }

        let matched = await apply(identified, to: tracks, in: db)
        if matched > 0 { try? db.sweepOrphanedAlbumEnrichment() }
        let resolved: EnrichmentFields = matched > 0 ? [.identified] : []
        let failure: EnrichmentFailure? = matched > 0 ? nil : .notFound

        EnrichmentPolicy.apply(to: &record, scope: .aiBatch, resolved: resolved, failure: failure, now: now)
        try? db.upsertEnrichmentRecord(record)

        await AppLogger.info(
            "AI batch \(directory): \(matched)/\(tracks.count) tracks identified", category: .content
        )
        return EnrichmentTasks.outcome(
            entity, record: record, resolved: resolved, gained: resolved, failure: failure, attempted: true
        )
    }

    /// Writes what Groq recognised and returns how many track rows it matched.
    /// A batch that matches nothing is the model answering that it cannot read
    /// these filenames, which is a `.notFound` and costs the folder an attempt.
    private static func apply(
        _ identified: IdentifiedMusic, to tracks: [TrackRecord], in db: DatabaseManager
    ) async -> Int {
        var matched = 0

        for album in identified.albums {
            for identifiedTrack in album.tracks {
                guard var dbTrack = tracks.first(where: { track in
                    let filename = URL(fileURLWithPath: track.fileURL).lastPathComponent
                    return filename.lowercased() == identifiedTrack.filename.lowercased()
                        || track.fileURL.lowercased().hasSuffix(identifiedTrack.filename.lowercased())
                }) else { continue }

                dbTrack.artist = album.artist
                dbTrack.albumTitle = album.album
                dbTrack.title = identifiedTrack.title
                dbTrack.trackNumber = identifiedTrack.trackNumber
                dbTrack.aiAnalyzed = true

                do {
                    try db.updateTrackPreservingArtwork(dbTrack)
                    matched += 1
                } catch {
                    await AppLogger.error("Track update failed: \(error.localizedDescription)", category: .database)
                }
            }

            do {
                var info = try db.fetchOrCreateAlbumInfo(title: album.album, artist: album.artist)
                if let year = album.year { info.year = year }
                if let genre = album.genre { info.genre = genre }
                try db.updateAlbumInfo(info)
            } catch {
                await AppLogger.error("Album info save failed: \(error.localizedDescription)", category: .database)
            }
        }

        return matched
    }

    private static func hasActiveEntitlement() async -> Bool {
        await MainActor.run { PurchaseManager.shared.allowsPlayback }
    }
}
