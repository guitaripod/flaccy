import UIKit

/// The live artwork grid at the heart of the Debut: one tile per album slot,
/// filling from the centre outward as embedded covers are decoded off disk.
/// The mosaic *is* the progress indicator for Act I, so it is deliberately the
/// only thing on screen that moves — the grid grows 4×4 → 5×5 → 6×6 and then
/// keeps living by rotating its oldest tile out, so a three-thousand-album
/// library never runs out of stage.
final class LibraryMosaicView: UIView {

    static let maximumTiles = 36

    private enum Metrics {
        static let maximumSlotSide: CGFloat = 72
        static let gap: CGFloat = 8
        static let springResponse: TimeInterval = 0.42
        static let springBounce: CGFloat = 0.28
        static let crossfade: TimeInterval = 0.35
        static let rotationInterval: TimeInterval = 0.9
        static let neighbourNudge: CGFloat = 2
        static let settleRise: CGFloat = 6
        static let settleStagger: TimeInterval = 0.012
        static let morphDuration: TimeInterval = 0.55
        static let morphBounce: CGFloat = 0.15
        static let pendingLimit = 24
    }

    static let dimmedAlpha: CGFloat = 0.55

    private var tiles: [MosaicTileView] = []
    private var side = 4
    private var filled = 0
    private var slotOrder: [Int] = []
    private var indexForKey: [String: Int] = [:]
    private var keyForIndex: [Int: String] = [:]
    private var refreshOrder: [Int] = []
    private var pending: [(key: String, cover: UIImage)] = []
    private var rotationTimer: Timer?
    private var paletteSeed: String?
    private var popCursor = 0
    private var isDimmed = false

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        slotOrder = Self.centreOutSlotOrder(side: side)
        addTiles(upTo: side * side)
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Your album covers")
        accessibilityTraits = .updatesFrequently
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { rotationTimer?.invalidate() }

    override var intrinsicContentSize: CGSize {
        let extent = Metrics.maximumSlotSide * 4 + Metrics.gap * 3
        return CGSize(width: extent, height: extent)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let slot = slotSide()
        let extent = CGFloat(side) * slot + CGFloat(side - 1) * Metrics.gap
        let origin = CGPoint(x: (bounds.width - extent) / 2, y: (bounds.height - extent) / 2)
        for (index, tile) in tiles.enumerated() {
            let position = slotOrder[index]
            let column = CGFloat(position % side)
            let row = CGFloat(position / side)
            tile.bounds = CGRect(x: 0, y: 0, width: slot, height: slot)
            tile.center = CGPoint(
                x: origin.x + column * (slot + Metrics.gap) + slot / 2,
                y: origin.y + row * (slot + Metrics.gap) + slot / 2
            )
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            rotationTimer?.invalidate()
            rotationTimer = nil
        } else {
            startRotationIfNeeded()
        }
    }

    /// Places one album's embedded cover, growing the grid when the current one
    /// is full and queueing for rotation once every slot is spoken for. A key
    /// already on screen is ignored, so a rescan cannot duplicate a tile.
    func insert(cover: UIImage, forKey key: String) {
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
        tiles[index].setCover(cover, animated: !reduceMotion, dimmedTo: isDimmed ? Self.dimmedAlpha : 1)
        nudgeNeighbours(of: index)
        accessibilityValue = LibraryLoadPhaseCopy.number(filled)
    }

    /// Act III's choreographed settle: every tile lifts and drops back into the
    /// grid on a short stagger, so the mosaic reads as finished rather than
    /// merely stopped.
    func settle() {
        guard !reduceMotion else { return }
        for (index, tile) in tiles.enumerated() where tile.hasCover {
            tile.transform = CGAffineTransform(translationX: 0, y: -Metrics.settleRise)
            UIView.animate(
                springDuration: Metrics.springResponse,
                bounce: Metrics.springBounce,
                delay: Double(index) * Metrics.settleStagger
            ) {
                tile.transform = .identity
            }
        }
    }

    /// The frames of every filled tile, in reading order, in this view's own
    /// coordinate space — what Act III's morph pairs with the album grid's
    /// first-screen cells.
    func tileFrames() -> [CGRect] {
        filledTiles().map(\.frame)
    }

    /// Flies the filled tiles from the grid onto the frames the album grid is
    /// about to occupy, so the library the reader watched being built is
    /// literally the library they land in.
    func morph(to targets: [CGRect], completion: @escaping () -> Void) {
        let tiles = filledTiles()
        guard !reduceMotion, !targets.isEmpty, !tiles.isEmpty else {
            UIView.animate(withDuration: 0.24, animations: { self.alpha = 0 }, completion: { _ in completion() })
            return
        }
        rotationTimer?.invalidate()
        rotationTimer = nil
        UIView.animate(springDuration: Metrics.morphDuration, bounce: Metrics.morphBounce) {
            for (index, tile) in tiles.enumerated() {
                guard index < targets.count else {
                    tile.alpha = 0
                    continue
                }
                tile.transform = .identity
                tile.bounds = CGRect(origin: .zero, size: targets[index].size)
                tile.center = CGPoint(x: targets[index].midX, y: targets[index].midY)
                tile.alpha = 1
            }
        } completion: { _ in
            completion()
        }
    }

    /// Act II dims the grid so the tiles the job repairs can light back up one
    /// at a time; tiles are dimmed individually rather than through the view's
    /// own alpha, which is what lets a single one return to full strength.
    func setDimmed(_ dimmed: Bool, animated: Bool) {
        guard dimmed != isDimmed else { return }
        isDimmed = dimmed
        popCursor = 0
        let target: CGFloat = dimmed ? Self.dimmedAlpha : 1
        let apply = { self.tiles.forEach { $0.alpha = target } }
        guard animated, !reduceMotion else {
            apply()
            return
        }
        UIView.animate(withDuration: 0.45, delay: 0, options: [.beginFromCurrentState], animations: apply)
    }

    /// Brings the next dimmed tile back to full strength with a small bump —
    /// the visible half of "the AI just corrected this album".
    func popNextTile() {
        guard isDimmed, filled > 0 else { return }
        let tile = tiles[popCursor % filled]
        popCursor += 1
        guard !reduceMotion else {
            tile.alpha = 1
            return
        }
        UIView.animate(springDuration: Metrics.springResponse, bounce: Metrics.springBounce) {
            tile.alpha = 1
            tile.transform = CGAffineTransform(scaleX: 1.06, y: 1.06)
        } completion: { _ in
            UIView.animate(withDuration: 0.24) { tile.transform = .identity }
        }
    }

    private func filledTiles() -> [MosaicTileView] {
        tiles.filter(\.hasCover).sorted {
            $0.frame.minY == $1.frame.minY ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY
        }
    }

    private func slotSide() -> CGFloat {
        let available = min(bounds.width, bounds.height) - CGFloat(side - 1) * Metrics.gap
        guard available > 0 else { return Metrics.maximumSlotSide }
        return min(Metrics.maximumSlotSide, available / CGFloat(side))
    }

    private func growGridIfNeeded() {
        guard filled == tiles.count, side < 6 else { return }
        side += 1
        slotOrder = Self.centreOutSlotOrder(side: side)
        addTiles(upTo: side * side)
        guard !reduceMotion else {
            setNeedsLayout()
            return
        }
        UIView.animate(springDuration: Metrics.springResponse, bounce: Metrics.springBounce) {
            self.layoutIfNeeded()
        }
    }

    private func addTiles(upTo count: Int) {
        while tiles.count < count {
            let tile = MosaicTileView(paletteSeed: seed(for: tiles.count))
            tile.alpha = isDimmed ? Self.dimmedAlpha : 1
            addSubview(tile)
            tiles.append(tile)
        }
        setNeedsLayout()
        layoutIfNeeded()
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
            let tile = tiles[tileIndex]
            UIView.animate(withDuration: 0.14, delay: 0, options: [.beginFromCurrentState]) {
                tile.transform = CGAffineTransform(translationX: dx, y: dy)
            } completion: { _ in
                UIView.animate(springDuration: Metrics.springResponse, bounce: Metrics.springBounce) {
                    tile.transform = .identity
                }
            }
        }
    }

    private func enqueue(cover: UIImage, forKey key: String) {
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

    /// Slots ordered by distance from the middle of the grid, so covers fill
    /// outward from the centre and a grid that grows keeps the albums it
    /// already has near where they were.
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

/// One slot in the mosaic: an album cover once there is one, and until then a
/// two-stop gradient hashed from a library title with a slow breath over it, so
/// an unfinished grid still looks like music rather than a loading skeleton.
private final class MosaicTileView: UIImageView {

    private let placeholder = CAGradientLayer()
    private let breath = UIView()

    private(set) var hasCover = false

    init(paletteSeed: String) {
        super.init(frame: .zero)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        layer.cornerCurve = .continuous
        backgroundColor = UIColor(white: 1, alpha: 0.05)
        isAccessibilityElement = false

        placeholder.startPoint = CGPoint(x: 0, y: 0)
        placeholder.endPoint = CGPoint(x: 1, y: 1)
        layer.addSublayer(placeholder)

        breath.backgroundColor = UIColor(white: 1, alpha: 1)
        breath.isUserInteractionEnabled = false
        breath.layer.opacity = 0.06
        addSubview(breath)

        applyPaletteSeed(paletteSeed)
        startBreathing()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(10, bounds.width * 0.12)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeholder.frame = bounds
        CATransaction.commit()
        breath.frame = bounds
    }

    func applyPaletteSeed(_ seed: String) {
        guard !hasCover else { return }
        let palette = ArtworkPaletteExtractor.fallbackPalette(seed: seed)
        let colors = palette.colors
        let first = (colors.first ?? .systemIndigo).withAlphaComponent(0.30)
        let second = (colors.count > 2 ? colors[2] : colors.last ?? .systemPurple).withAlphaComponent(0.14)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.6)
        placeholder.colors = [first.cgColor, second.cgColor]
        CATransaction.commit()
    }

    func setCover(_ cover: UIImage, animated: Bool, dimmedTo alpha: CGFloat) {
        hasCover = true
        stopBreathing()
        guard animated else {
            crossfade(to: cover, duration: 0.35)
            return
        }
        image = cover
        placeholder.isHidden = true
        transform = CGAffineTransform(scaleX: 0.86, y: 0.86)
        self.alpha = 0
        UIView.animate(springDuration: 0.42, bounce: 0.28) {
            self.transform = .identity
            self.alpha = alpha
        }
    }

    func crossfade(to cover: UIImage, duration: TimeInterval) {
        hasCover = true
        stopBreathing()
        placeholder.isHidden = true
        UIView.transition(with: self, duration: duration, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.image = cover
        }
    }

    /// The empty slots breathe between 6% and 10% white. It is the only motion
    /// in an otherwise still grid, and it is what stops a slow first scan from
    /// looking like a stalled one.
    private func startBreathing() {
        guard !UIAccessibility.isReduceMotionEnabled else {
            breath.layer.opacity = 0.08
            return
        }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.06
        pulse.toValue = 0.10
        pulse.duration = 1.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.timeOffset = Double.random(in: 0..<1.8)
        breath.layer.add(pulse, forKey: "breath")
    }

    private func stopBreathing() {
        breath.layer.removeAnimation(forKey: "breath")
        breath.isHidden = true
    }
}
