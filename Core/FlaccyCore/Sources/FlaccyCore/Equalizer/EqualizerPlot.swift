import Foundation

/// How the equalizer's response curve maps onto a drawing surface, and how a
/// touch or a pointer maps back onto the numbers: 20 Hz to 20 kHz on a log
/// axis, plus or minus 12 dB on a linear one. The same maths drives the iPhone,
/// the Mac and Linux surfaces so a point sits in the same place on all three.
/// Mirrored in Rust as `linux/shared/src/equalizer/plot.rs`.
public enum EqualizerPlot {

    public static let decibelRange = 12.0
    public static let magnetThreshold = 0.4
    public static let gainStep = 0.5
    public static let fineGainStep = 0.1

    public static func x(forFrequency frequency: Double, width: Double) -> Double {
        let low = EqualizerBand.frequencyRange.lowerBound
        let high = EqualizerBand.frequencyRange.upperBound
        return width * log(frequency / low) / log(high / low)
    }

    public static func frequency(atX x: Double, width: Double) -> Double {
        let low = EqualizerBand.frequencyRange.lowerBound
        let high = EqualizerBand.frequencyRange.upperBound
        let fraction = min(max(x / width, 0), 1)
        return low * pow(high / low, fraction)
    }

    /// Top of the plot is +12 dB, the middle is 0, the bottom is -12 dB.
    public static func y(forDecibels decibels: Double, height: Double) -> Double {
        height / 2 - (decibels / decibelRange) * (height / 2)
    }

    public static func decibels(atY y: Double, height: Double) -> Double {
        (height / 2 - y) / (height / 2) * decibelRange
    }

    /// A gain read off a touch, settled onto the half-decibel grid, with a
    /// magnet at 0 dB so flat is easy to find and easy to return to.
    public static func snappedGain(_ decibels: Double) -> Double {
        let limit = EqualizerBand.gainRange
        if abs(decibels) < magnetThreshold { return 0 }
        let stepped = (decibels / gainStep).rounded() * gainStep
        return min(max(stepped, limit.lowerBound), limit.upperBound)
    }

    /// A gain read off a touch for a parametric band, settled onto a tenth of a decibel.
    public static func preciseGain(_ decibels: Double) -> Double {
        let limit = EqualizerBand.gainRange
        if abs(decibels) < 0.3 { return 0 }
        let stepped = (decibels * 10).rounded() / 10
        return min(max(stepped, limit.lowerBound), limit.upperBound)
    }

    /// The graphic band whose column a horizontal position falls in.
    public static func nearestCentreIndex(atX x: Double, width: Double) -> Int {
        var best = 0
        var distance = Double.infinity
        for (index, centre) in GraphicSolver.centres.enumerated() {
            let d = abs(self.x(forFrequency: centre, width: width) - x)
            if d < distance {
                distance = d
                best = index
            }
        }
        return best
    }

    /// A rounded frequency for a parametric band: three significant figures
    /// so a drag does not land on 1003.7 Hz.
    public static func roundedFrequency(_ frequency: Double) -> Double {
        let clamped = min(max(frequency, EqualizerBand.frequencyRange.lowerBound), EqualizerBand.frequencyRange.upperBound)
        let magnitude = pow(10, floor(log10(clamped)) - 2)
        return (clamped / magnitude).rounded() * magnitude
    }
}
