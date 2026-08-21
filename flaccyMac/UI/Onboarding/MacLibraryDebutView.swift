import AppKit
import Combine
import FlaccyCore

/// The first two acts of the Debut, rendered inside the onboarding panel's own
/// glass rather than over the window. The Mac never takes the window over: the
/// library, the sidebar and the transport stay exactly where they are while the
/// panel grows a stage in the middle of them.
///
/// Act I is bounded disk work and keeps a determinate hairline. Act II is
/// unbounded network work, so the hairline is gone and a countdown takes its
/// place — the job has no fraction, and drawing one here would be a guess.
final class MacLibraryDebutView: NSView {

    private enum Metrics {
        static let mosaicSide: CGFloat = 196
        static let springResponse: Double = 0.42
        static let springDamping: Double = 0.72
        static let crossfade: TimeInterval = 0.35
    }

    var onTurnOnAI: (() -> Void)?

    private let headline = NSTextField(labelWithString: "")
    private let chip = NSView()
    private let chipLabel = NSTextField(labelWithString: LibraryDebutCopy.trialChip)
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private let mosaic = MacLibraryMosaicView()
    private let hairline = HairlineProgressView()
    private let countdown = NSTextField(labelWithString: "")
    private let caption = NSTextField(labelWithString: "")
    private let aiButton = GlassCapsuleButton(
        title: LibraryDebutCopy.aiSkippedAction, symbolName: "wand.and.stars"
    )
    private let tallies = MacDebutTalliesView()

    private var lastCaption: String?
    private var lastAct: LibraryDebutAct = .indexing
    private var cancellables: Set<AnyCancellable> = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        headline.font = .systemFont(ofSize: 20, weight: .semibold)
        headline.textColor = MacColors.primaryLabel

        chip.wantsLayer = true
        chip.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
        chip.layer?.cornerRadius = 9
        chip.layer?.cornerCurve = .continuous
        chipLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        chipLabel.textColor = MacColors.secondaryLabel
        chipLabel.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(chipLabel)
        chip.isHidden = true

        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = MacColors.secondaryLabel
        explanation.alignment = .center
        explanation.preferredMaxLayoutWidth = 460
        explanation.maximumNumberOfLines = 2

        countdown.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        countdown.textColor = MacColors.secondaryLabel
        countdown.isHidden = true

        caption.font = .systemFont(ofSize: 11)
        caption.textColor = MacColors.tertiaryLabel
        caption.lineBreakMode = .byTruncatingMiddle
        caption.alphaValue = 0

        aiButton.isHidden = true
        aiButton.onClick = { [weak self] in self?.onTurnOnAI?() }

        let headlineRow = NSStackView(views: [headline, chip])
        headlineRow.orientation = .horizontal
        headlineRow.alignment = .centerY
        headlineRow.spacing = 8

        mosaic.translatesAutoresizingMaskIntoConstraints = false
        hairline.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [
            headlineRow, explanation, mosaic, hairline, countdown, caption, aiButton, tallies,
        ])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 10
        content.setCustomSpacing(18, after: explanation)
        content.setCustomSpacing(16, after: mosaic)
        content.setCustomSpacing(18, after: caption)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            chipLabel.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 8),
            chipLabel.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -8),
            chipLabel.topAnchor.constraint(equalTo: chip.topAnchor, constant: 3),
            chipLabel.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -3),
            mosaic.widthAnchor.constraint(equalToConstant: Metrics.mosaicSide),
            mosaic.heightAnchor.constraint(equalToConstant: Metrics.mosaicSide),
            hairline.widthAnchor.constraint(equalToConstant: 300),
            hairline.heightAnchor.constraint(equalToConstant: 3),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(libraryChanged), name: Library.didUpdateNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(albumEnriched), name: EnrichmentCoordinator.albumDidEnrich, object: nil
        )
        NotificationCenter.default.publisher(for: Library.albumCoversHoisted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in self?.absorbHoistedCovers(notification) }
            .store(in: &cancellables)
        libraryChanged()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func render(_ state: MacLibrarySurfaceModel.State) {
        switch state.act {
        case .indexing:
            renderIndexing(state)
        case .finishing:
            renderFinishing(state)
        case .summary, .done:
            break
        }
        if state.act != lastAct {
            mosaic.setDimmed(state.act > .indexing, animated: true)
            lastAct = state.act
        }
    }

    /// Act I: the phases, the tallies and a hairline that reaches a real 100%,
    /// because every phase behind it is bounded disk work.
    private func renderIndexing(_ state: MacLibrarySurfaceModel.State) {
        headline.stringValue = LibraryLoadPhaseCopy.headline(for: state.load.phase)
        explanation.stringValue = LibraryLoadPhaseCopy.explanation(for: state.load.phase)
        chip.isHidden = true
        countdown.isHidden = true
        aiButton.isHidden = true
        hairline.isHidden = false
        hairline.setFraction(state.fraction, indeterminate: !state.load.isDeterminate)
        tallies.update(state.load)
        setAccessibilityValueDescription(
            LibraryLoadPhaseCopy.accessibilityValue(for: state.load, fraction: state.fraction)
        )
    }

    /// Act II: the bar is gone with the bounded work it measured, and a countdown
    /// takes over. An expired trial is named rather than hidden — the messy
    /// titles stay on screen and the pill offers the fix.
    private func renderFinishing(_ state: MacLibrarySurfaceModel.State) {
        hairline.isHidden = true
        tallies.update(state.load)

        guard state.job.activity != .needsEntitlement else {
            headline.stringValue = LibraryDebutCopy.aiSkippedHeadline
            explanation.stringValue = LibraryDebutCopy.explanation(for: .aiBatch)
            chip.isHidden = true
            countdown.isHidden = true
            aiButton.isHidden = false
            return
        }

        headline.stringValue = LibraryDebutCopy.headline(for: state.job.scope)
        explanation.stringValue = LibraryDebutCopy.explanation(for: state.job.scope)
        chip.isHidden = !(state.job.scope == .aiBatch && PurchaseManager.shared.state != .purchased)
        aiButton.isHidden = true
        countdown.isHidden = false
        countdown.stringValue = state.job.activity == .waitingForNetwork
            ? EnrichmentJobCopy.waitingForNetwork
            : EnrichmentJobCopy.detail(remaining: state.job.remaining)
        crossfadeCaption(to: state.job.currentTitle)
        setAccessibilityValueDescription(EnrichmentJobCopy.accessibilityValue(for: state.job))
    }

    /// The visible half of "the AI just corrected this one": the title the job is
    /// working on, dissolving into the title before it.
    private func crossfadeCaption(to title: String?) {
        guard let title, !title.isEmpty else {
            caption.animator().alphaValue = 0
            lastCaption = nil
            return
        }
        guard title != lastCaption else { return }
        lastCaption = title
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            caption.stringValue = title
            caption.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Metrics.crossfade / 2
            caption.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.caption.stringValue = title
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Metrics.crossfade / 2
                self.caption.animator().alphaValue = 1
            }
        }
    }

    @objc private func libraryChanged() {
        mosaic.absorb(Library.shared.albums)
    }

    /// Act I's fuel. The tag pass announces each album's embedded cover as soon
    /// as the batch holding it is committed, so the mosaic fills while the scan
    /// is still reading rather than all at once when the first build lands.
    private func absorbHoistedCovers(_ notification: Notification) {
        guard let covers = notification.userInfo?[Library.CoverKey.covers] as? [HoistedAlbumCover]
        else { return }
        mosaic.absorb(hoisted: covers)
    }

    @objc private func albumEnriched() {
        mosaic.absorb(Library.shared.albums)
        mosaic.popNextTile()
    }

    /// Act III's settle, forwarded so the summary card rises over a mosaic that
    /// has just visibly finished rather than one that merely stopped.
    func settle() {
        mosaic.settle()
    }
}

/// The live artwork grid. Same geometry and the same spring as iPhone's
/// `LibraryMosaicView` — centre-out fill, 4×4 → 5×5 → 6×6 capped at 36 tiles,
/// and the oldest tile rotating out once every slot is spoken for, so a
/// three-thousand-album library never runs out of stage.
private final class MacLibraryMosaicView: NSView {

    static let maximumTiles = 36

    private enum Metrics {
        static let gap: CGFloat = 6
        static let rotationInterval: TimeInterval = 0.9
        static let crossfade: TimeInterval = 0.35
        static let neighbourNudge: CGFloat = 2
        static let settleRise: CGFloat = 6
        static let settleStagger: TimeInterval = 0.012
        static let pendingLimit = 24
        static let requestLimit = 240
        static let dimmedAlpha: CGFloat = 0.55
    }

    private var tiles: [MacMosaicTileView] = []
    private var side = 4
    private var filled = 0
    private var slotOrder: [Int] = []
    private var indexForKey: [String: Int] = [:]
    private var keyForIndex: [Int: String] = [:]
    private var refreshOrder: [Int] = []
    private var pending: [(key: String, cover: NSImage)] = []
    private var requested: Set<String> = []
    private var rotationTimer: Timer?
    private var paletteSeed: String?
    private var popCursor = 0
    private var isDimmed = false

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        slotOrder = Self.centreOutSlotOrder(side: side)
        addTiles(upTo: side * side)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Your album covers"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { rotationTimer?.invalidate() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let slot = slotSide()
        let extent = CGFloat(side) * slot + CGFloat(side - 1) * Metrics.gap
        let origin = CGPoint(x: (bounds.width - extent) / 2, y: (bounds.height - extent) / 2)
        for (index, tile) in tiles.enumerated() {
            let position = slotOrder[index]
            let column = CGFloat(position % side)
            let row = CGFloat(position / side)
            tile.frame = CGRect(
                x: origin.x + column * (slot + Metrics.gap),
                y: origin.y + row * (slot + Metrics.gap),
                width: slot, height: slot
            )
        }
    }

    /// Asks for the thumbnail of every album it has not already asked about.
    /// This is the backstop behind `absorb(hoisted:)`: the covers the first
    /// build produced and the ones the job resolves afterwards, deduped against
    /// the tiles the tag pass already filled by their shared key.
    func absorb(_ albums: [Album]) {
        for album in albums {
            let key = "\(album.title)|\(album.artist)"
            guard !requested.contains(key), requested.count < Metrics.requestLimit else { continue }
            requested.insert(key)
            if let cached = AlbumArtworkCache.shared.thumbnail(forAlbum: album.title, artist: album.artist) {
                insert(cover: cached, forKey: key)
                continue
            }
            AlbumArtworkCache.shared.loadThumbnail(forAlbum: album.title, artist: album.artist) { [weak self] image in
                guard let self, let image else { return }
                self.insert(cover: image, forKey: key)
            }
        }
    }

    /// Feeds the grid straight from the tag pass, which knows an album's raw
    /// title and artist before any build has grouped them: the artwork is
    /// looked up under the row that was just committed, while the tile is keyed
    /// the way the built album will be, so the backstop cannot tile it twice.
    func absorb(hoisted covers: [HoistedAlbumCover]) {
        for cover in covers {
            guard !requested.contains(cover.tileKey), requested.count < Metrics.requestLimit
            else { continue }
            requested.insert(cover.tileKey)
            if let cached = AlbumArtworkCache.shared.thumbnail(
                forAlbum: cover.albumTitle, artist: cover.artist
            ) {
                insert(cover: cached, forKey: cover.tileKey)
                continue
            }
            AlbumArtworkCache.shared.loadThumbnail(
                forAlbum: cover.albumTitle, artist: cover.artist
            ) { [weak self] image in
                guard let self, let image else { return }
                self.insert(cover: image, forKey: cover.tileKey)
            }
        }
    }

    private func insert(cover: NSImage, forKey key: String) {
        guard indexForKey[key] == nil else { return }
        applyPaletteSeedIfNeeded(key)
        guard filled < Self.maximumTiles else {
            enqueue(cover: cover, forKey: key)
            return
        }
        growGridIfNeeded()
        let index = filled
        filled += 1
        indexForKey[key] = index
        keyForIndex[index] = key
        refreshOrder.append(index)
        tiles[index].setCover(cover, animated: !reduceMotion, dimmedTo: isDimmed ? Metrics.dimmedAlpha : 1)
        nudgeNeighbours(of: index)
        setAccessibilityValueDescription(LibraryLoadPhaseCopy.number(filled))
    }

    func setDimmed(_ dimmed: Bool, animated: Bool) {
        guard dimmed != isDimmed else { return }
        isDimmed = dimmed
        popCursor = 0
        let target: CGFloat = dimmed ? Metrics.dimmedAlpha : 1
        guard animated, !reduceMotion else {
            tiles.forEach { $0.alphaValue = target }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            tiles.forEach { $0.animator().alphaValue = target }
        }
    }

    func popNextTile() {
        guard isDimmed, filled > 0 else { return }
        let tile = tiles[popCursor % filled]
        popCursor += 1
        tile.pop(reduceMotion: reduceMotion)
    }

    /// Act III's choreographed settle: every filled tile lifts and drops back
    /// into the grid on a short stagger, so the mosaic reads as finished rather
    /// than merely stopped.
    func settle() {
        guard !reduceMotion else { return }
        rotationTimer?.invalidate()
        rotationTimer = nil
        for (index, tile) in tiles.enumerated() where tile.hasCover {
            tile.settle(rise: Metrics.settleRise, delay: Double(index) * Metrics.settleStagger)
        }
    }

    private func slotSide() -> CGFloat {
        let available = min(bounds.width, bounds.height) - CGFloat(side - 1) * Metrics.gap
        guard available > 0 else { return 0 }
        return available / CGFloat(side)
    }

    private func growGridIfNeeded() {
        guard filled == tiles.count, side < 6 else { return }
        side += 1
        slotOrder = Self.centreOutSlotOrder(side: side)
        addTiles(upTo: side * side)
        guard !reduceMotion else {
            needsLayout = true
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.allowsImplicitAnimation = true
            self.layoutSubtreeIfNeeded()
        }
    }

    private func addTiles(upTo count: Int) {
        while tiles.count < count {
            let tile = MacMosaicTileView(paletteSeed: seed(for: tiles.count))
            tile.alphaValue = isDimmed ? Metrics.dimmedAlpha : 1
            addSubview(tile)
            tiles.append(tile)
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// The empty slots take their colour from the first album the scan finds, so
    /// the grid is warm and specific to this library from the very first cover
    /// instead of being a wall of grey rectangles.
    private func applyPaletteSeedIfNeeded(_ key: String) {
        guard paletteSeed == nil else { return }
        paletteSeed = key
        for (index, tile) in tiles.enumerated() {
            tile.applyPaletteSeed(seed(for: index))
        }
    }

    private func seed(for index: Int) -> String {
        "\(paletteSeed ?? "flaccy")#\(index)"
    }

    private func nudgeNeighbours(of index: Int) {
        guard !reduceMotion else { return }
        let position = slotOrder[index]
        let row = position / side
        let column = position % side
        let neighbours: [(Int, Int, CGFloat, CGFloat)] = [
            (row - 1, column, 0, -Metrics.neighbourNudge),
            (row + 1, column, 0, Metrics.neighbourNudge),
            (row, column - 1, -Metrics.neighbourNudge, 0),
            (row, column + 1, Metrics.neighbourNudge, 0),
        ]
        for (neighbourRow, neighbourColumn, dx, dy) in neighbours {
            guard neighbourRow >= 0, neighbourRow < side, neighbourColumn >= 0, neighbourColumn < side else { continue }
            let slot = neighbourRow * side + neighbourColumn
            guard let tileIndex = slotOrder.firstIndex(of: slot) else { continue }
            tiles[tileIndex].nudge(dx: dx, dy: dy)
        }
    }

    private func enqueue(cover: NSImage, forKey key: String) {
        pending.append((key, cover))
        if pending.count > Metrics.pendingLimit { pending.removeFirst() }
        startRotationIfNeeded()
    }

    private func startRotationIfNeeded() {
        guard rotationTimer == nil, !pending.isEmpty, window != nil else { return }
        rotationTimer = Timer.scheduledTimer(withTimeInterval: Metrics.rotationInterval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.rotateOldestTile(timer)
            }
        }
    }

    /// Retires the least recently refreshed tile in favour of a queued cover, so
    /// the grid keeps reporting a library far larger than thirty-six albums.
    private func rotateOldestTile(_ timer: Timer) {
        guard !pending.isEmpty, !refreshOrder.isEmpty else {
            timer.invalidate()
            rotationTimer = nil
            return
        }
        let next = pending.removeFirst()
        let index = refreshOrder.removeFirst()
        refreshOrder.append(index)
        if let previous = keyForIndex[index] { indexForKey[previous] = nil }
        keyForIndex[index] = next.key
        indexForKey[next.key] = index
        tiles[index].crossfade(to: next.cover, duration: Metrics.crossfade)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            rotationTimer?.invalidate()
            rotationTimer = nil
            return
        }
        startRotationIfNeeded()
    }

    /// Slots ordered by distance from the middle of the grid, so covers fill
    /// outward from the centre and a grid that grows keeps the albums it already
    /// has near where they were.
    private static func centreOutSlotOrder(side: Int) -> [Int] {
        let centre = Double(side - 1) / 2
        return (0..<(side * side)).sorted { first, second in
            let a = offset(of: first, side: side, centre: centre)
            let b = offset(of: second, side: side, centre: centre)
            let da = a.x * a.x + a.y * a.y
            let db = b.x * b.x + b.y * b.y
            if abs(da - db) > 0.0001 { return da < db }
            return atan2(a.y, a.x) < atan2(b.y, b.x)
        }
    }

    private static func offset(of slot: Int, side: Int, centre: Double) -> (x: Double, y: Double) {
        (x: Double(slot % side) - centre, y: Double(slot / side) - centre)
    }
}

/// One slot: an album cover once there is one, and until then a two-stop
/// gradient hashed from a library title, so an unfinished grid still looks like
/// music rather than a loading skeleton.
private final class MacMosaicTileView: NSImageView {

    private let placeholder = CAGradientLayer()

    private(set) var hasCover = false

    init(paletteSeed: String) {
        super.init(frame: .zero)
        wantsLayer = true
        imageScaling = .scaleProportionallyUpOrDown
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = MacColors.fill(0.05, light: 0.04).cgColor

        placeholder.startPoint = CGPoint(x: 0, y: 0)
        placeholder.endPoint = CGPoint(x: 1, y: 1)
        layer?.addSublayer(placeholder)

        applyPaletteSeed(paletteSeed)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(8, bounds.width * 0.12)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeholder.frame = bounds
        CATransaction.commit()
    }

    func applyPaletteSeed(_ seed: String) {
        guard !hasCover else { return }
        let (base, second) = PlaceholderGradient.colors(seed: seed)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.6)
        placeholder.colors = [base.cgColor, second.cgColor]
        CATransaction.commit()
    }

    func setCover(_ cover: NSImage, animated: Bool, dimmedTo alpha: CGFloat) {
        hasCover = true
        placeholder.isHidden = true
        guard animated else {
            crossfade(to: cover, duration: 0.35)
            return
        }
        image = cover
        alphaValue = alpha
        layer?.add(MacSpring.animation(keyPath: "transform.scale", from: 0.86, to: 1), forKey: "pop")
        layer?.add(MacSpring.fade(from: 0, to: Float(alpha)), forKey: "fade")
    }

    func crossfade(to cover: NSImage, duration: TimeInterval) {
        hasCover = true
        placeholder.isHidden = true
        let dissolve = CATransition()
        dissolve.type = .fade
        dissolve.duration = duration
        layer?.add(dissolve, forKey: "crossfade")
        image = cover
    }

    func pop(reduceMotion: Bool) {
        guard !reduceMotion else {
            alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            animator().alphaValue = 1
        }
        layer?.add(MacSpring.animation(keyPath: "transform.scale", from: 1.06, to: 1), forKey: "pop")
    }

    func nudge(dx: CGFloat, dy: CGFloat) {
        if dx != 0 {
            layer?.add(MacSpring.animation(keyPath: "transform.translation.x", from: dx, to: 0), forKey: "nudgeX")
        }
        if dy != 0 {
            layer?.add(MacSpring.animation(keyPath: "transform.translation.y", from: dy, to: 0), forKey: "nudgeY")
        }
    }

    func settle(rise: CGFloat, delay: TimeInterval) {
        let animation = MacSpring.animation(keyPath: "transform.translation.y", from: -rise, to: 0)
        animation.beginTime = CACurrentMediaTime() + delay
        animation.fillMode = .backwards
        layer?.add(animation, forKey: "settle")
    }
}

/// The Debut's one spring, expressed once. Response 0.42 and damping 0.72 are
/// the iPhone's constants; `CASpringAnimation` wants stiffness and damping
/// instead, which is what these two conversions are for.
enum MacSpring {

    static let response: Double = 0.42
    static let dampingRatio: Double = 0.72

    static func animation(keyPath: String, from: CGFloat, to: CGFloat) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 1
        animation.stiffness = stiffness
        animation.damping = damping
        animation.initialVelocity = 0
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        return animation
    }

    static func fade(from: Float, to: Float) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = 0.28
        return animation
    }

    private static var stiffness: Double {
        let frequency = 2 * Double.pi / response
        return frequency * frequency
    }

    private static var damping: Double {
        2 * dampingRatio * (2 * Double.pi / response)
    }
}

/// A 3 pt determinate hairline. `NSProgressIndicator` cannot be made this thin,
/// and Act I wants one quiet line under the mosaic rather than a control.
private final class HairlineProgressView: NSView {

    private let track = CALayer()
    private let fill = CALayer()
    private var fraction: Double = 0
    private var isIndeterminate = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        track.backgroundColor = MacColors.fill(0.12, light: 0.10).cgColor
        fill.backgroundColor = NSColor.controlAccentColor.cgColor
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        track.cornerRadius = bounds.height / 2
        fill.cornerRadius = bounds.height / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        CATransaction.commit()
        applyFill(animated: false)
    }

    func setFraction(_ fraction: Double, indeterminate: Bool) {
        self.fraction = min(1, max(0, fraction))
        isIndeterminate = indeterminate
        applyFill(animated: true)
    }

    /// An indeterminate phase still shows something moving — the fraction the
    /// tracker reports already counts an indeterminate phase as half done, so
    /// the line never sits at zero while work is happening.
    private func applyFill(animated: Bool) {
        let width = bounds.width * CGFloat(fraction)
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        CATransaction.setAnimationDuration(0.3)
        fill.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        fill.opacity = isIndeterminate ? 0.6 : 1
        CATransaction.commit()
    }
}

/// The three-up tally row: files found, tracks read, albums built. Monospaced
/// digits so a number that grows does not shift the row under the reader.
private final class MacDebutTalliesView: NSStackView {

    private let files = MacDebutStatView(label: String(localized: "Files"))
    private let tracks = MacDebutStatView(label: String(localized: "Tracks"))
    private let albums = MacDebutStatView(label: String(localized: "Albums"))

    init() {
        super.init(frame: .zero)
        setViews([files, tracks, albums], in: .center)
        orientation = .horizontal
        distribution = .fillEqually
        spacing = 28
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ progress: LibraryLoadProgress) {
        files.value = LibraryLoadPhaseCopy.number(progress.filesFound)
        tracks.value = LibraryLoadPhaseCopy.number(progress.tracksIndexed)
        albums.value = LibraryLoadPhaseCopy.number(progress.albumsBuilt)
    }
}

private final class MacDebutStatView: NSStackView {

    private let valueLabel = NSTextField(labelWithString: "0")
    private let captionLabel = NSTextField(labelWithString: "")

    var value: String {
        get { valueLabel.stringValue }
        set { valueLabel.stringValue = newValue }
    }

    init(label: String) {
        super.init(frame: .zero)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        valueLabel.textColor = MacColors.primaryLabel
        valueLabel.alignment = .center
        captionLabel.stringValue = label.uppercased()
        captionLabel.font = .systemFont(ofSize: 9.5, weight: .semibold)
        captionLabel.textColor = MacColors.tertiaryLabel
        captionLabel.alignment = .center
        setViews([valueLabel, captionLabel], in: .center)
        orientation = .vertical
        alignment = .centerX
        spacing = 2
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
