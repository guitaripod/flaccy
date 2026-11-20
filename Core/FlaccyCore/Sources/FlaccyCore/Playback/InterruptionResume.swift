import Foundation

/// What the player does once another app that took the sound is done with it.
///
/// iPhone and iPad only: the Mac and Linux mix every app's sound and the watch keeps the system's
/// own hand-back, so there is nothing to mirror in `linux/shared`.
public enum InterruptionResume: String, CaseIterable, Sendable {
    /// Plays again as soon as the other app goes quiet, whether or not it hands the sound back.
    case whenQuiet
    /// Plays again only when the system says to: after a call, Siri, an alarm, or an app that hands back.
    case whenHandedBack
    /// Stays paused until someone presses play.
    case never

    public static let standard: InterruptionResume = .whenQuiet

    public static let defaultsKey = "flaccy.interruptionResume"

    /// The choice a stored name stands for, the standard one for a name this version does not know.
    public init(storedName: String?) {
        self = storedName.flatMap(InterruptionResume.init(rawValue:)) ?? Self.standard
    }

    /// The person's choice as this device keeps it.
    public static var stored: InterruptionResume {
        get { InterruptionResume(storedName: UserDefaults.standard.string(forKey: defaultsKey)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// Whether the system's own "the interruption ended" is acted on.
    public func resumes(onHandBack shouldResume: Bool) -> Bool {
        switch self {
        case .whenQuiet, .whenHandedBack: shouldResume
        case .never: false
        }
    }

    /// Whether the player keeps listening for the other app to go quiet on its own.
    public var watchesForQuiet: Bool { self == .whenQuiet }
}

/// Decides, from a sample a second of "is another app playing", when an interrupted player may
/// take the sound back. Behind another app it waits until that app has been heard and has then
/// stayed quiet, so an app that took the sound to record (the camera, a voice memo, dictation) and
/// never played anything is left alone. With the player itself on screen quiet alone is enough.
public struct InterruptionQuietWatch: Sendable, Equatable {
    public static let sampleInterval: TimeInterval = 1
    public static let quietSamplesNeeded = 2

    public private(set) var heardOtherAudio = false
    public private(set) var quietSamples = 0

    public init() {}

    /// Takes one sample and answers whether the player may play again now.
    public mutating func observe(otherAudioPlaying: Bool, playerIsOnScreen: Bool = false) -> Bool {
        if otherAudioPlaying {
            heardOtherAudio = true
            quietSamples = 0
            return false
        }
        guard heardOtherAudio || playerIsOnScreen else { return false }
        quietSamples += 1
        return quietSamples >= Self.quietSamplesNeeded
    }

    /// Starts the count of quiet samples again after an attempt to play was refused.
    public mutating func attemptWasRefused() {
        quietSamples = 0
    }
}
