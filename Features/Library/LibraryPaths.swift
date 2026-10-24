import Foundation

/// The single root every shared component resolves track paths against.
/// On iOS this is the app's Documents sandbox, byte-identical to the URLs the
/// shipping code previously derived inline; on macOS it is the user-chosen
/// (or default container) library folder managed by `LibraryRoot`.
nonisolated enum LibraryPaths {

    static var root: URL {
        #if os(macOS)
        LibraryRoot.current
        #else
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL
        #endif
    }
}
