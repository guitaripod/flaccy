#if DEBUG
import Foundation

/// A debug launch on a real device cannot be handed switches: `devicectl`
/// keeps every argument that starts with a dash for itself. `FLACCY_ARGS` in
/// the launch environment carries them instead, split on spaces, and an
/// exercise meant to run on a device reads its switch here.
nonisolated enum DebugLaunch {

    /// The command line and whatever `FLACCY_ARGS` adds to it.
    static let arguments: [String] = {
        let switches = ProcessInfo.processInfo.environment["FLACCY_ARGS"] ?? ""
        return CommandLine.arguments + switches.split(separator: " ").map(String.init)
    }()
}
#endif
