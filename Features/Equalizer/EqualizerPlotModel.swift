import CoreGraphics
import FlaccyCore
import Foundation

enum EqualizerPlotMode {
    case simple
    case advanced
}

/// What a plot is asked to show.
struct EqualizerPlotContent {
    var mode: EqualizerPlotMode = .simple
    var targets: [Double] = Array(repeating: 0, count: GraphicSolver.centres.count)
    var bands: [EqualizerBand] = []
    var selectedIndex = 0
    var isEnabled = true
    var isComparing = false
}

/// What a curve view is asked to show: the plot's content plus the accent it is drawn in.
struct EqualizerCurveContent {
    var mode: EqualizerPlotMode = .simple
    var targets: [Double] = Array(repeating: 0, count: GraphicSolver.centres.count)
    var bands: [EqualizerBand] = []
    var selectedIndex = 0
    var isEnabled = true
    var isComparing = false
    var accent: PlatformColor = EqualizerTheme.fallbackAccent

    var plot: EqualizerPlotContent {
        EqualizerPlotContent(mode: mode, targets: targets, bands: bands, selectedIndex: selectedIndex, isEnabled: isEnabled, isComparing: isComparing)
    }
}

/// The state behind the response curve on every Apple client: the bands to
/// draw, the points to put on them, and the easing that lets a preset glide
/// into place and the spectrum rise and fall rather than jump. Drawing and
/// touch handling stay in each platform's view; this holds the geometry, in a
/// coordinate space whose y axis grows downward.
final class EqualizerPlotModel {

    private(set) var content = EqualizerPlotContent()
    private(set) var displayTargets = Array(repeating: 0.0, count: GraphicSolver.centres.count)
    private(set) var resolvedBands: [EqualizerBand] = []
    private(set) var spectrumBins: [Float] = []
    private(set) var previewBands: [EqualizerBand]?
    private var previewFrom: [EqualizerBand] = []
    private var previewProgress = 1.0
    var isDragging = false

    static let spectrumFloorDecibels: Float = -78
    static let spectrumRangeDecibels: Float = 66

    private static let easing = 0.34
    private static let settleThreshold = 0.02
    private static let spectrumFall: Float = 2.2
    private static let previewStep = 1.0 / (0.16 * 30)

    /// Replaces the content. In Simple mode the drawn targets glide to the new
    /// ones unless `snap` is set, as it is when the mode itself changed.
    func update(_ new: EqualizerPlotContent, snap: Bool) {
        let modeChanged = new.mode != content.mode
        content = new
        if new.mode == .simple, snap || modeChanged {
            displayTargets = new.targets
        }
        refreshResolvedBands()
    }

    var isPreviewing: Bool {
        previewBands != nil
    }

    /// Shows the curve of a preset being auditioned as the line being heard,
    /// gliding from whatever was on screen; nil goes back to the curve in force.
    func setPreview(_ bands: [EqualizerBand]?, snap: Bool) {
        guard let bands else {
            previewBands = nil
            previewProgress = 1
            return
        }
        previewFrom = previewBands ?? (content.isEnabled ? resolvedBands : [])
        previewBands = bands
        previewProgress = snap ? 1 : 0
    }

    /// The previewed curve placed on the plot, part-way from the one before it
    /// while the glide plays.
    func previewPoints(in plot: CGRect) -> [CGPoint]? {
        guard let previewBands else { return nil }
        let target = curvePoints(previewBands, in: plot)
        guard previewProgress < 1 else { return target }
        let from = curvePoints(previewFrom, in: plot)
        let eased = CGFloat(previewProgress * previewProgress * (3 - 2 * previewProgress))
        return zip(from, target).map { CGPoint(x: $1.x, y: $0.y + ($1.y - $0.y) * eased) }
    }

    /// One animation frame. Returns true when the drawn curve moved.
    @discardableResult
    func step(spectrum: [Float]?, freezeSpectrum: Bool) -> Bool {
        var moved = false
        if content.mode == .simple {
            if isDragging {
                if displayTargets != content.targets {
                    displayTargets = content.targets
                    moved = true
                }
            } else {
                for index in displayTargets.indices {
                    let gap = content.targets[index] - displayTargets[index]
                    if abs(gap) < Self.settleThreshold {
                        if displayTargets[index] != content.targets[index] {
                            displayTargets[index] = content.targets[index]
                            moved = true
                        }
                    } else {
                        displayTargets[index] += gap * Self.easing
                        moved = true
                    }
                }
            }
        }
        if moved { refreshResolvedBands() }
        if previewProgress < 1 {
            previewProgress = min(previewProgress + Self.previewStep, 1)
            moved = true
        }
        if !freezeSpectrum { advanceSpectrum(spectrum) }
        return moved
    }

    private func advanceSpectrum(_ fresh: [Float]?) {
        guard let fresh else {
            for index in spectrumBins.indices {
                spectrumBins[index] = max(spectrumBins[index] - 3, SpectrumAnalyzer.floorDecibels)
            }
            return
        }
        if spectrumBins.count != fresh.count { spectrumBins = fresh }
        for index in fresh.indices {
            spectrumBins[index] = fresh[index] > spectrumBins[index]
                ? fresh[index]
                : max(fresh[index], spectrumBins[index] - Self.spectrumFall)
        }
    }

    private func refreshResolvedBands() {
        switch content.mode {
        case .simple: resolvedBands = GraphicSolver.bands(forTargets: displayTargets)
        case .advanced: resolvedBands = content.bands
        }
    }

    var nodeCount: Int {
        content.mode == .simple ? GraphicSolver.centres.count : content.bands.count
    }

    func nodePosition(_ index: Int, in plot: CGRect) -> CGPoint {
        switch content.mode {
        case .simple:
            return CGPoint(
                x: plot.minX + CGFloat(EqualizerPlot.x(forFrequency: GraphicSolver.centres[index], width: Double(plot.width))),
                y: plot.minY + CGFloat(EqualizerPlot.y(forDecibels: displayTargets[index], height: Double(plot.height)))
            )
        case .advanced:
            let band = content.bands[index]
            let decibels = band.type.hasGain ? band.gain : 0
            return CGPoint(
                x: plot.minX + CGFloat(EqualizerPlot.x(forFrequency: band.frequency, width: Double(plot.width))),
                y: plot.minY + CGFloat(EqualizerPlot.y(forDecibels: decibels, height: Double(plot.height)))
            )
        }
    }

    /// The curve of `bands`, sampled on a log axis and clamped a little past the plot.
    func curvePoints(_ bands: [EqualizerBand], in plot: CGRect, count: Int = 160) -> [CGPoint] {
        let reference = BiquadMath.referenceSampleRate
        let compiled = bands.filter(\.isEnabled).map { BiquadMath.coefficients(for: $0, sampleRate: reference) }
        let limit = EqualizerPlot.decibelRange * 1.5
        return BiquadMath.logFrequencies(count: count).map { frequency in
            let decibels = compiled.reduce(0.0) { $0 + BiquadMath.magnitudeDecibels($1, frequency: frequency, sampleRate: reference) }
            return CGPoint(
                x: plot.minX + CGFloat(EqualizerPlot.x(forFrequency: frequency, width: Double(plot.width))),
                y: plot.minY + CGFloat(EqualizerPlot.y(forDecibels: min(max(decibels, -limit), limit), height: Double(plot.height)))
            )
        }
    }

    /// The spectrum as points along the plot, left to right; the caller closes the shape.
    func spectrumPoints(in plot: CGRect) -> [CGPoint] {
        guard !spectrumBins.isEmpty else { return [] }
        let low = EqualizerBand.frequencyRange.lowerBound
        let high = EqualizerBand.frequencyRange.upperBound
        let count = spectrumBins.count
        return spectrumBins.enumerated().map { index, level in
            let frequency = low * pow(high / low, (Double(index) + 0.5) / Double(count))
            let fraction = CGFloat(min(max((level - Self.spectrumFloorDecibels) / Self.spectrumRangeDecibels, 0), 1))
            return CGPoint(
                x: plot.minX + CGFloat(EqualizerPlot.x(forFrequency: frequency, width: Double(plot.width))),
                y: plot.maxY - fraction * plot.height * 0.86
            )
        }
    }

    func nearestNode(to point: CGPoint, in plot: CGRect, within radius: CGFloat) -> Int? {
        var best: Int?
        var distance = radius
        for index in 0..<nodeCount {
            let center = nodePosition(index, in: plot)
            let d = hypot(center.x - point.x, center.y - point.y)
            if d < distance {
                distance = d
                best = index
            }
        }
        return best
    }
}
