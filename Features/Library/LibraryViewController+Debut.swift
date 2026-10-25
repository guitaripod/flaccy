import Combine
import MidgarCore
import FlaccyCore
import UIKit
import UniformTypeIdentifiers

extension LibraryViewController {

    /// Adds the Debut only when no earlier launch ever indexed a library.
    ///
    /// The question is answered from `UserDefaults` rather than the database,
    /// because by the time a `SELECT` could answer it the first frame is already
    /// on screen — which is how a relaunch used to get a 1% ring it then had to
    /// crossfade away. A returning library never puts the view in the hierarchy
    /// at all, so there is nothing to flash.
    func installDebutViewIfNeeded() {
        guard !LibraryStartupProbe.hadIndexedLibrary else { return }
        let debut = LibraryDebutView()
        debut.translatesAutoresizingMaskIntoConstraints = false
        debut.accessibilityIdentifier = "library.debut"
        debut.alpha = 1
        debut.onDismiss = { [weak self] in self?.finishDebut() }
        debut.onShowPaywall = { [weak self] in
            guard let self else { return }
            PaywallViewController.presentSheet(from: self)
        }
        let host = debutHost
        host.addSubview(debut)
        debutView = debut
        navigationController?.setNavigationBarHidden(true, animated: false)

        NSLayoutConstraint.activate([
            debut.topAnchor.constraint(equalTo: host.topAnchor),
            debut.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            debut.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            debut.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    /// The Debut has left the screen for now — demoted, or its sheet swiped
    /// away — which frees the runway banner but ends nothing.
    func noteDebutLeftScreen() {
        applyRunwayBannerVisibility(animated: true)
    }

    /// Everything that waited for the Debut to be over runs from here.
    func noteDebutFinished() {
        NotificationCenter.default.post(name: Self.debutDidDismiss, object: self)
    }

    /// Takes the Debut off the screen the moment the library behind it is worth
    /// looking at, without throwing away what it still has to show. The view
    /// keeps living — the mosaic keeps filling, the countdown keeps counting —
    /// but from here it is reached through the banner or raised once for the
    /// summary, never left standing in the reader's way.
    func demoteDebutToSheet() {
        guard let debut = debutView, debut.superview === debutHost else { return }
        debut.removeFromSuperview()
        navigationController?.setNavigationBarHidden(false, animated: true)
        noteDebutLeftScreen()
    }

    /// Opens the Debut over whatever the reader is doing, on their say-so.
    func presentDebutSheet() {
        guard let debut = debutView, presentedViewController == nil else { return }
        let sheet = LibraryDebutSheetController(debutView: debut)
        sheet.presentationController?.delegate = self
        debutSheet = sheet
        present(sheet, animated: true)
    }

    func dismissDebutSheet(completion: (() -> Void)? = nil) {
        guard let sheet = debutSheet, presentedViewController === sheet else {
            completion?()
            return
        }
        debutSheet = nil
        sheet.dismiss(animated: true, completion: completion)
    }

    func updateDebut(with state: LibraryViewModel.LibraryLoadState) {
        guard let debutView else { return }
        let act = viewModel.debutAct
        debutView.update(progress: state.progress, fraction: state.fraction, job: state.job, act: act)
        feedDebutMosaic()
        guard renderedDebutAct != act else { return }
        renderedDebutAct = act
        enter(act)
    }

    /// Pours the artwork the built library holds into the mosaic — the backstop
    /// for anything Act I's live feed missed, and the only source once the scan
    /// found no new files to read.
    func feedDebutMosaic() {
        for album in viewModel.mosaicAlbums() where fedMosaicKeys.count < LibraryViewModel.mosaicCoverBudget {
            guard fedMosaicKeys.insert(album.id).inserted else { continue }
            loadMosaicCover(albumTitle: album.title, artist: album.artist, tileKey: album.id)
        }
    }

    /// Fills the mosaic *during* Act I, from the covers the scan is hoisting out
    /// of the tags as it reads them. This is the act's whole show: the album
    /// model does not exist until the phase after it, so without this the grid
    /// stays a wall of gradients for the entire scan and then fills all at once.
    func absorbHoistedCovers(_ notification: Notification) {
        guard debutView != nil,
              let covers = notification.userInfo?[Library.CoverKey.covers] as? [HoistedAlbumCover]
        else { return }
        for cover in covers where fedMosaicKeys.count < LibraryViewModel.mosaicCoverBudget {
            guard fedMosaicKeys.insert(cover.tileKey).inserted else { continue }
            loadMosaicCover(albumTitle: cover.albumTitle, artist: cover.artist, tileKey: cover.tileKey)
        }
    }

    /// Decodes one cover off the main thread and places it under the identity the
    /// album model will carry, so the live feed and the post-build pass cannot
    /// tile the same album twice.
    func loadMosaicCover(albumTitle: String, artist: String, tileKey: String) {
        AlbumArtworkCache.shared.loadThumbnail(forAlbum: albumTitle, artist: artist) { [weak self] image in
            guard let image, let debutView = self?.debutView else { return }
            debutView.insert(cover: image, forKey: tileKey)
        }
    }

    /// Moves the Debut into an act. No haptic fires here: the Debut's single
    /// haptic belongs to `LibraryDebutView.presentSummary(_:aiSkippedForEntitlement:)`, which plays it
    /// at the moment the card actually rises rather than one database pass
    /// earlier. Acts I and II are background work, and the HIG is explicit that
    /// background work does not get repeated feedback.
    func enter(_ act: LibraryDebutAct) {
        switch act {
        case .indexing, .finishing:
            break
        case .summary:
            if debutView?.superview !== debutHost { presentDebutSheet() }
            presentDebutSummary()
        case .done:
            viewModel.dismissDebut()
        }
    }

    func presentDebutSummary() {
        Task { [weak self] in
            guard let self else { return }
            let summary = await self.viewModel.debutSummary()
            self.debutSummary = summary
            self.debutView?.presentSummary(
                summary, aiSkippedForEntitlement: self.viewModel.aiSkippedForEntitlement
            )
        }
    }

    /// Leaves the Debut for good, recording the summary the person just read so
    /// no later launch can offer them the showpiece again, and flying the mosaic
    /// onto the album grid it was a picture of all along.
    ///
    /// The grid's frames are measured and the view is released *before* the
    /// latch is dropped: releasing it raises the status banner, which would
    /// otherwise shift the grid under tiles already in flight. Nilling the
    /// property up front also makes `updateDebut` a no-op for the
    /// duration, so no second crossfade competes with the morph — which leaves
    /// the nav bar to be restored by hand.
    func finishDebut() {
        guard let debut = debutView else { return }
        guard debut.superview === debutHost else {
            debutView = nil
            if let debutSummary {
                viewModel.completeDebut(with: debutSummary)
            } else {
                viewModel.dismissDebut()
            }
            dismissDebutSheet { [weak self] in
                debut.removeFromSuperview()
                self?.retireDebutState()
            }
            return
        }
        debutHost.layoutIfNeeded()
        let targets = UIAccessibility.isReduceMotionEnabled ? [] : albumGridTargetFrames(in: debut)
        debutView = nil
        debutHost.bringSubviewToFront(debut)
        navigationController?.setNavigationBarHidden(false, animated: false)
        if let debutSummary {
            viewModel.completeDebut(with: debutSummary)
        } else {
            viewModel.dismissDebut()
        }
        debut.morph(to: targets) { [weak self] in
            debut.removeFromSuperview()
            self?.retireDebutState()
        }
    }

    /// The frames the album grid's first screen is about to occupy, in the debut
    /// view's own space, so the tiles land on their own counterparts.
    func albumGridTargetFrames(in space: UIView) -> [CGRect] {
        collectionView.indexPathsForVisibleItems
            .sorted()
            .compactMap { collectionView.layoutAttributesForItem(at: $0)?.frame }
            .map { collectionView.convert($0, to: space) }
    }

    /// Drops everything the Debut was holding — thirty-six decoded covers, the
    /// summary it read from, and the keys that stopped it tiling an album twice.
    func retireDebutState() {
        renderedDebutAct = nil
        debutSummary = nil
        fedMosaicKeys.removeAll()
        noteDebutLeftScreen()
        noteDebutFinished()
    }

    func showDebut() {
        guard let debutView, debutView.isHidden || debutView.alpha < 1 else { return }
        debutView.isHidden = false
        debutView.alpha = 1
        debutHost.bringSubviewToFront(debutView)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    /// The quiet surface: one line under the segments reporting work going on
    /// behind a library the person can already use. A live disk scan wins the
    /// line, because it is the thing that changes what is on screen; the job
    /// gets it the rest of the time.
    func showAmbient(_ state: LibraryViewModel.LibraryLoadState, animated: Bool) {
        if statusBannerHeight.constant == 0 { statusBanner.prepareForShow() }
        statusBanner.update(
            state.progress.isActive ? .load(state.progress, state.fraction) : .job(state.job)
        )
        setStatusBanner(visible: true, animated: animated)
    }
}
