import AppKit
import Foundation

/// Resolves the folder the mac library indexes in place. Defaults to a
/// container-private `Data/Music` folder that needs no permission prompt;
/// a user-chosen folder persists as an app-scoped security bookmark whose
/// access stays open for the app's lifetime so scans and playback URLs
/// resolve at any time. When the bookmarked folder is unreachable (external
/// drive unmounted) the root falls back to the default folder in an explicit
/// offline state so callers can suspend destructive work until it returns.
nonisolated final class LibraryRoot: @unchecked Sendable {

    static let shared = LibraryRoot()
    static let didChange = Notification.Name("LibraryRootDidChange")

    private static let bookmarkKey = "flaccy.mac.libraryBookmark"

    private let lock = NSLock()
    private var resolvedURL: URL?
    private var scopedURL: URL?
    private var fallbackActive = false
    private var mountObserver: NSObjectProtocol?

    static var current: URL { shared.url }

    /// True when a persisted bookmark exists but did not resolve to a
    /// reachable folder, so the returned root is a stand-in and the real
    /// library is temporarily offline.
    var isFallbackActive: Bool {
        _ = url
        lock.lock()
        defer { lock.unlock() }
        return fallbackActive
    }

    /// Re-resolves an offline bookmark (called on volume mounts and app
    /// activation); posts `didChange` only when the real folder comes back.
    func retryFallbackResolutionIfNeeded() {
        lock.lock()
        guard fallbackActive else {
            lock.unlock()
            return
        }
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        resolvedURL = nil
        let resolved = resolveLocked()
        resolvedURL = resolved
        let recovered = !fallbackActive
        lock.unlock()
        guard recovered else { return }
        AppLogger.info("Library root reconnected at \(resolved.path)", category: .content)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    var url: URL {
        lock.lock()
        defer { lock.unlock() }
        if let resolvedURL { return resolvedURL }
        let resolved = resolveLocked()
        resolvedURL = resolved
        return resolved
    }

    var isUsingDefaultRoot: Bool {
        url.standardizedFileURL == Self.defaultRoot.standardizedFileURL
    }

    func chooseFolder(_ folder: URL) throws {
        let bookmark = try folder.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        AppLogger.info("Library root changed to \(folder.path)", category: .content)
        invalidateAndNotify()
    }

    func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        AppLogger.info("Library root reset to default container folder", category: .content)
        invalidateAndNotify()
    }

    private func invalidateAndNotify() {
        lock.lock()
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        resolvedURL = nil
        lock.unlock()
        _ = url
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    private func resolveLocked() -> URL {
        if let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            if let resolved = resolveBookmarkLocked(bookmark) {
                fallbackActive = false
                return resolved
            }
            fallbackActive = true
            observeMountsLocked()
            return Self.ensuredDefaultRoot()
        }
        fallbackActive = false
        return Self.ensuredDefaultRoot()
    }

    private func observeMountsLocked() {
        guard mountObserver == nil else { return }
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.retryFallbackResolutionIfNeeded()
        }
    }

    private func resolveBookmarkLocked(_ bookmark: Data) -> URL? {
        var isStale = false
        guard let folder = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            AppLogger.warning("Library bookmark failed to resolve, falling back to default root", category: .content)
            return nil
        }
        if folder.startAccessingSecurityScopedResource() {
            scopedURL = folder
        }
        if isStale, let refreshed = try? folder.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
        ) {
            UserDefaults.standard.set(refreshed, forKey: Self.bookmarkKey)
            AppLogger.info("Refreshed stale library bookmark", category: .content)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            AppLogger.warning("Bookmarked library folder unreachable at \(folder.path), falling back to default root", category: .content)
            scopedURL?.stopAccessingSecurityScopedResource()
            scopedURL = nil
            return nil
        }
        return folder.standardizedFileURL
    }

    /// The container's `Data/Music` cannot serve as the default root — macOS
    /// scaffolds it as a symlink to the user's real Music folder, which the
    /// sandbox denies. Application Support is genuinely container-private.
    private static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("flaccy", isDirectory: true)
            .appendingPathComponent("Music", isDirectory: true)
            .standardizedFileURL
    }

    private static func ensuredDefaultRoot() -> URL {
        let root = defaultRoot
        if !FileManager.default.fileExists(atPath: root.path) {
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            } catch {
                AppLogger.error("Failed to create default library root: \(error.localizedDescription)", category: .content)
            }
        }
        return root
    }
}
