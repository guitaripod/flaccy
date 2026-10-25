import Foundation

/// The app group folder the old Mac app writes its export into and the universal app reads it from: the only place
/// two sandboxed apps of one team share. The group id comes from the Info.plist so it is spelled once, in
/// `project.yml`. A DEBUG build takes `--handoff-container <path>` instead, since an unsigned build has no real group.
nonisolated enum HandoffContainer {

    private static let infoKey = "FlaccyHandoffGroup"

    static var url: URL? {
        #if DEBUG
        if let override = overridePath { return URL(fileURLWithPath: override, isDirectory: true) }
        #endif
        guard let group = Bundle.main.object(forInfoDictionaryKey: infoKey) as? String,
              !group.isEmpty, !group.hasPrefix("$(")
        else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    #if DEBUG
    private static var overridePath: String? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--handoff-container"), arguments.indices.contains(flag + 1)
        else { return nil }
        return arguments[flag + 1]
    }
    #endif
}
