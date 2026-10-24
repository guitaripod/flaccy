import Combine
import MidgarCore
import FlaccyCore

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

extension LibraryViewModel {

    /// Merges the two things that decide launch chrome — the bounded load bar
    /// and the unbounded enrichment job — onto **one** pipeline.
    ///
    /// Two subscriptions would let a job snapshot and the load fraction it
    /// belongs to be applied in either order, and the surface would flicker
    /// between them. Merged, every routing decision sees one consistent pair.
    /// The third source is a tick the Debut needs while it is on screen: the
    /// director's curtain budget and its "the queue drained" test are questions
    /// about elapsed time that no notification will ever ask on its own.
    func bindLibrarySurface() {
        let load = NotificationCenter.default.publisher(for: Library.progressDidChange)
            .compactMap(Self.loadSignal(from:))
            .eraseToAnyPublisher()

        let job = NotificationCenter.default.publisher(for: EnrichmentCoordinator.progressDidChange)
            .compactMap(Self.jobSignal(from:))
            .eraseToAnyPublisher()

        let tick = debutTick.map { LibrarySignal.tick }.eraseToAnyPublisher()

        surfaceCancellable = Publishers.MergeMany(load, job, tick)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] signal in
                guard let self else { return }
                switch signal {
                case .load(let progress, let fraction):
                    self.latestLoad = progress
                    self.latestFraction = fraction
                case .job(let progress):
                    self.latestJob = progress
                    self.heardFromJob = true
                case .tick:
                    break
                }
                self.loadStatePublisher.send(self.routedState())
            }
    }

    /// Reads a load-progress notification on the thread that posted it, which is why this is not isolated.
    nonisolated static func loadSignal(from notification: Notification) -> LibrarySignal? {
        guard let progress = notification.userInfo?[Library.ProgressKey.progress] as? LibraryLoadProgress,
              let fraction = notification.userInfo?[Library.ProgressKey.fraction] as? Double
        else { return nil }
        return .load(progress, fraction)
    }

    /// Reads an enrichment-progress notification on the thread that posted it, which is why this is not isolated.
    nonisolated static func jobSignal(from notification: Notification) -> LibrarySignal? {
        guard let progress = notification.userInfo?[EnrichmentCoordinator.ProgressKey.progress]
            as? EnrichmentJobProgress else { return nil }
        return .job(progress)
    }

    func routedState() -> LibraryLoadState {
        let surface = surfaceRouter.route(
            load: latestLoad,
            job: latestJob,
            debutCompleted: debutCompleted,
            hasLibrary: !library.albums.isEmpty,
            elapsed: latestJob.startedAt.map { Date().timeIntervalSince($0) } ?? 0
        )
        advanceDebut(on: surface)
        return LibraryLoadState(
            surface: surface, progress: latestLoad, fraction: latestFraction, job: latestJob
        )
    }

    /// Moves the Debut's director forward, and keeps the tick alive only while
    /// there is an act left to reach. Act III is terminal until the card is
    /// dismissed, so the timer stops there rather than polling behind a card.
    func advanceDebut(on surface: LibrarySurface) {
        guard surface == .debut else {
            stopDebutTicking()
            return
        }
        let elapsedInFinishing = finishingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        debutDirector.advance(
            load: latestLoad,
            job: latestJob,
            albumCount: library.albums.count,
            elapsedInFinishing: elapsedInFinishing,
            jobHeardFrom: jobHasSpoken(elapsedInFinishing: elapsedInFinishing)
        )
        debutAct = debutDirector.act
        if debutAct == .finishing, finishingStartedAt == nil { finishingStartedAt = Date() }
        if debutAct < .summary { startDebutTicking() } else { stopDebutTicking() }
    }

    /// Whether the director may believe a drained queue means the enrichment
    /// job is over.
    ///
    /// The job's snapshot starts life `.idle` with nothing remaining, so the
    /// first evaluation after Act I would otherwise skip the whole AI act
    /// before the coordinator has even counted what is due. The floor keeps a
    /// pass that never reports from stranding the act; the 90 s curtain
    /// remains the ceiling either way.
    func jobHasSpoken(elapsedInFinishing: TimeInterval) -> Bool {
        heardFromJob || elapsedInFinishing >= Self.jobReportFloor
    }

    static let jobReportFloor: TimeInterval = 2

    func startDebutTicking() {
        guard debutTicker == nil else { return }
        debutTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.debutTick.send()
            }
        }
    }

    func stopDebutTicking() {
        debutTicker?.cancel()
        debutTicker = nil
    }

    /// The figures the summary card reports.
    func debutSummary() async -> LibraryDebutSummary {
        await library.debutSummary()
    }

    /// Whether the AI pass was skipped because there was nothing entitling it.
    ///
    /// Read from the same predicate `AIIdentificationTask` gates itself on, not
    /// from the job's activity: a `needsEntitlement` snapshot is throttled like
    /// any other and can be superseded by the `.idle` that ends the pass, so a
    /// card built from the stream would miss the one moment worth converting on.
    var aiSkippedForEntitlement: Bool {
        PurchaseManager.shared.state == .expired
    }

    /// Writes the once-per-library record and leaves the Debut for good. The
    /// summary is what makes the launch a debut rather than a scan, so it is
    /// persisted before the surface is released, not after.
    func completeDebut(with summary: LibraryDebutSummary) {
        do {
            try DatabaseManager.shared.saveLibraryDebut(summary)
        } catch {
            MidgarLog.error("Failed to record library debut: \(error.localizedDescription)", category: .database)
        }
        dismissDebut()
    }

    /// Whether this library has already had its Debut. The startup probe
    /// answers first: a launch that indexed a library but died before the
    /// summary card was dismissed leaves no `libraryDebut` row, and the
    /// controller will not install the debut view for it — so deriving this from
    /// the row alone would latch the router on a surface with nothing to draw
    /// and nothing left to release it. Read once, at bind time, before
    /// `Library.recordIndexedLibrary()` can fire in this same launch.
    static func readDebutCompleted() -> Bool {
        if LibraryStartupProbe.hadIndexedLibrary { return true }
        return ((try? DatabaseManager.shared.libraryDebut()) ?? nil) != nil
    }

    /// Leaves the Debut without writing one — an empty first build has no
    /// library to be the debut of, and must earn the showpiece next time.
    func dismissDebut() {
        surfaceRouter.releaseDebut()
        debutCompleted = true
        debutAct = .done
        stopDebutTicking()
        loadStatePublisher.send(routedState())
    }
}
