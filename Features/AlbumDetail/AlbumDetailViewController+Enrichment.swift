import FlaccyCore
import UIKit

extension AlbumDetailViewController {

    /// Repairs the album the reader is actually looking at, the way the Mac's
    /// detail page does. The request is not forced: an album the ladder has
    /// already settled — or given up on — costs zero network calls to open, so
    /// browsing can never burn the four-attempt ladder.
    func repairMetadataIfNeeded() {
        guard album.year == nil || album.genre == nil else { return }
        let title = album.title
        let artist = album.artist
        guard isEnrichmentDue(title: title, artist: artist) else { return }
        metadataTask = Task { [weak self] in
            let changed = await EnrichmentCoordinator.shared.requestNow(title: title, artist: artist)
            guard changed, !Task.isCancelled else { return }
            self?.applyStoredMetadata(title: title, artist: artist)
        }
    }

    /// The presentation half of the ladder. The authoritative gate is the one
    /// inside the task itself; this only keeps the page from asking for work
    /// the durable queue has already answered.
    func isEnrichmentDue(title: String, artist: String) -> Bool {
        let record = (try? DatabaseManager.shared.fetchEnrichmentRecord(
            scope: .album, key: EnrichmentKey.album(title: title, artist: artist)
        )) ?? nil
        return EnrichmentPolicy.isDue(record, scope: .album, now: Date())
    }

    func applyStoredMetadata(title: String, artist: String) {
        let status = try? DatabaseManager.shared.fetchAlbumInfoStatus(title: title, artist: artist)
        renderMetaLine(year: status?.year, genre: status?.genre)
    }

    /// The year and genre under the artist name, hidden entirely when neither
    /// is known rather than left as an empty line.
    func renderMetaLine(year: String?, genre: String?) {
        var parts: [String] = []
        if let year, !year.isEmpty { parts.append(year) }
        if let genre, !genre.isEmpty { parts.append(genre) }
        metaLabel.text = parts.joined(separator: " \u{00B7} ")
        metaLabel.isHidden = parts.isEmpty
    }

    /// Fetches Last.fm genre tags off-main, caching them, then folds them into
    /// the header without blocking UI, and counts the album's plays locally.
    func loadEnrichment() {
        let artist = album.artist
        refreshPlayCount()

        let cachedTags = DetailEnrichmentCache.shared.cachedTopTags(artist: artist)
        if let cachedTags {
            applyGenreChips(cachedTags, animated: false)
            return
        }

        enrichmentTask = Task { [weak self] in
            let tags = await DetailEnrichmentCache.shared.topTags(artist: artist)
            if !Task.isCancelled { self?.applyGenreChips(tags, animated: true) }
        }
    }

    /// Counts the album's plays in the local listening history and shows the
    /// line when there are any.
    func refreshPlayCount() {
        playCountTask?.cancel()
        let album = self.album
        playCountTask = Task { [weak self] in
            let plays = await AlbumListenCount.count(for: album)
            if !Task.isCancelled, plays > 0 { self?.applyPlayCount(plays, animated: self?.playCountLabel.isHidden ?? true) }
        }
    }

    @objc func historyDidChange() {
        refreshPlayCount()
    }

    func applyGenreChips(_ tags: [String], animated: Bool) {
        genreChipsHolder.subviews.forEach { $0.removeFromSuperview() }
        guard !tags.isEmpty else {
            genreChipsHolder.isHidden = true
            sizeHeaderToFit()
            return
        }
        let row = DetailChip.chipsRow(tags)
        row.translatesAutoresizingMaskIntoConstraints = false
        genreChipsHolder.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: genreChipsHolder.topAnchor),
            row.bottomAnchor.constraint(equalTo: genreChipsHolder.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: genreChipsHolder.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: genreChipsHolder.trailingAnchor),
        ])
        genreChipsHolder.isHidden = false
        reveal(row, animated: animated)
    }

    func applyPlayCount(_ count: Int, animated: Bool) {
        playCountLabel.text = String(localized: "You've played this album \(count) times")
        playCountLabel.textColor = accentColor
        playCountLabel.isHidden = false
        reveal(playCountLabel, animated: animated)
    }

    func reveal(_ view: UIView, animated: Bool) {
        if animated {
            animateHeaderReveal(fading: view)
        } else {
            view.alpha = 1
            sizeHeaderToFit()
        }
    }

    /// Fades a newly-revealed header element in while smoothly resizing the
    /// table header so the track rows slide down instead of jumping; applies
    /// instantly under Reduce Motion.
    func animateHeaderReveal(fading view: UIView) {
        sizeHeaderToFit()
        guard !UIAccessibility.isReduceMotionEnabled else {
            view.alpha = 1
            return
        }
        view.alpha = 0
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut]) {
            view.alpha = 1
        }
    }
}
