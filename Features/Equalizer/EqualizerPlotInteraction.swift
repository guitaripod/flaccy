import CoreGraphics
import FlaccyCore
import Foundation

/// The moments of a drag a platform may want to mark with a haptic or a sound.
enum EqualizerDetent {
    case tick
    case zero
    case limit
    case reset
    case add
}

@MainActor
protocol EqualizerPlotInteractionDelegate: AnyObject {
    func interaction(didBeginEditing index: Int)
    func interaction(setTarget value: Double, at index: Int)
    func interaction(setFrequency frequency: Double, gain: Double, at index: Int)
    func interaction(resetBandAt index: Int)
    func interaction(addBandAtFrequency frequency: Double, gain: Double)
    func interaction(didCross detent: EqualizerDetent)
    func interactionDidEnd()
}

/// How a pointer edits the curve, written once for the iPhone and the Mac. In
/// Simple mode a press grabs the column it lands in and moves that band
/// straight up and down; in Advanced mode it grabs the node under it and moves
/// it in both directions, and a double press on empty space adds a band. A
/// double press on a node resets its gain. Values settle through
/// `EqualizerPlot` so every client lands on the same numbers.
@MainActor
final class EqualizerPlotInteraction {

    weak var delegate: EqualizerPlotInteractionDelegate?

    private let model: EqualizerPlotModel
    private(set) var isActive = false
    private var draggedIndex = 0
    private var lastValue = 0.0
    private var lastPress: (time: TimeInterval, index: Int?, point: CGPoint)?

    private static let doubleWindow: TimeInterval = 0.32
    private static let doubleSlop: CGFloat = 24
    var nodeHitRadius: CGFloat = 32

    init(model: EqualizerPlotModel) {
        self.model = model
    }

    func begin(at point: CGPoint, in plot: CGRect, time: TimeInterval) {
        let localX = Double(point.x - plot.minX)
        let localY = Double(point.y - plot.minY)
        let height = Double(plot.height)

        switch model.content.mode {
        case .simple:
            let index = EqualizerPlot.nearestCentreIndex(atX: localX, width: Double(plot.width))
            let isDouble = lastPress.map { time - $0.time < Self.doubleWindow && $0.index == index } ?? false
            lastPress = (time, index, point)
            delegate?.interaction(didBeginEditing: index)
            if isDouble {
                delegate?.interaction(didCross: .reset)
                delegate?.interaction(resetBandAt: index)
                return
            }
            begin(dragging: index)
            let value = EqualizerPlot.snappedGain(EqualizerPlot.decibels(atY: localY, height: height))
            lastValue = value
            delegate?.interaction(setTarget: value, at: index)

        case .advanced:
            let hit = model.nearestNode(to: point, in: plot, within: nodeHitRadius)
            let isDouble = lastPress.map { time - $0.time < Self.doubleWindow && hypot($0.point.x - point.x, $0.point.y - point.y) < Self.doubleSlop } ?? false
            lastPress = (time, hit, point)
            if let hit {
                delegate?.interaction(didBeginEditing: hit)
                if isDouble, model.content.bands[hit].type.hasGain {
                    delegate?.interaction(didCross: .reset)
                    delegate?.interaction(resetBandAt: hit)
                    return
                }
                begin(dragging: hit)
                lastValue = model.content.bands[hit].gain
            } else if isDouble, plot.contains(point) {
                let frequency = EqualizerPlot.roundedFrequency(EqualizerPlot.frequency(atX: localX, width: Double(plot.width)))
                let gain = EqualizerPlot.preciseGain(EqualizerPlot.decibels(atY: localY, height: height))
                delegate?.interaction(didCross: .add)
                delegate?.interaction(addBandAtFrequency: frequency, gain: gain)
                begin(dragging: model.content.bands.count)
                lastValue = gain
            }
        }
    }

    func move(to point: CGPoint, in plot: CGRect) {
        guard isActive else { return }
        let localX = Double(point.x - plot.minX)
        let decibels = EqualizerPlot.decibels(atY: Double(point.y - plot.minY), height: Double(plot.height))

        switch model.content.mode {
        case .simple:
            let value = EqualizerPlot.snappedGain(decibels)
            guard value != lastValue else { return }
            markDetents(from: lastValue, to: value)
            lastValue = value
            delegate?.interaction(setTarget: value, at: draggedIndex)

        case .advanced:
            guard model.content.bands.indices.contains(draggedIndex) else { return }
            let band = model.content.bands[draggedIndex]
            let frequency = EqualizerPlot.roundedFrequency(EqualizerPlot.frequency(atX: localX, width: Double(plot.width)))
            let gain = band.type.hasGain ? EqualizerPlot.preciseGain(decibels) : 0
            if band.type.hasGain { markDetents(from: lastValue, to: gain) }
            lastValue = gain
            delegate?.interaction(setFrequency: frequency, gain: gain, at: draggedIndex)
        }
    }

    func end() {
        guard isActive else { return }
        isActive = false
        model.isDragging = false
        delegate?.interactionDidEnd()
    }

    private func begin(dragging index: Int) {
        isActive = true
        model.isDragging = true
        draggedIndex = index
    }

    private func markDetents(from old: Double, to new: Double) {
        let limit = EqualizerBand.gainRange.upperBound
        if new == 0 && old != 0 {
            delegate?.interaction(didCross: .zero)
        } else if abs(new) == limit && abs(old) != limit {
            delegate?.interaction(didCross: .limit)
        } else if floor(new) != floor(old) {
            delegate?.interaction(didCross: .tick)
        }
    }
}
