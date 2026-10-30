import Foundation

/// Whether a launch opens on the welcome: the first time Flaccy runs with no music and no server, never in a test, an
/// exercise or a screenshot run, and never again once the person has seen it.
nonisolated enum WelcomeGate {

    private static let key = "flaccy.welcome.seen"

    /// The launch argument that shows the welcome whatever the state, for screenshots and for checking it by hand.
    static let forceArgument = "--show-welcome"

    /// With ``forceArgument``, opens the welcome on its Flaccy Server step.
    static let serverStepArgument = "server"

    static var hasBeenSeen: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func markSeen() {
        UserDefaults.standard.set(true, forKey: key)
    }

    /// The decision, free of the app's stores so it can be tested.
    static func shouldPresent(seen: Bool, hadIndexedLibrary: Bool, serverCount: Int, isAutomated: Bool, forced: Bool) -> Bool {
        if forced { return true }
        return !seen && !hadIndexedLibrary && serverCount == 0 && !isAutomated
    }

    /// A run a test, an exercise or a screenshot route started must open where it asked to, not on the welcome.
    static func isAutomatedRun(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["FLACCY_ROUTE"] != nil
            || arguments.dropFirst().contains { $0.hasPrefix("-") }
    }

    static func isForced(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(forceArgument)
    }

    static func opensOnServerStep(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        guard let index = arguments.firstIndex(of: forceArgument), arguments.indices.contains(index + 1) else { return false }
        return arguments[index + 1] == serverStepArgument
    }
}
