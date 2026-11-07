import FlaccyCore
import Foundation

/// The words of the Meaning sheet on iPhone and Mac. The Linux client carries
/// the same English in `linux/src/meaning/copy.rs`, apart from where a reading
/// comes from: flaccy-api here, a model on the person's computer there.
nonisolated enum LyricsMeaningCopy {

    static var title: String { String(localized: "Meaning") }
    static var buttonTitle: String { String(localized: "What This Song Means") }
    static var explainLine: String { String(localized: "Explain This Line") }
    static var lineHeader: String { String(localized: "This Line") }
    static var songHeader: String { String(localized: "About the Song") }
    static var wikipediaHeader: String { String(localized: "From Wikipedia") }
    static var readOnWikipedia: String { String(localized: "Read on Wikipedia") }
    static var lookingUp: String { String(localized: "Looking for the song on Wikipedia…") }
    static var reading: String { String(localized: "Reading the lyrics…") }
    static var tryAgain: String { String(localized: "Try Again") }
    static var seePlans: String { String(localized: "See Plans") }
    static var writtenByAI: String {
        String(localized: "Written by AI from the lyrics. It can be wrong.")
    }

    static func wikipediaCredit(_ article: String) -> String {
        String(localized: "From the Wikipedia article “\(article)”, CC BY-SA 4.0.")
    }

    static func wikipediaFailure(_ failure: WikipediaClient.Failure) -> String {
        switch failure {
        case .unreachable:
            return String(localized: "Couldn't reach Wikipedia. Check your connection and try again.")
        case .timedOut:
            return String(localized: "Wikipedia took too long to answer. Try again in a moment.")
        case .server(let code):
            return String(localized: "Wikipedia couldn't answer (HTTP \(code)). Try again in a few minutes.")
        }
    }

    /// What went wrong asking for a reading, the cause and what to do next.
    static func failure(_ failure: MeaningFailure) -> String {
        switch failure {
        case .needsEntitlement:
            return String(localized: "Explaining lyrics uses Flaccy's AI, which comes with Flaccy Lifetime.")
        case .unreachable:
            return String(localized: "Couldn't explain this because Flaccy's AI couldn't be reached. Check your connection and try again.")
        case .quotaReached(let resetsAt):
            let time = resetsAt.formatted(date: .omitted, time: .shortened)
            return String(localized: "Couldn't explain this because today's AI allowance is used up. It comes back at \(time).")
        case .unavailable:
            return String(localized: "Couldn't explain this because Flaccy's AI is unavailable right now. Try again in a few minutes.")
        case .unreadable:
            return String(localized: "Couldn't explain this because the AI's answer couldn't be read. Try again.")
        }
    }
}
