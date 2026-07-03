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

    static func percent(_ fraction: Double) -> String {
        "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }
}

/// Mirrors WatchSyncService's document-relative path derivation so the UI can
/// match tracks against the service's published path sets without widening the
/// service's API.
private func syncRelativePath(for url: URL) -> String {
    let documents = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(documents) else { return canonicalSyncPath(url.lastPathComponent) }
    let relative = String(path.dropFirst(documents.count))
    return canonicalSyncPath(relative.hasPrefix("/") ? String(relative.dropFirst()) : relative)
}

private enum AlbumSyncStatus {
    case synced
    case sending(Double)
    case waiting
    case failed
    case storageFull
    case partial(synced: Int, total: Int)
    case notSynced

    var pill: (text: String, color: UIColor)? {
        switch self {
        case .synced: return ("Synced", .systemGreen)
        case .sending: return ("Sending", .systemBlue)
        case .waiting: return ("Waiting", .systemGray)
        case .failed: return ("Failed", .systemRed)
        case .storageFull: return ("Storage Full", .systemOrange)
        case .partial, .notSynced: return nil
        }
    }

    var voiceOverValue: String {
        switch self {
        case .synced: return "Synced"
        case let .sending(fraction): return "Sending, \(SyncFormat.percent(fraction))"
        case .waiting: return "Waiting"
        case .failed: return "Failed"
        case .storageFull: return "Storage full"
        case let .partial(synced, total): return "\(synced) of \(total) synced"
        case .notSynced: return "Not synced"
        }
    }

    static func status(for album: Album, service: WatchSyncService) -> AlbumSyncStatus {
        let paths = album.tracks.map { syncRelativePath(for: $0.fileURL) }
        let total = album.tracks.count
        let synced = paths.reduce(0) { $0 + (service.syncedPaths.contains($1) ? 1 : 0) }
        if paths.contains(where: { service.diskFullPaths.contains($0) }) { return .storageFull }
        if paths.contains(where: { service.failedPaths.contains($0) || service.stuckPaths.contains($0) }) { return .failed }
        if service.isSyncing(album: album) { return .sending(service.albumSyncFraction(album)) }
        if synced == total, total > 0 { return .synced }
        if paths.contains(where: { service.requestedPaths.contains($0) && !service.syncedPaths.contains($0) }) { return .waiting }
        if synced > 0 { return .partial(synced: synced, total: total) }
        return .notSynced
    }
}

private final class ProgressRingView: UIView {

    private let trackLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()
    private var fraction: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for layer in [trackLayer, progressLayer] {
            layer.fillColor = UIColor.clear.cgColor
            layer.lineCap = .round
            layer.lineWidth = 3
            self.layer.addSublayer(layer)
        }
        progressLayer.strokeEnd = 0
        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: ProgressRingView, _) in
            self.applyColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func applyColors() {
        trackLayer.strokeColor = UIColor.tertiarySystemFill.cgColor
        progressLayer.strokeColor = tintColor.cgColor
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyColors()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = progressLayer.lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = UIBezierPath(
            arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
            radius: min(rect.width, rect.height) / 2,
            startAngle: -.pi / 2,
            endAngle: .pi * 1.5,
            clockwise: true
        )
        trackLayer.path = path.cgPath
        progressLayer.path = path.cgPath
        trackLayer.frame = bounds
        progressLayer.frame = bounds
    }

    /// Advances the ring smoothly; regressions and Reduce Motion set the value
    /// directly so the stroke never visibly rewinds or interpolates.
    func setProgress(_ value: Double, animated: Bool) {
        let clamped = CGFloat(min(1, max(0, value)))
        let shouldAnimate = animated
            && !UIAccessibility.isReduceMotionEnabled
            && clamped > fraction
            && window != nil
        fraction = clamped
        if shouldAnimate {
            let from = (progressLayer.presentation() ?? progressLayer).strokeEnd
            progressLayer.strokeEnd = clamped
            let animation = CABasicAnimation(keyPath: "strokeEnd")
            animation.fromValue = from
            animation.toValue = clamped
            animation.duration = 0.3
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            progressLayer.add(animation, forKey: "strokeEnd")
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            progressLayer.removeAnimation(forKey: "strokeEnd")
            progressLayer.strokeEnd = clamped
            CATransaction.commit()
        }
    }
}

private final class StatusPillView: UIView {

    private let label = UILabel()

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.cornerCurve = .continuous
        clipsToBounds = true
        label.font = .preferredFont(forTextStyle: .caption2)
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    func apply(text: String, color: UIColor) {
        label.text = text
        label.textColor = color
        backgroundColor = UIAccessibility.isReduceTransparencyEnabled
            ? color.withAlphaComponent(0.28)
            : color.withAlphaComponent(0.16)
    }
}

final class WatchSyncViewController: UITableViewController {

    nonisolated private enum Section: Int, CaseIterable { case status, albums }

    nonisolated private enum Item: Hashable {
        case status
        case activeSync
        case album(String)
    }

    private final class DataSource: UITableViewDiffableDataSource<Section, Item> {
        var headerTitle: ((Section) -> String?)?
        var footerTitle: ((Section) -> String?)?

        override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
            Section(rawValue: section).flatMap { headerTitle?($0) }
        }

        override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
            Section(rawValue: section).flatMap { footerTitle?($0) }
        }
    }

    private var albums: [Album] = []
    private let service = WatchSyncService.shared
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let notify = UINotificationFeedbackGenerator()
    private var dataSource: DataSource!
    private var wasSyncing = false
    private var pendingProgressUpdate: DispatchWorkItem?

    init() { super.init(style: .insetGrouped) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Apple Watch"
        view.backgroundColor = .systemGroupedBackground
        tableView.register(WatchAlbumSyncCell.self, forCellReuseIdentifier: WatchAlbumSyncCell.reuseID)
        tableView.register(WatchStatusCell.self, forCellReuseIdentifier: WatchStatusCell.reuseID)
        tableView.register(ActiveSyncCell.self, forCellReuseIdentifier: ActiveSyncCell.reuseID)
        albums = Library.shared.albums
        configureDataSource()
        applySnapshot()

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

    private func configureDataSource() {
        dataSource = DataSource(tableView: tableView) { [weak self] tableView, indexPath, item in
            guard let self else { return UITableViewCell() }
            switch item {
            case .status:
                let cell = tableView.dequeueReusableCell(withIdentifier: WatchStatusCell.reuseID, for: indexPath) as! WatchStatusCell
                let state = self.connectionState()
                cell.configure(state: state, subtitle: self.stateSubtitle(state))
                return cell
            case .activeSync:
                let cell = tableView.dequeueReusableCell(withIdentifier: ActiveSyncCell.reuseID, for: indexPath) as! ActiveSyncCell
                cell.configure(service: self.service)
                return cell
            case let .album(id):
                let cell = tableView.dequeueReusableCell(withIdentifier: WatchAlbumSyncCell.reuseID, for: indexPath) as! WatchAlbumSyncCell
                if let album = self.album(withID: id) {
                    cell.configure(album: album, service: self.service)
                }
                return cell
            }
        }
        dataSource.defaultRowAnimation = .fade
        dataSource.headerTitle = { [weak self] section in
            guard let self else { return nil }
            return section == .albums && !self.albums.isEmpty ? "Albums" : nil
        }
        dataSource.footerTitle = { [weak self] section in
            guard let self else { return nil }
            return section == .status ? self.statusFooter() : self.albumsFooter()
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems(service.isSyncing ? [.status, .activeSync] : [.status], toSection: .status)
        snapshot.appendItems(albums.map { .album($0.id) }, toSection: .albums)
        dataSource.applySnapshotUsingReloadData(snapshot)
    }

    private func album(withID id: String) -> Album? {
        albums.first { $0.id == id }
    }

    @objc private func stateChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isViewLoaded, self.view.window != nil else { return }
            self.pendingProgressUpdate?.cancel()
            self.pendingProgressUpdate = nil
            self.albums = Library.shared.albums
            let isSyncing = self.service.isSyncing
            if self.wasSyncing, !isSyncing, self.service.unconfirmedCount == 0, self.service.diskFullCount == 0 {
                self.notify.notificationOccurred(.success)
            }
            self.wasSyncing = isSyncing
            self.applySnapshot()
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
            switch dataSource.itemIdentifier(for: indexPath) {
            case .activeSync:
                (tableView.cellForRow(at: indexPath) as? ActiveSyncCell)?.configure(service: service)
            case let .album(id):
                guard
                    let cell = tableView.cellForRow(at: indexPath) as? WatchAlbumSyncCell,
                    let album = album(withID: id)
                else { continue }
                cell.configure(album: album, service: service)
            default:
                continue
            }
        }
    }

    private var canSync: Bool {
        service.isSupported && service.isPaired && service.isWatchAppInstalled
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case let .album(id) = dataSource.itemIdentifier(for: indexPath), let album = album(withID: id) else { return }
        toggle(album: album)
    }

    override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard case .album = dataSource.itemIdentifier(for: indexPath) else { return false }
        return canSync
    }

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

    fileprivate enum ConnectionState {
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
}

private final class WatchStatusCell: UITableViewCell {

    static let reuseID = "WatchStatusCell"

    private let dot = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        dot.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13)
        dot.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 0

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        let stack = UIStackView(arrangedSubviews: [dot, textStack])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(state: WatchSyncViewController.ConnectionState, subtitle: String) {
        dot.image = UIImage(systemName: state.symbol)
        dot.tintColor = state.color
        titleLabel.text = state.title
        subtitleLabel.text = subtitle
        isAccessibilityElement = true
        accessibilityLabel = state.title
        accessibilityValue = subtitle
    }
}

final class ActiveSyncCell: UITableViewCell {

    static let reuseID = "ActiveSyncCell"

    private let ring = ProgressRingView()
    private let percentLabel = UILabel()
    private let header = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let detail = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        header.font = .preferredFont(forTextStyle: .subheadline).bold()
        header.adjustsFontForContentSizeCategory = true

        progress.progressTintColor = .tintColor
        progress.trackTintColor = .tertiarySystemFill

        detail.font = .preferredFont(forTextStyle: .caption1).monospacedDigit()
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0

        percentLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        percentLabel.textColor = .secondaryLabel
        percentLabel.textAlignment = .center
        percentLabel.adjustsFontSizeToFitWidth = true
        percentLabel.minimumScaleFactor = 0.6
        percentLabel.translatesAutoresizingMaskIntoConstraints = false

        ring.translatesAutoresizingMaskIntoConstraints = false
        ring.addSubview(percentLabel)

        let textStack = UIStackView(arrangedSubviews: [header, progress, detail])
        textStack.axis = .vertical
        textStack.spacing = 7

        let stack = UIStackView(arrangedSubviews: [ring, textStack])
        stack.axis = .horizontal
        stack.spacing = 14
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            ring.widthAnchor.constraint(equalToConstant: 48),
            ring.heightAnchor.constraint(equalToConstant: 48),
            percentLabel.centerXAnchor.constraint(equalTo: ring.centerXAnchor),
            percentLabel.centerYAnchor.constraint(equalTo: ring.centerYAnchor),
            percentLabel.widthAnchor.constraint(lessThanOrEqualTo: ring.widthAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        ring.setProgress(0, animated: false)
        progress.setProgress(0, animated: false)
    }

    func configure(service: WatchSyncService) {
        let count = service.activeTransferCount
        let fraction = service.sessionFraction
        header.text = "Syncing \(count) track\(count == 1 ? "" : "s")…"
        ring.setProgress(fraction, animated: true)
        percentLabel.text = SyncFormat.percent(fraction)
        if UIAccessibility.isReduceMotionEnabled {
            progress.setProgress(Float(fraction), animated: false)
        } else {
            progress.setProgress(Float(fraction), animated: Float(fraction) > progress.progress)
        }
        let transferred = SyncFormat.size(service.sessionTransferredBytes)
        let total = SyncFormat.size(service.sessionTotalBytesPending)
        let speed = SyncFormat.speed(service.speedBytesPerSec)
        let eta = SyncFormat.eta(service.etaSeconds)
        detail.text = "\(transferred) of \(total)  ·  \(speed)  ·  \(eta)"
        isAccessibilityElement = true
        accessibilityLabel = header.text
        accessibilityValue = "\(SyncFormat.percent(fraction)), \(transferred) of \(total), \(speed), \(eta)"
    }
}

final class WatchAlbumSyncCell: UITableViewCell {

    static let reuseID = "WatchAlbumSyncCell"

    private let artworkView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let pill = StatusPillView()
    private let ring = ProgressRingView()
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
        ring.setProgress(0, animated: false)
        ring.isHidden = true
        pill.isHidden = true
        statusIcon.image = nil
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

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1
        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 1

        pill.isHidden = true
        let pillRow = UIStackView(arrangedSubviews: [pill, UIView()])
        pillRow.axis = .horizontal

        statusIcon.contentMode = .center
        ring.isHidden = true

        let trailing = UIView()
        trailing.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        ring.translatesAutoresizingMaskIntoConstraints = false
        trailing.addSubview(statusIcon)
        trailing.addSubview(ring)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, pillRow])
        textStack.axis = .vertical
        textStack.spacing = 4
        textStack.setCustomSpacing(6, after: subtitleLabel)

        let stack = UIStackView(arrangedSubviews: [artworkView, textStack, trailing])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            artworkView.widthAnchor.constraint(equalToConstant: 48),
            artworkView.heightAnchor.constraint(equalToConstant: 48),
            trailing.widthAnchor.constraint(equalToConstant: 28),
            trailing.heightAnchor.constraint(equalToConstant: 28),
            statusIcon.centerXAnchor.constraint(equalTo: trailing.centerXAnchor),
            statusIcon.centerYAnchor.constraint(equalTo: trailing.centerYAnchor),
            ring.widthAnchor.constraint(equalToConstant: 26),
            ring.heightAnchor.constraint(equalToConstant: 26),
            ring.centerXAnchor.constraint(equalTo: trailing.centerXAnchor),
            ring.centerYAnchor.constraint(equalTo: trailing.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    func configure(album: Album, service: WatchSyncService) {
        titleLabel.text = album.title
        loadArtwork(for: album)

        let total = album.tracks.count
        let synced = service.syncedCount(in: album)
        let size = SyncFormat.size(service.totalBytes(in: album))
        let status = AlbumSyncStatus.status(for: album, service: service)

        if let pillContent = status.pill {
            pill.apply(text: pillContent.text, color: pillContent.color)
            pill.isHidden = false
        } else {
            pill.isHidden = true
        }

        switch status {
        case let .sending(fraction):
            statusIcon.image = nil
            ring.isHidden = false
            ring.setProgress(fraction, animated: true)
            subtitleLabel.text = "Syncing \(synced) of \(total)  ·  \(size)"
        case .synced:
            showIcon("checkmark.circle.fill", tint: .systemGreen)
            subtitleLabel.text = "On Apple Watch  ·  \(size)"
        case .failed:
            showIcon("exclamationmark.circle.fill", tint: .systemRed)
            subtitleLabel.text = "Tap to retry  ·  \(size)"
        case .storageFull:
            showIcon("externaldrive.fill.trianglebadge.exclamationmark", tint: .systemOrange)
            subtitleLabel.text = "Not enough space on Watch  ·  \(size)"
        case .waiting:
            showIcon("clock", tint: .systemGray)
            subtitleLabel.text = "Waiting to send  ·  \(size)"
        case .partial:
            showIcon("circle.lefthalf.filled", tint: .tintColor)
            subtitleLabel.text = "\(synced) of \(total) on Watch  ·  \(size)"
        case .notSynced:
            showIcon("arrow.down.circle", tint: .tintColor)
            subtitleLabel.text = "\(total) track\(total == 1 ? "" : "s")  ·  \(size)"
        }

        isAccessibilityElement = true
        accessibilityLabel = "\(album.title), \(subtitleLabel.text ?? "")"
        accessibilityValue = status.voiceOverValue
        accessibilityTraits = .button
    }

    private func showIcon(_ symbol: String, tint: UIColor) {
        ring.isHidden = true
        ring.setProgress(0, animated: false)
        statusIcon.image = UIImage(systemName: symbol)
        statusIcon.tintColor = tint
    }

    private func loadArtwork(for album: Album) {
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
