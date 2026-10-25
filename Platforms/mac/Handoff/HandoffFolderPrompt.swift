import Foundation

/// The universal app imported a library from the old Mac app but cannot read its music folder yet: macOS grants a
/// folder to one app at a time, so the person picks it once more. While that is pending the library is treated as
/// offline, which keeps the scan from removing songs it cannot see, and the welcome panel asks for the folder.
nonisolated enum HandoffFolderPrompt {

    private static let key = "flaccy.mac.handoff.pendingFolder"

    static var pendingPath: String? {
        UserDefaults.standard.string(forKey: key)
    }

    static var isPending: Bool {
        pendingPath != nil
    }

    /// The folder the old app indexed, when it is still there, for the open panel to start in.
    static var suggestedFolder: URL? {
        guard let path = pendingPath else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func markPending(path: String) {
        UserDefaults.standard.set(path, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
