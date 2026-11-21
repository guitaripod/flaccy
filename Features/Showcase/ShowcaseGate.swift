import Foundation

/// Whether a launch opens on the showcase: once on every device, the first time a Flaccy of this edition runs there,
/// for a person who updated and for a new one alike, and never in a test, an exercise or a screenshot run.
nonisolated enum ShowcaseGate {

    /// The edition the showcase celebrates. A device that has seen a lower one, or none, is shown it once.
    static let edition = 2

    private static let key = "flaccy.showcase.edition"

    /// The launch argument that shows the showcase whatever the state, for screenshots and for checking it by hand.
    static let forceArgument = "--show-showcase"

    /// With ``forceArgument``, opens the showcase on its second page.
    static let everythingArgument = "everything"

    static var seenEdition: Int {
        UserDefaults.standard.integer(forKey: key)
    }

    static func markSeen() {
        UserDefaults.standard.set(edition, forKey: key)
    }

    /// The decision, free of the app's stores so it can be tested.
    static func shouldPresent(seenEdition: Int, isAutomated: Bool, forced: Bool) -> Bool {
        if forced { return true }
        return seenEdition < edition && !isAutomated
    }

    /// A run a test, an exercise or a screenshot route started must open where it asked to, not on the showcase.
    static func isAutomatedRun(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["FLACCY_ROUTE"] != nil
            || arguments.dropFirst().contains { $0.hasPrefix("-") && $0 != forceArgument }
    }

    static func isForced(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(forceArgument)
    }

    static func opensOnEverything(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        guard let index = arguments.firstIndex(of: forceArgument), arguments.indices.contains(index + 1) else { return false }
        return arguments[index + 1] == everythingArgument
    }
}
