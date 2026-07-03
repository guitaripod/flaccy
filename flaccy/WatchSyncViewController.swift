import FlaccyCore
import UIKit

enum SyncFormat {
    private static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()

    static func size(_ value: Int64) -> String { bytes.string(fromByteCount: max(0, value)) }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "measuring…" }
        return "\(bytes.string(fromByteCount: Int64(bytesPerSecond)))/s"
    }

    static func eta(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "estimating time…" }
        if seconds < 60 { return "less than a minute left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "about \(minutes) min left" }
        return "about \(minutes / 60)h \(minutes % 60)m left"
    }
}

final class WatchSyncViewController: UITableViewController {

    private var albums: [Album] = []
    private let service = WatchSyncService.shared
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let notify = UINotificationFeedbackGenerator()

    init() { super.init(style: .insetGrouped) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Apple Watch"
        view.backgroundColor = .systemGroupedBackground
        tableView.register(WatchAlbumSyncCell.self, forCellReuseIdentifier: WatchAlbumSyncCell.reuseID)
        albums = Library.shared.albums

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "trash"),
            primaryAction: UIAction { [weak self] _ in self?.confirmRemoveAll() }
        )

        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged), name: WatchSyncService.stateDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged), name: Library.didUpdateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(progressChanged), name: WatchSyncService.progressDidChange, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        service.requestWatchState()
        service.reconcile()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private var wasSyncing = false
    private var pendingProgressUpdate: DispatchWorkItem?

    @objc private func stateChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isViewLoaded, self.view.window != nil else { return }
            self.pendingProgressUpdate?.cancel()
            self.pendingProgressUpdate = nil
            self.albums = Library.shared.albums
            self.wasSyncing = self.service.isSyncing
            self.tableView.reloadData()
        }
    }

    /// Progress ticks arrive dozens of times per second across concurrent
    /// transfers; coalesce them and refresh only the visible cells in place so
    /// scrolling stays smooth and artwork loads never re-fire.
    @objc private func progressChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isViewLoaded, self.view.window != nil else { return }
            guard self.pendingProgressUpdate == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingProgressUpdate = nil
                self.applyProgressToVisibleCells()
            }
            self.pendingProgressUpdate = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    private func applyProgressToVisibleCells() {
        guard isViewLoaded, view.window != nil else { return }
        if service.isSyncing != wasSyncing {
            stateChanged()
            return
        }
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            if indexPath.section == 0 {
                if indexPath.row == 1 {
                    configureActiveSync(cell: tableView.cellForRow(at: indexPath))
                }
            } else if let cell = tableView.cellForRow(at: indexPath) as? WatchAlbumSyncCell,
                      albums.indices.contains(indexPath.row) {
                cell.configure(album: albums[indexPath.row], service: service)
            }
        }
    }

    private var canSync: Bool {
        service.isSupported && service.isPaired && service.isWatchAppInstalled
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return service.isSyncing ? 2 : 1 }
        return albums.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 1 && !albums.isEmpty ? "Albums" : nil
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? statusFooter() : albumsFooter()
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            return indexPath.row == 0 ? statusCell() : activeSyncCell()
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: WatchAlbumSyncCell.reuseID, for: indexPath) as! WatchAlbumSyncCell
        cell.configure(album: albums[indexPath.row], service: service)
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1 else { return }
        toggle(album: albums[indexPath.row])
    }

    override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        indexPath.section == 1 && canSync
    }

    // MARK: - Actions

    private func toggle(album: Album) {
        guard canSync else {
            notify.notificationOccurred(.warning)
            return
        }
        if service.syncedCount(in: album) == album.tracks.count {
            confirmRemove(album: album)
        } else if case let .tooLarge(needed, free) = service.fitResult(for: album) {
            showWontFit(album: album, needed: needed, free: free)
        } else {
            impact.impactOccurred()
            service.sync(tracks: album.tracks)
        }
    }

    private func showWontFit(album: Album, needed: Int64, free: Int64) {
        notify.notificationOccurred(.warning)
        let alert = UIAlertController(
            title: "Not Enough Space",
            message: "“\(album.title)” needs \(SyncFormat.size(needed)), but your Apple Watch has \(SyncFormat.size(free)) free. Remove some music first.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        alert.addAction(UIAlertAction(title: "Sync Anyway", style: .default) { [weak self] _ in
            self?.impact.impactOccurred()
            self?.service.sync(tracks: album.tracks)
        })
        present(alert, animated: true)
    }

    private func confirmRemoveAll() {
        guard !service.syncedPaths.isEmpty || !service.requestedPaths.isEmpty else {
            notify.notificationOccurred(.warning)
            return
        }
        let alert = UIAlertController(
            title: "Remove All from Watch",
            message: "Delete all synced music from your Apple Watch and start fresh?",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Remove All", style: .destructive) { [weak self] _ in
            self?.impact.impactOccurred()
            self?.service.removeAll()
        })
        present(alert, animated: true)
    }

    private func confirmRemove(album: Album) {
        let size = SyncFormat.size(service.totalBytes(in: album))
        let alert = UIAlertController(
            title: "Remove from Watch",
            message: "Delete “\(album.title)” (\(size)) from your Apple Watch?",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
            self?.impact.impactOccurred()
            self?.service.remove(tracks: album.tracks)
        })
        present(alert, animated: true)
    }

    // MARK: - Connection state

    private enum ConnectionState {
        case notSupported, notPaired, notInstalled, full, syncing, pending, synced, ready

        var color: UIColor {
            switch self {
            case .syncing, .synced, .ready: return .systemGreen
            case .pending, .notInstalled: return .systemOrange
            case .full: return .systemRed
            case .notSupported, .notPaired: return .systemGray
            }
        }

        var symbol: String {
            switch self {
            case .syncing: return "arrow.triangle.2.circlepath.circle.fill"
            case .synced: return "checkmark.circle.fill"
            case .pending: return "clock.fill"
            case .full: return "exclamationmark.triangle.fill"
            case .notInstalled: return "exclamationmark.circle.fill"
            case .ready, .notSupported, .notPaired: return "circle.fill"
            }
        }

        var title: String {
            switch self {
            case .notSupported: return "Not Available"
            case .notPaired: return "No Apple Watch"
            case .notInstalled: return "Install Flaccy on Apple Watch"
            case .full: return "Apple Watch is Full"
            case .syncing: return "Syncing…"
            case .pending: return "Finishing Up"
            case .synced: return "Up to Date"
            case .ready: return "Connected"
            }
        }
    }

    private func connectionState() -> ConnectionState {
        if !service.isSupported { return .notSupported }
        if !service.isPaired { return .notPaired }
        if !service.isWatchAppInstalled { return .notInstalled }
        if service.isSyncing { return .syncing }
        if service.watchIsFull || service.diskFullCount > 0 { return .full }
        if service.unconfirmedCount > 0 { return .pending }
        if service.syncedPaths.count > 0 { return .synced }
        return .ready
    }

    private var freeSpaceText: String {
        service.watchFreeBytes > 0 ? " · \(SyncFormat.size(service.watchFreeBytes)) free" : ""
    }

    private func stateSubtitle(_ state: ConnectionState) -> String {
        switch state {
        case .notSupported: return "Watch sync isn’t available on this device."
        case .notPaired: return "Pair an Apple Watch to sync music."
        case .notInstalled: return "Open the Watch app on your iPhone and install Flaccy."
        case .full:
            let n = service.diskFullCount
            return "\(n) track\(n == 1 ? "" : "s") didn’t fit\(freeSpaceText). Remove music to make room."
        case .syncing:
            let n = service.activeTransferCount
            return "\(n) track\(n == 1 ? "" : "s") transferring in the background\(freeSpaceText)."
        case .pending:
            let n = service.unconfirmedCount
            return "\(n) track\(n == 1 ? "" : "s") left — retrying automatically\(freeSpaceText)."
        case .synced:
            let n = service.syncedPaths.count
            return "\(n) track\(n == 1 ? "" : "s") on your Apple Watch\(freeSpaceText)."
        case .ready:
            return "Ready to sync — choose an album below.\(freeSpaceText.isEmpty ? "" : " Watch has\(freeSpaceText).")"
        }
    }

    // MARK: - Footers

    private func statusFooter() -> String {
        let state = connectionState()
        switch state {
        case .notSupported, .notPaired, .notInstalled:
            return stateSubtitle(state)
        default:
            return "Music transfers in the background — you can leave this screen or lock your phone. "
                + "Each track is re-sent until your Apple Watch confirms it arrived."
        }
    }

    private func albumsFooter() -> String {
        "Tip: keep both devices nearby and charging, and on the same Wi‑Fi, to transfer faster. "
            + "Hi‑res albums are large and take several minutes; compressed (AAC) files sync in seconds — "
            + "same quality through AirPods."
    }

    // MARK: - Cells

    private func statusCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.selectionStyle = .none

        let state = connectionState()
        let dot = UIImageView(image: UIImage(systemName: state.symbol))
        dot.tintColor = state.color
        dot.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13)
        dot.setContentHuggingPriority(.required, for: .horizontal)

        let title = UILabel()
        title.font = .preferredFont(forTextStyle: .body)
        title.text = state.title
        let subtitle = UILabel()
        subtitle.font = .preferredFont(forTextStyle: .caption1)
        subtitle.textColor = .secondaryLabel
        subtitle.numberOfLines = 0
        subtitle.text = stateSubtitle(state)

        let textStack = UIStackView(arrangedSubviews: [title, subtitle])
        textStack.axis = .vertical
        textStack.spacing = 2

        let stack = UIStackView(arrangedSubviews: [dot, textStack])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(stack)
        pinToMargins(stack, in: cell)
        return cell
    }

    private func activeSyncCell() -> UITableViewCell {
        let cell = ActiveSyncCell()
        cell.configure(service: service)
        return cell
    }

    private func configureActiveSync(cell: UITableViewCell?) {
        (cell as? ActiveSyncCell)?.configure(service: service)
    }

    private func pinToMargins(_ view: UIView, in cell: UITableViewCell, vertical: CGFloat? = nil) {
        let guide = cell.contentView.layoutMarginsGuide
        var constraints = [
            view.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
        ]
        if let vertical {
            constraints.append(view.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: vertical))
            constraints.append(view.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -vertical))
        } else {
            constraints.append(view.topAnchor.constraint(equalTo: guide.topAnchor))
            constraints.append(view.bottomAnchor.constraint(equalTo: guide.bottomAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }
}

final class ActiveSyncCell: UITableViewCell {

    private let header = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let detail = UILabel()

    init() {
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none

        header.font = .preferredFont(forTextStyle: .subheadline).bold()

        progress.progressTintColor = .tintColor
        progress.trackTintColor = .tertiarySystemFill
        progress.translatesAutoresizingMaskIntoConstraints = false

        detail.font = .preferredFont(forTextStyle: .caption1).monospacedDigit()
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [header, progress, detail])
        stack.axis = .vertical
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(service: WatchSyncService) {
        let count = service.activeTransferCount
        header.text = "Syncing \(count) track\(count == 1 ? "" : "s")…"
        progress.setProgress(Float(service.sessionFraction), animated: false)
        let transferred = SyncFormat.size(service.sessionTransferredBytes)
        let total = SyncFormat.size(service.sessionTotalBytesPending)
        detail.text = "\(transferred) of \(total)  ·  \(SyncFormat.speed(service.speedBytesPerSec))  ·  \(SyncFormat.eta(service.etaSeconds))"
    }
}

final class WatchAlbumSyncCell: UITableViewCell {

    static let reuseID = "WatchAlbumSyncCell"

    private let artworkView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let statusIcon = UIImageView()
    private var currentArtworkKey: String?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentArtworkKey = nil
        artworkView.image = nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.layer.cornerRadius = 8
        artworkView.layer.cornerCurve = .continuous
        artworkView.backgroundColor = .tertiarySystemFill
        artworkView.tintColor = .tertiaryLabel
        artworkView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.numberOfLines = 1
        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 1

        progressView.progressTintColor = .tintColor
        progressView.trackTintColor = .tertiarySystemFill
        progressView.isHidden = true

        statusIcon.contentMode = .center
        statusIcon.setContentHuggingPriority(.required, for: .horizontal)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, progressView])
        textStack.axis = .vertical
        textStack.spacing = 4

        let stack = UIStackView(arrangedSubviews: [artworkView, textStack, statusIcon])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            artworkView.widthAnchor.constraint(equalToConstant: 48),
            artworkView.heightAnchor.constraint(equalToConstant: 48),
            statusIcon.widthAnchor.constraint(equalToConstant: 28),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    func configure(album: Album, service: WatchSyncService) {
        titleLabel.text = album.title

        let artworkKey = album.id
        currentArtworkKey = artworkKey
        if let art = album.artwork ?? AlbumArtworkCache.shared.artwork(forAlbum: album.title, artist: album.artist) {
            setArtwork(art)
        } else {
            setPlaceholder()
            AlbumArtworkCache.shared.loadArtwork(forAlbum: album.title, artist: album.artist) { [weak self] image in
                guard let self, let image, self.currentArtworkKey == artworkKey else { return }
                self.setArtwork(image)
            }
        }

        let total = album.tracks.count
        let synced = service.syncedCount(in: album)
        let size = SyncFormat.size(service.totalBytes(in: album))

        if service.isSyncing(album: album) {
            statusIcon.image = nil
            progressView.isHidden = false
            progressView.setProgress(Float(service.albumSyncFraction(album)), animated: false)
            subtitleLabel.text = "Syncing \(synced) of \(total)  ·  \(size)"
        } else if synced == total, total > 0 {
            progressView.isHidden = true
            statusIcon.image = UIImage(systemName: "checkmark.circle.fill")
            statusIcon.tintColor = .systemGreen
            subtitleLabel.text = "On Apple Watch  ·  \(size)"
        } else if synced > 0 {
            progressView.isHidden = true
            statusIcon.image = UIImage(systemName: "circle.lefthalf.filled")
            statusIcon.tintColor = .tintColor
            subtitleLabel.text = "\(synced) of \(total) on Watch  ·  \(size)"
        } else {
            progressView.isHidden = true
            statusIcon.image = UIImage(systemName: "arrow.down.circle")
            statusIcon.tintColor = .tintColor
            subtitleLabel.text = "\(total) track\(total == 1 ? "" : "s")  ·  \(size)"
        }
    }

    private func setArtwork(_ image: UIImage) {
        artworkView.contentMode = .scaleAspectFill
        artworkView.image = image
    }

    private func setPlaceholder() {
        artworkView.contentMode = .center
        artworkView.image = UIImage(systemName: "music.note")
    }
}

private extension UIFont {
    func bold() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
    func monospacedDigit() -> UIFont {
        UIFont.monospacedDigitSystemFont(ofSize: pointSize, weight: .regular)
    }
}
