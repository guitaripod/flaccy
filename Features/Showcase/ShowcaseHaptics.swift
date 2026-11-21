import CoreHaptics
import MidgarCore
import UIKit

/// The feel of the showcase arriving: a short swell that ends in one firm beat as the version lands, a light tick
/// for each line that follows and a soft beat when the buttons are ready. One pattern, played once.
@MainActor
final class ShowcaseHaptics {

    private var engine: CHHapticEngine?
    private let fallback = UIImpactFeedbackGenerator(style: .medium)

    /// Starts the engine ahead of the entrance so the first beat is not late.
    func prepare() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            fallback.prepare()
            return
        }
        do {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = true
            try engine.start()
            self.engine = engine
        } catch {
            MidgarLog.info("Showcase haptics unavailable: \(error.localizedDescription)", category: .ui)
        }
    }

    /// Plays the whole entrance. With `gentle` (Reduce Motion) everything arrives at once, so one beat is all it gets.
    func playEntrance(rowCount: Int, gentle: Bool) {
        guard let engine else {
            fallback.impactOccurred(intensity: 0.7)
            return
        }
        do {
            let pattern = try gentle ? Self.singleBeat() : Self.entrance(rowCount: rowCount)
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
            MidgarLog.debug("Showcase haptics playing, \(pattern.duration) s", category: .ui)
        } catch {
            MidgarLog.info("Showcase haptics did not play: \(error.localizedDescription)", category: .ui)
        }
    }

    private static func singleBeat() throws -> CHHapticPattern {
        try CHHapticPattern(events: [beat(at: 0, intensity: 0.7, sharpness: 0.4)], parameters: [])
    }

    private static func entrance(rowCount: Int) throws -> CHHapticPattern {
        let swellLength = ShowcaseTiming.versionLands - ShowcaseTiming.version
        let swell = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.55),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.15),
            ],
            relativeTime: ShowcaseTiming.version,
            duration: swellLength
        )
        let rise = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                CHHapticParameterCurve.ControlPoint(relativeTime: 0, value: 0.2),
                CHHapticParameterCurve.ControlPoint(relativeTime: swellLength, value: 1),
            ],
            relativeTime: ShowcaseTiming.version
        )
        let ticks = (0..<rowCount).map { beat(at: ShowcaseTiming.row($0), intensity: 0.32, sharpness: 0.75) }
        let events = [swell, beat(at: ShowcaseTiming.versionLands, intensity: 1, sharpness: 0.45)]
            + ticks
            + [beat(at: ShowcaseTiming.buttons(rowCount: rowCount), intensity: 0.55, sharpness: 0.25)]
        return try CHHapticPattern(events: events, parameterCurves: [rise])
    }

    private static func beat(at time: TimeInterval, intensity: Float, sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ],
            relativeTime: time
        )
    }
}
